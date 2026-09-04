import Looper.Asl.Engine
import Looper.Core.Time
import Looper.Io.Fs
import Looper.Io.Clock
import Looper.Io.Proc

/-!
`Looper.Cli.Asl` — agentic-state-loop レシピの schema 駆動 state エンジンの
IO シェル(vendored `files/loop/scripts/state.py` の置換先、`asl-loop state`)。

外部契約(state.py と同一):
- `asl-loop state <command> [flags]`。stdout は Python 版とバイト一致
  (JSON はキー順・セパレータ込み、status はテキスト行)。
- exit code: predicate(should-stop)は 0 = yes / 1 = no、validate は
  findings で 1、die は 2(dangling 系の die は 3)、それ以外の成功は 0。
  呼び出し側(`_lib.sh` の `state_predicate`)は rc > 1 を fail-closed で
  扱うので、予期しない失敗を exit 1 に落とさない(`hardErrorFrame`)。
- die の stderr プレフィクスは `[state] ERROR:`(state.py と同一)。

LOOP_ROOT の解決: Python は `Path(__file__).resolve().parent.parent`
(scripts/ の親)。バイナリは `<loop_dir>/bin/asl-loop` 配置規約により
実行ファイルの 2 つ上を既定とし、テスト・併走検証は `--loop-root` で
明示注入する(Lean 版のみのフラグ。state.py には存在しない)。

Python との裁定済み仕様差(META.md §31.2):
- `LOOP_TZ` は IANA 名からオフセット方言(`+HH:MM`/`Z`/`UTC`)へ
  (Over-Project 側の表示 TZ と同じ裁定の適用)。既定は +09:00 固定。タイムスタンプは
  表示専用で判定に使われない。
- `state_lock` は fcntl.flock から mkdir ロック(pid 記録 + stale 再取得)へ
  一本化(§4.4 の裁定の適用)。flock の無期限待機は有限リトライ
  (100ms × 600)+ ハード失敗に写す。
- 未捕捉例外相当(ロック不能・書き込み失敗等)は Python の traceback
  exit 1 ではなく die(exit 2)= fail-closed。
-/

namespace Looper.Cli.Asl

open Looper
open Looper.Asl
open Looper.Core.Prim (expandEquals)
open Looper.Core.Doc (RawFile)

private def die (msg : String) (code : UInt32 := 2) : IO UInt32 := do
  IO.eprintln s!"[state] ERROR: {msg}"
  pure code

/-! ## 引数パース(argparse 相当) -/

private structure Args where
  command : String
  loopRoot : Option String := none
  reason : Option String := none
  detail : Option String := none
  runId : Option String := none
  status : Option String := none
  changed : Option String := none
  runStatus : Option String := none
  note : Option String := none
  force : Bool := false
  doc : Option String := none
  contentFile : Option String := none
  logName : Option String := none
  entry : Option String := none

private structure ArgsAcc where
  command : Option String := none
  loopRoot : Option String := none
  reason : Option String := none
  detail : Option String := none
  runId : Option String := none
  status : Option String := none
  changed : Option String := none
  runStatus : Option String := none
  note : Option String := none
  force : Bool := false
  doc : Option String := none
  contentFile : Option String := none
  logName : Option String := none
  entry : Option String := none
  /-- 出現したフラグ名(コマンドごとの許可検査用)。 -/
  seen : List String := []

/-- `asl-loop state` の全コマンド(argparse の choices)。**usage もここから
導く**(`Cli.AslMain.usage`)— Over 側で手書きの一覧が実装から遅れた事故
(抽出計画 Phase 10 の整合性総点検)と同じ形を In 側でも作らない。 -/
def commands : List String := [
  "ensure", "validate", "raise-gate", "should-stop", "start-run", "end-run",
  "record-progress", "resume", "status", "write-doc", "append-log"]

/-- argparse がサブコマンドごとに定義するフラグ(`--loop-root` は Lean 版
共通フラグ)。 -/
private def allowedFlags : String → List String
  | "raise-gate" => ["--reason", "--detail"]
  | "end-run" => ["--run-id", "--status"]
  | "record-progress" => ["--changed", "--run-status"]
  | "resume" => ["--note", "--force"]
  | "write-doc" => ["--doc", "--content-file"]
  | "append-log" => ["--log", "--entry"]
  | _ => []

private def requiredFlags : String → List String
  | "raise-gate" => ["--reason", "--detail"]
  | "end-run" => ["--run-id"]
  | "record-progress" => ["--changed", "--run-status"]
  | "write-doc" => ["--doc", "--content-file"]
  | "append-log" => ["--log", "--entry"]
  | _ => []

private def finishArgs (acc : ArgsAcc) : Except String Args := do
  let some command := acc.command
    | .error "the following arguments are required: command"
  if !commands.contains command then
    .error s!"argument command: invalid choice: '{command}'"
  for flag in acc.seen do
    if flag != "--loop-root" && !(allowedFlags command).contains flag then
      .error s!"unrecognized arguments: {flag}"
  for flag in requiredFlags command do
    if !acc.seen.contains flag then
      .error s!"the following arguments are required: {flag}"
  if let some c := acc.changed then
    if c != "yes" && c != "no" then
      .error s!"argument --changed: invalid choice: '{c}' (choose from 'yes', 'no')"
  if let some r := acc.runStatus then
    if r != "ok" && r != "fail" then
      .error s!"argument --run-status: invalid choice: '{r}' (choose from 'ok', 'fail')"
  pure { command, loopRoot := acc.loopRoot, reason := acc.reason,
         detail := acc.detail, runId := acc.runId, status := acc.status,
         changed := acc.changed, runStatus := acc.runStatus, note := acc.note,
         force := acc.force, doc := acc.doc, contentFile := acc.contentFile,
         logName := acc.logName, entry := acc.entry }

private def parseArgs (args : List String) : Except String Args :=
  go (args.flatMap expandEquals) {}
where
  valueError (flag : String) : Except String Args :=
    .error s!"argument {flag}: expected one argument"
  go : List String → ArgsAcc → Except String Args
    | [], acc => finishArgs acc
    | "--loop-root" :: v :: rest, acc =>
      go rest { acc with loopRoot := some v, seen := acc.seen ++ ["--loop-root"] }
    | ["--loop-root"], _ => valueError "--loop-root"
    | "--reason" :: v :: rest, acc =>
      go rest { acc with reason := some v, seen := acc.seen ++ ["--reason"] }
    | ["--reason"], _ => valueError "--reason"
    | "--detail" :: v :: rest, acc =>
      go rest { acc with detail := some v, seen := acc.seen ++ ["--detail"] }
    | ["--detail"], _ => valueError "--detail"
    | "--run-id" :: v :: rest, acc =>
      go rest { acc with runId := some v, seen := acc.seen ++ ["--run-id"] }
    | ["--run-id"], _ => valueError "--run-id"
    | "--status" :: v :: rest, acc =>
      go rest { acc with status := some v, seen := acc.seen ++ ["--status"] }
    | ["--status"], _ => valueError "--status"
    | "--changed" :: v :: rest, acc =>
      go rest { acc with changed := some v, seen := acc.seen ++ ["--changed"] }
    | ["--changed"], _ => valueError "--changed"
    | "--run-status" :: v :: rest, acc =>
      go rest { acc with runStatus := some v, seen := acc.seen ++ ["--run-status"] }
    | ["--run-status"], _ => valueError "--run-status"
    | "--note" :: v :: rest, acc =>
      go rest { acc with note := some v, seen := acc.seen ++ ["--note"] }
    | ["--note"], _ => valueError "--note"
    | "--force" :: rest, acc =>
      go rest { acc with force := true, seen := acc.seen ++ ["--force"] }
    | "--doc" :: v :: rest, acc =>
      go rest { acc with doc := some v, seen := acc.seen ++ ["--doc"] }
    | ["--doc"], _ => valueError "--doc"
    | "--content-file" :: v :: rest, acc =>
      go rest { acc with contentFile := some v, seen := acc.seen ++ ["--content-file"] }
    | ["--content-file"], _ => valueError "--content-file"
    | "--log" :: v :: rest, acc =>
      go rest { acc with logName := some v, seen := acc.seen ++ ["--log"] }
    | ["--log"], _ => valueError "--log"
    | "--entry" :: v :: rest, acc =>
      go rest { acc with entry := some v, seen := acc.seen ++ ["--entry"] }
    | ["--entry"], _ => valueError "--entry"
    | arg :: rest, acc =>
      if arg.startsWith "-" then .error s!"unrecognized arguments: {arg}"
      else match acc.command with
        | none => go rest { acc with command := some arg }
        | some _ => .error s!"unrecognized arguments: {arg}"

/-! ## 実行文脈と IO ヘルパ -/

private structure Ctx where
  loopRoot : System.FilePath
  stateDir : System.FilePath
  tmpDir : System.FilePath
  schemaPath : System.FilePath

private def mkCtx (loopRoot : System.FilePath) : Ctx :=
  { loopRoot, stateDir := loopRoot / "state", tmpDir := loopRoot / "tmp",
    schemaPath := loopRoot / "schema.json" }

/-- LOOP_ROOT: `--loop-root` 明示、なければ実行ファイルの 2 つ上
(`<loop_dir>/bin/asl-loop` 配置規約 = Python の `__file__` 起点に対応)。 -/
private def resolveCtx (flag : Option String) : IO (Except String Ctx) := do
  match flag with
  | some p => pure (.ok (mkCtx (← Io.Fs.resolveNonStrict p)))
  | none =>
    let exe ← IO.appPath
    match exe.parent.bind (·.parent) with
    | some root => pure (.ok (mkCtx root))
    | none => pure (.error "cannot determine LOOP_ROOT from the binary location; pass --loop-root")

/-- state.py のテキスト読み: 不在は `.absent`、その他の失敗は `.ioError`。 -/
private def readRaw (path : System.FilePath) : IO RawFile := do
  try
    pure (.text (← IO.FS.readFile path))
  catch e =>
    if ← path.pathExists then pure (.ioError (toString e))
    else pure .absent

private def isFile (path : System.FilePath) : IO Bool := do
  try
    pure ((← path.metadata).type == IO.FS.FileType.file)
  catch _ =>
    pure false

/-- Python `now_local()`: `LOOP_TZ`(オフセット方言)、既定 +09:00。 -/
private def nowLocal : IO String := Io.Clock.nowLocal "LOOP_TZ"

/-- schema.json の読みと分類。fuel はテキスト長(check_value の入れ子上限)。 -/
private def readSchema (ctx : Ctx) : IO (Engine.SchemaLoad × Nat) := do
  let raw ← readRaw ctx.schemaPath
  let fuel := match raw with
    | .text t => t.length + 1
    | _ => 1
  pure (Engine.classifySchema ctx.schemaPath.toString raw, fuel)

/-- Python `load_schema()`(strict): 失敗は die。 -/
private def schemaOrDie (ctx : Ctx) (k : Core.Json.Value → Nat → IO UInt32) : IO UInt32 := do
  let (load, fuel) ← readSchema ctx
  match load with
  | .ok schema => k schema fuel
  | other => die ((Engine.schemaLoadError other).getD "schema.json unreadable")

private def readControlNow (ctx : Ctx) : IO (Except String Core.Json.Value) := do
  let path := ctx.stateDir / "control.json"
  pure (Engine.readControl path.toString (← readRaw path))

/-- Python `dangling_run_ids(diagnostics)`。 -/
private def readDangling (ctx : Ctx) : IO (List Core.Json.Value × Option String) := do
  let path := ctx.stateDir / "runs.jsonl"
  if !(← isFile path) then
    return ([], none)
  match ← readRaw path with
  | .absent => pure ([], none)
  | .ioError e => pure ([], some s!"runs.jsonl unreadable: {e}")
  | .text t =>
    match Looper.Core.Doc.parseJsonl t with
    | .ok records => pure (Engine.danglingRuns records, none)
    | .error e => pure ([], some s!"runs.jsonl unreadable: {e}")

private def appendJsonlOrDie (path : System.FilePath) (record : Core.Json.Value)
    (act : IO UInt32) : IO UInt32 := do
  match ← Io.Fs.appendJsonl path record with
  | .error e => die s!"cannot append to {path}: {e}"
  | .ok () => act

/-! ## state_lock(mkdir ロック、モジュール頭注の裁定) -/

private def removeTree (path : System.FilePath) : IO Unit := do
  try
    IO.FS.removeDirAll path
  catch _ =>
    pure ()

private def selfPid : IO Int := do
  pure (Int.ofNat (← IO.Process.getPID).toNat)

private def lockPid? (lockDir : System.FilePath) : IO (Option Int) := do
  try
    pure (Looper.Core.Doc.pyIntOfString? (← IO.FS.readFile (lockDir / "pid")))
  catch _ =>
    pure none

private def reclaimLock (lockDir : System.FilePath) : IO Unit := do
  let reclaim := lockDir.withFileName s!"state.lock.reclaim.{← selfPid}"
  let renamed ← try
      IO.FS.rename lockDir reclaim
      pure true
    catch _ =>
      pure false
  if renamed then
    removeTree reclaim

private def acquireStateLock (lockDir : System.FilePath) :
    Nat → IO (Except String Unit)
  | 0 => pure (.error s!"could not acquire the state lock: {lockDir}")
  | n + 1 => do
    let createErr? ← try
        IO.FS.createDir lockDir
        pure none
      catch e =>
        pure (some e)
    match createErr? with
    | none =>
      let recordErr? ← try
          IO.FS.writeFile (lockDir / "pid") s!"{← selfPid}\n"
          pure none
        catch e =>
          pure (some e)
      match recordErr? with
      | none => pure (.ok ())
      | some e =>
        removeTree lockDir
        pure (.error s!"cannot record state lock owner in {lockDir}: {e}")
    | some e =>
      if !(← lockDir.pathExists) then
        return .error s!"cannot acquire the state lock {lockDir}: {e}"
      match ← lockPid? lockDir with
      | some owner =>
        if ← Io.Proc.pidAlive owner then
          -- flock 相当の待機(生存保持者が解放するまで 100ms 刻み)
          IO.sleep 100
          acquireStateLock lockDir n
        else do
          reclaimLock lockDir
          acquireStateLock lockDir n
      | none =>
        -- pid 未記録: 取得途中の新鮮なロックは待ち、古い残骸
        -- (Python 時代の flock ファイル含む)だけ回収する
        let age? ← try
            let md ← lockDir.metadata
            pure (some ((← Io.Clock.epochSeconds) - md.modified.sec))
          catch _ =>
            pure none
        match age? with
        | some age =>
          if age ≤ 10 then do
            IO.sleep 100
            acquireStateLock lockDir n
          else do
            reclaimLock lockDir
            acquireStateLock lockDir n
        | none => acquireStateLock lockDir n

/-- Python `state_lock()`: instance 内の全 state 変異を直列化する。 -/
private def withStateLock (ctx : Ctx) (act : IO UInt32) : IO UInt32 := do
  IO.FS.createDirAll ctx.tmpDir
  let lockDir := ctx.tmpDir / "state.lock"
  match ← acquireStateLock lockDir 600 with
  | .error msg => die msg
  | .ok () =>
    try
      act
    finally
      if (← lockPid? lockDir) == some (← selfPid) then
        removeTree lockDir

/-! ## サブコマンド -/

private def runEnsure (ctx : Ctx) : IO UInt32 :=
  schemaOrDie ctx fun schema _ =>
    withStateLock ctx do
      IO.FS.createDirAll ctx.stateDir
      let controlPath := ctx.stateDir / "control.json"
      if !(← isFile controlPath) then
        Io.Fs.writeJsonPretty controlPath (Engine.initialControl (← nowLocal))
      for (name, spec) in Engine.schemaDocuments schema do
        let path := ctx.stateDir / name
        if !(← isFile path) then
          Io.Fs.writeJsonPretty path (Engine.documentSeed spec)
      for name in Engine.schemaLogs schema do
        let path := ctx.stateDir / name
        if !(← isFile path) then
          IO.FS.writeFile path ""
      IO.println (Core.Json.Value.obj [
        ("ensured", .bool true),
        ("state_dir", .str ctx.stateDir.toString)]).renderAscii
      pure 0

private def runValidate (ctx : Ctx) : IO UInt32 := do
  let (load, fuel) ← readSchema ctx
  let schema := match load with
    | .ok v => v
    | _ => .obj []
  let prompt ← readRaw (ctx.loopRoot / "prompts" / "cycle.md")
  let stateDirExists ← ctx.stateDir.isDir
  let control ← readControlNow ctx
  let docs ← (Engine.schemaDocuments schema).mapM fun (name, spec) => do
    pure (name, spec, ← readRaw (ctx.stateDir / name))
  let logs ← (Engine.schemaLogs schema).mapM fun (name : String) => do
    pure (name, ← readRaw (ctx.stateDir / name))
  let previous := (← Io.Fs.readJson? (ctx.stateDir / "validation.json")).getD (.obj [])
  let outcome := Engine.validateOutcome {
    fuel, schemaLoad := load, prompt, stateDirExists, control, docs, logs,
    previous, now := ← nowLocal }
  if outcome.write then
    Io.Fs.writeJsonPretty (ctx.stateDir / "validation.json") outcome.validation
  IO.println outcome.validation.renderPretty
  pure (if outcome.hasErrors then 1 else 0)

private def runShouldStop (ctx : Ctx) : IO UInt32 := do
  match ← readControlNow ctx with
  | .error diag => die diag
  | .ok control =>
    let gates := Engine.openGates control
    let (dangling, diag?) ← readDangling ctx
    match diag? with
    | some diag => die diag
    | none =>
      match Engine.shouldStopPayload gates dangling with
      | .error msg => die msg
      | .ok payload =>
        IO.println payload.renderPretty
        pure (if payload.get? "stop" == some (.bool true) then 0 else 1)

private def runRaiseGate (ctx : Ctx) (args : Args) : IO UInt32 := do
  let reason := (args.reason).getD ""
  if !Engine.isReasonSlug reason then
    return ← die "--reason must be a lowercase slug (e.g. human_input_required)"
  let detail := Core.Text.pyStrip ((args.detail).getD "")
  if detail.isEmpty then
    return ← die "--detail must explain what the human must decide or provide"
  schemaOrDie ctx fun _ _ =>
    withStateLock ctx do
      match ← readControlNow ctx with
      | .error diag => die diag
      | .ok control =>
        let (control, added) := Engine.addGate control reason detail "agent" (← nowLocal)
        if added then
          Io.Fs.writeJsonPretty (ctx.stateDir / "control.json") control
        IO.println (Core.Json.Value.obj [
          ("raised", .bool added), ("reason", .str reason)]).renderAscii
        pure 0

private def runStartRun (ctx : Ctx) : IO UInt32 :=
  schemaOrDie ctx fun _ _ =>
    withStateLock ctx do
      let (dangling, diag?) ← readDangling ctx
      match diag? with
      | some diag => die diag
      | none =>
        if !dangling.isEmpty then
          die (Engine.danglingStartRunError dangling) 3
        else
          let runId := s!"R-{((← nowLocal).replace ":" "")}-{← IO.Process.getPID}"
          appendJsonlOrDie (ctx.stateDir / "runs.jsonl")
              (Engine.runStartRecord runId (← nowLocal)) do
            IO.println runId
            pure 0

private def runEndRun (ctx : Ctx) (args : Args) : IO UInt32 :=
  withStateLock ctx do
    let status := match args.status with
      | some s => if s.isEmpty then "ok" else s
      | none => "ok"
    let runId := Core.Json.Value.str ((args.runId).getD "")
    appendJsonlOrDie (ctx.stateDir / "runs.jsonl")
        (Engine.runEndRecord runId (← nowLocal) status) do
      IO.println (Core.Json.Value.obj [
        ("ended", runId), ("status", .str status)]).renderAscii
      pure 0

private def runRecordProgress (ctx : Ctx) (args : Args) : IO UInt32 :=
  schemaOrDie ctx fun schema _ =>
    withStateLock ctx do
      match ← readControlNow ctx with
      | .error diag => die diag
      | .ok control =>
        let policy := Engine.schemaPolicy schema
        let changed := args.changed == some "yes"
        let runOk := args.runStatus == some "ok"
        match Engine.recordProgress control policy changed runOk (← nowLocal) with
        | .error msg => die msg
        | .ok (control, payload) =>
          Io.Fs.writeJsonPretty (ctx.stateDir / "control.json") control
          IO.println payload.renderAscii
          pure 0

private def runResume (ctx : Ctx) (args : Args) : IO UInt32 := do
  let note := Core.Text.pyStrip ((args.note).getD "")
  if note.isEmpty then
    return ← die "resume requires --note explaining what the human reviewed/decided"
  schemaOrDie ctx fun _ _ =>
    withStateLock ctx do
      match ← readControlNow ctx with
      | .error diag => die diag
      | .ok control =>
        let (dangling, diag?) ← readDangling ctx
        match diag? with
        | some diag => die diag
        | none =>
          if !dangling.isEmpty && !args.force then
            die (Engine.danglingResumeError dangling) 3
          else
            match Engine.resumeApply control note (← nowLocal) with
            | .error msg => die msg
            | .ok (control, released) =>
              Io.Fs.writeJsonPretty (ctx.stateDir / "control.json") control
              let closed := if args.force then dangling else []
              let rec appendEnds : List Core.Json.Value → IO UInt32
                | [] => do
                  -- 兄弟 payload(ensure / raise-gate / …)は renderAscii だが、
                  -- resume だけは端末の人間へ note(和文が通例)を読み返す
                  -- 表示なので ensure_ascii=False の render を保つ(意図差)。
                  IO.println (Engine.resumePayload released closed note).render
                  pure 0
                | runId :: rest => do
                  appendJsonlOrDie (ctx.stateDir / "runs.jsonl")
                    (Engine.runEndRecord runId (← nowLocal) "interrupted")
                    (appendEnds rest)
              appendEnds closed

private def runWriteDoc (ctx : Ctx) (args : Args) : IO UInt32 :=
  schemaOrDie ctx fun schema fuel => do
    let docs := Engine.schemaDocuments schema
    let name := (args.doc).getD ""
    let some (_, spec) := docs.find? (fun (k, _) => k == name)
      | die (Engine.unknownDocumentError name docs)
    let source := (args.contentFile).getD ""
    let text? ← try
        if source == "-" then
          pure (.ok (← (← IO.getStdin).readToEnd))
        else
          pure (.ok (← IO.FS.readFile source))
      catch e =>
        pure (Except.error (toString e))
    match text? with
    | .error e => die s!"cannot read --content-file: {e}"
    | .ok text =>
      match Core.Json.parse text with
      | .error e => die s!"--content-file is not valid JSON: {e}"
      | .ok payload =>
        let errors := match spec.get? "schema" with
          | some docSchema =>
            if docSchema matches .obj _ then
              Check.checkValue fuel payload docSchema name
            else []
          | none => []
        if !errors.isEmpty then
          die s!"schema validation failed: {String.intercalate "; " errors}"
        else
          withStateLock ctx do
            Io.Fs.writeJsonPretty (ctx.stateDir / name) payload
            IO.println (Core.Json.Value.obj [("written", .str name)]).renderAscii
            pure 0

private def runAppendLog (ctx : Ctx) (args : Args) : IO UInt32 :=
  schemaOrDie ctx fun schema _ => do
    let logs := Engine.schemaLogs schema
    let name := (args.logName).getD ""
    if name == "runs.jsonl" || !logs.contains name then
      die (Engine.unknownLogError name)
    else
      match Core.Json.parse ((args.entry).getD "") with
      | .error e => die s!"--entry is not valid JSON: {e}"
      | .ok record =>
        if !(record matches .obj _) then
          die "--entry must be a JSON object"
        else
          let record := Engine.withDefaultAt record (← nowLocal)
          withStateLock ctx do
            appendJsonlOrDie (ctx.stateDir / name) record do
              IO.println (Core.Json.Value.obj [("appended", .str name)]).renderAscii
              pure 0

private def runStatus (ctx : Ctx) : IO UInt32 := do
  let control ← readControlNow ctx
  let (load, _) ← readSchema ctx
  let schema := match load with
    | .ok v => v
    | _ => .obj []
  let validation := (← Io.Fs.readJson? (ctx.stateDir / "validation.json")).getD (.obj [])
  let lines := Engine.statusLines {
    loopName := (ctx.loopRoot.fileName).getD ctx.loopRoot.toString
    targetRoot := ((ctx.loopRoot.parent).getD ctx.loopRoot).toString
    control, schema, validation }
  IO.println (String.intercalate "\n" lines)
  pure 0

/-! ## ディスパッチ -/

/-- exit-code 規律: 予期しない失敗は「no」(exit 1)ではなく必ずハード
エラー(exit 2)として表面化させる(`_lib.sh` の `state_predicate` 契約)。 -/
private def hardErrorFrame (command : String) (act : IO UInt32) : IO UInt32 := do
  try
    act
  catch e =>
    IO.eprintln (toString e)
    die s!"unexpected failure in '{command}'; treating as a hard error, never as a gate answer."

def run (args : List String) : IO UInt32 := do
  match parseArgs args with
  | .error e =>
    die s!"usage: asl-loop state <command> [flags] ({e})"
  | .ok parsed =>
    match ← resolveCtx parsed.loopRoot with
    | .error msg => die msg
    | .ok ctx =>
      hardErrorFrame parsed.command <|
        match parsed.command with
        | "ensure" => runEnsure ctx
        | "validate" => runValidate ctx
        | "raise-gate" => runRaiseGate ctx parsed
        | "should-stop" => runShouldStop ctx
        | "start-run" => runStartRun ctx
        | "end-run" => runEndRun ctx parsed
        | "record-progress" => runRecordProgress ctx parsed
        | "resume" => runResume ctx parsed
        | "status" => runStatus ctx
        | "write-doc" => runWriteDoc ctx parsed
        | "append-log" => runAppendLog ctx parsed
        | other => die s!"unreachable command dispatch: {other}"

end Looper.Cli.Asl
