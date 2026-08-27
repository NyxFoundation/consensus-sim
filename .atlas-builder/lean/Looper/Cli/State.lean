import Looper.Core.Json
import Looper.Core.Path
import Looper.Core.PathAlg
import Looper.Core.Time
import Looper.State.Model
import Looper.State.Predicates
import Looper.State.Status
import Looper.State.Validate
import Looper.State.Loop
import Looper.State.Resume
import Looper.State.Supervise
import Looper.State.Append
import Looper.Io.Fs
import Looper.Io.Signature
import Looper.Io.Env
import Looper.Io.Clock
import Looper.Io.Proc
import Looper.Io.Lock
import Looper.Io.Rand
import Looper.Domain

/-!
`<tool> state <command> --project <p>` — state エンジンの CLI(IO シェル)。

コマンドは read-only(should-stop / should-complete / should-reset / status /
supervise-check)、mutating(ensure / validate / apply-projection)、loop 所有
の mutating(record-progress / raise-loop-gates / start-run / end-run /
reset-context)、human-only の resume。
mutating 系は enforce_bound_project → I-018 スロット(`Io.Lock`)→
コマンド本体の順で走る。

契約:
- stdout: payload JSON 1 行(`ensure_ascii=False` 相当の直列化)
- exit 0 = yes、1 = no、2 = usage・ハード失敗(I-021 の exit-code 規律 —
  予期しない失敗は決して gate の答えとして返さない)
- PROJECT_ROOT の topology 検証(§5.1)は全コマンド共通の frame

IO シェルは 3 手のみ(§31.4-3): 読む → 純粋核(`State.Predicates`)を呼ぶ →
出力する。分岐ロジックは持たない。
-/

namespace Looper.Cli.State

open Looper.Core
open Looper.Core.Prim (expandEquals)
open Looper.State
open Looper.Core.Doc (RawFile)
open Looper.State.Model (EssenceRead)

/-- Python `die`: stderr 1 行 + exit 2。プレフィクスは state.py の
`[state.py] ERROR:` を後継バイナリ名に写したもの(テストは文言本文のみを
照合する)。 -/
private def die (tool msg : String) : IO UInt32 := do
  IO.eprintln s!"[{tool} state] ERROR: {msg}"
  pure 2

private def isFileType (t : IO.FS.FileType) (path : System.FilePath) : IO Bool :=
  try
    pure ((← path.metadata).type == t)
  catch _ =>
    pure false

/-- state.py のテキスト読み(`open(encoding="utf-8")` 系)。不在は `.absent`、
OSError は `.ioError`(読み手が診断へ落とす側)。不正 UTF-8 は Python の
uncaught UnicodeDecodeError(exit 2)に対応する `IO.userError`(呼び出し枠の
ハードエラー catch が exit 2 へ写す)。 -/
private def readRawText (path : System.FilePath) : IO RawFile := do
  if !(← isFileType .file path) then
    return .absent
  try
    let bytes ← IO.FS.readBinFile path
    match String.fromUTF8? bytes with
    | some text => pure (.text text)
    | none => throw (IO.userError s!"{path}: invalid UTF-8 in text file")
  catch
    | .userError msg => throw (.userError msg)
    | e => pure (.ioError (toString e))

/-- ESSENCE.md のバイト読み(`sha256_file` = `read_bytes` に対応)。UTF-8 の
検証は純粋側(`essenceIsPlaceholder`)が placeholder 判定時に行う。 -/
private def readEssence (path : System.FilePath) : IO EssenceRead := do
  if !(← isFileType .file path) then
    return .absent
  try
    pure (.file (← IO.FS.readBinFile path))
  catch e =>
    pure (.ioError (toString e))

/-- essences/ 走査の 1 階層分。`depth` は走査対象エントリの階層(直下 = 1)。
`Essence.maxAssetDepth` を超えるエントリは内容を読まず `tooDeep` に積み、そこから
先へは降りない(§2.1.5 の階層違反として純粋側が報告する)。 -/
private partial def scanEssencesLevel (dir : System.FilePath) (prefix? : String)
    (depth : Nat) :
    IO (Except String (List (String × EssenceRead) × List String × List String)) := do
  let entries ← try
      pure (Sum.inl (← dir.readDir))
    catch e =>
      pure (Sum.inr (toString e))
  match entries with
  | .inr e => pure (.error e)
  | .inl entries =>
    let names := ((entries.map (·.fileName)).toList.filter
      (fun n => !n.startsWith ".")).mergeSort (· ≤ ·)
    let mut files : List (String × EssenceRead) := []
    let mut dirs : List String := []
    let mut tooDeep : List String := []
    for name in names do
      let path := dir / name
      let rel := if prefix?.isEmpty then name else prefix? ++ "/" ++ name
      let t? ← try pure (some (← path.metadata).type) catch _ =>
        pure (none : Option IO.FS.FileType)
      if depth > Looper.Core.Essence.maxAssetDepth then
        tooDeep := tooDeep ++ [rel]
      else
        match t? with
        | some .dir =>
          dirs := dirs ++ [rel]
          match ← scanEssencesLevel path rel (depth + 1) with
          | .error e => return .error e
          | .ok (f, d, td) =>
            files := files ++ f
            dirs := dirs ++ d
            tooDeep := tooDeep ++ td
        | some .file =>
          let read ← try
              pure (EssenceRead.file (← IO.FS.readBinFile path))
            catch e =>
              pure (EssenceRead.ioError (toString e))
          files := files ++ [(rel, read)]
        | some _ | none =>
          -- 壊れた symlink 等: 読めない資産として fail-closed に表面化させる
          files := files ++ [(rel, .ioError s!"unreadable entry: {rel}")]
    pure (.ok (files, dirs, tooDeep))

/-- `PROJECT_ROOT/essences/` の観測(§2.1.5)。`Essence.maxAssetDepth`(3)階層まで
再帰的に走査する。dot 始まりエントリ(`.DS_Store` 等の OS 残骸)はファイル・
ディレクトリとも資産でも違反でもないため除外する。エントリはパス昇順、
ファイル内容の読取失敗は per-file の `.ioError`(純粋側の `essencesManifest` が
ハードエラーへ倒す)。ディレクトリ列挙の失敗は `.ioError`(fail-closed)。 -/
private def readEssencesDir (dir : System.FilePath) : IO Model.EssencesRead := do
  let type? ← try pure (some (← dir.metadata).type) catch _ => pure none
  match type? with
  | none => pure .absent
  | some .dir =>
    match ← scanEssencesLevel dir "" 1 with
    | .error e => pure (.ioError e)
    | .ok (files, dirs, tooDeep) => pure (.dir files dirs tooDeep)
  | some _ => pure .notDir

/-! ## 引数(argparse 対応)と PROJECT_ROOT topology(Python `Ctx`) -/

private structure Args where
  command : String
  project : String
  runId : Option String := none
  status : Option String := none
  runStatus : Option String := none
  note : Option String := none
  todoId : Option String := none
  recommendationId : Option String := none
  resolveIds : List String := []
  retractIds : List String := []
  /-- ドメイン専有フラグ(`Domain.resumeAdjudication?`)が受けた
  (entry id, verdict) 列。綴りは軸が決めるので、ここに製品の綴りは現れない。 -/
  adjudications : List (String × String) := []
  approveShould : Bool := false
  closeAtMust : Bool := false
  steerOnly : Bool := false
  projectionFile : Option String := none
  force : Bool := false

/-- state.py の argparse が受け付ける全コマンド(choices)。**トップレベルの
usage 文字列もここから導く**(`Cli.Main.usage`)— 手書きの一覧を並べていた
あいだ、5h で足した 3 コマンドが usage に載らないまま残っていた。 -/
def allCommands : List String := [
  "ensure", "validate", "should-stop", "record-progress", "raise-loop-gates",
  "should-complete", "should-reset", "start-run", "end-run", "reset-context",
  "resume", "status", "apply-projection", "supervise-check",
  -- §8.2 / §14.3: エージェントが append-only 台帳へ書ける唯一の遷移
  "append-reflection", "append-lesson",
  -- §8.2: 投影 bundle の雛形生成(read-only。tmp/ にしか書かない)
  "stage-projection"
]

/-- state.py `MUTATING_COMMANDS`(enforce_bound_project + I-018 スロットの
枠に入る)。`stage-projection` は canonical state を読むだけだが、bundle 雛形は
「その瞬間の正本」でなければ意味がないので、同じ slot の下で読む。 -/
private def mutatingCommands : List String := [
  "ensure", "validate", "record-progress", "raise-loop-gates", "start-run",
  "end-run", "reset-context", "resume", "apply-projection",
  "append-reflection", "append-lesson", "stage-projection"
]

/-- §28.6 の分類語彙。`usage`(プラン/モデル利用上限)は infra の特定された
下位種別で、別カウンタ・別 gate(§13.1-12')を駆動する。 -/
private def runStatusChoices : List String := ["ok", "infra", "usage", "unknown"]

private structure ArgsAcc where
  command : Option String := none
  project : Option String := none
  runId : Option String := none
  status : Option String := none
  runStatus : Option String := none
  note : Option String := none
  todoId : Option String := none
  recommendationId : Option String := none
  resolveIds : List String := []
  retractIds : List String := []
  /-- ドメイン専有フラグ(`Domain.resumeAdjudication?`)が受けた
  (entry id, verdict) 列。綴りは軸が決めるので、ここに製品の綴りは現れない。 -/
  adjudications : List (String × String) := []
  approveShould : Bool := false
  closeAtMust : Bool := false
  steerOnly : Bool := false
  projectionFile : Option String := none
  force : Bool := false

/-- argparse 相当の引数パース: positional 1 個(command)+ 既知オプション。
`--opt value` と `--opt=value` の両形式、`--run-status` の choices 検証、
`--project` の必須検証。未知・不正は usage エラー(exit 2)。

**ドメイン専有フラグ(`Domain.resumeAdjudication?`)だけは軸から綴りを取る。**
共通のフラグと同じ表に並べられないので、既知フラグを全て外した後の最後の枝で
軸と照合する — 照合に落ちたものは従来どおり `unrecognized arguments` である。 -/
private def parseArgs (d : Domain) (args : List String) : Except String Args :=
  go (args.flatMap expandEquals) {}
where
  go : List String → ArgsAcc → Except String Args
    | [], acc =>
      match acc.command, acc.project with
      | none, _ => .error "the following arguments are required: command"
      | _, none => .error "the following arguments are required: --project"
      | some command, some project =>
        if acc.approveShould && acc.closeAtMust then
          .error "--approve-should and --close-at-must are mutually exclusive"
        else
          .ok { command, project, runId := acc.runId, status := acc.status,
                runStatus := acc.runStatus, note := acc.note,
                todoId := acc.todoId, recommendationId := acc.recommendationId,
                resolveIds := acc.resolveIds, retractIds := acc.retractIds,
                adjudications := acc.adjudications,
                approveShould := acc.approveShould,
                closeAtMust := acc.closeAtMust,
                steerOnly := acc.steerOnly,
                projectionFile := acc.projectionFile, force := acc.force }
    | "--project" :: v :: rest, acc => go rest { acc with project := some v }
    | ["--project"], _ => .error "argument --project: expected one argument"
    | "--run-id" :: v :: rest, acc => go rest { acc with runId := some v }
    | ["--run-id"], _ => .error "argument --run-id: expected one argument"
    | "--status" :: v :: rest, acc => go rest { acc with status := some v }
    | ["--status"], _ => .error "argument --status: expected one argument"
    | "--note" :: v :: rest, acc => go rest { acc with note := some v }
    | ["--note"], _ => .error "argument --note: expected one argument"
    | "--todo" :: v :: rest, acc => go rest { acc with todoId := some v }
    | ["--todo"], _ => .error "argument --todo: expected one argument"
    | "--recommendation" :: v :: rest, acc =>
      go rest { acc with recommendationId := some v }
    | ["--recommendation"], _ =>
      .error "argument --recommendation: expected one argument"
    | "--resolve" :: v :: rest, acc =>
      go rest { acc with resolveIds := acc.resolveIds ++ [v] }
    | ["--resolve"], _ => .error "argument --resolve: expected one argument"
    | "--retract-approval" :: v :: rest, acc =>
      go rest { acc with retractIds := acc.retractIds ++ [v] }
    | ["--retract-approval"], _ =>
      .error "argument --retract-approval: expected one argument"
    | "--approve-should" :: rest, acc => go rest { acc with approveShould := true }
    | "--close-at-must" :: rest, acc => go rest { acc with closeAtMust := true }
    -- §13.3-4''': 他の選択フラグとの排他は engine の `selectionError?` が
    -- 判断する(意図の混線は resume 遷移の意味論であり、argparse の構文規則では
    -- ない)。wrapper はロック取得前の早期拒否として同じ組を二重検査する。
    | "--steer-only" :: rest, acc => go rest { acc with steerOnly := true }
    | "--file" :: v :: rest, acc => go rest { acc with projectionFile := some v }
    | ["--file"], _ => .error "argument --file: expected one argument"
    | "--run-status" :: v :: rest, acc =>
      if runStatusChoices.contains v then go rest { acc with runStatus := some v }
      else .error s!"argument --run-status: invalid choice: '{v}'"
    | ["--run-status"], _ => .error "argument --run-status: expected one argument"
    | "--force" :: rest, acc => go rest { acc with force := true }
    | flag :: rest, acc =>
      if some flag == (d.resumeAdjudication?.map (·.flag)) then
        -- `<id>=<verdict>` の 1 引数形(§13.3)。verdict の語彙検査と受理集合の
        -- 照合は engine(`Resume.selectionError?`)が行い、ここは形だけを見る
        match rest with
        | v :: rest' =>
          let argForm := (d.resumeAdjudication?.map (·.argForm)).getD ""
          match v.splitOn "=" with
          | [id, verdict] =>
            if id.isEmpty || verdict.isEmpty then
              .error s!"argument {flag}: expected {argForm}"
            else go rest' { acc with
              adjudications := acc.adjudications ++ [(id, verdict)] }
          | _ => .error s!"argument {flag}: expected {argForm}"
        | [] => .error s!"argument {flag}: expected one argument"
      else if flag.startsWith "-" then
        .error s!"unrecognized arguments: {flag}"
      else
        match acc.command with
        | none =>
          if allCommands.contains flag then go rest { acc with command := some flag }
          else .error s!"argument command: invalid choice: '{flag}'"
        | some _ => .error s!"unrecognized arguments: {flag}"

/-- Python `Ctx` の解決済みパス文脈。`Cli.Watch`(watch-render、§15.3)が
`resolveCtx` / `stopInputs` と共に再利用する(I-017 — 観測の単一構築点)。 -/
structure Ctx where
  projectRoot : System.FilePath
  title : String
  stateRoot : System.FilePath
  stateDir : System.FilePath
  essence : System.FilePath
  /-- `PROJECT_ROOT/essences/`(§2.1.5 の human-only 資産面)。 -/
  essencesDir : System.FilePath
  controlRoot : System.FilePath
  /-- 製品が注入するドメイン軸(抽出計画 D-9)。観測の単一構築点である `Ctx`
  に載せることで、以降の軸(台帳面・停止理由・書込み面ポリシー)は
  「フィールド追加 + 消費点の置換」だけになる。 -/
  domain : Domain

private def ctxState (ctx : Ctx) (name : String) : System.FilePath :=
  ctx.stateDir / name

/-- Python `ATTESTATION_LEDGER`(§13.1-10、§13.3): should-stop が信頼する
唯一の essence-review 記録。resume だけが追記する。 -/
private def attestationPath (ctx : Ctx) : System.FilePath :=
  ctx.controlRoot / ".agent" / "state" / "essence_attestations.jsonl"

/-- Python `Path.parent`: ルートの親はルート自身。 -/
private def pyParent (p : System.FilePath) : System.FilePath :=
  p.parent.getD p

/-- Python `Ctx.__init__` の topology 検証(§5.1、exit 2 の die ctx.domain.tool 文言も同一)。 -/
def resolveCtx (d : Domain) (projectArg : String) : IO (Except String Ctx) := do
  let some controlRootRaw ← Io.Env.controlRoot?
    | return .error "cannot determine CONTROL_ROOT from the binary location"
  let controlRoot := (← Io.Fs.realPath? controlRootRaw).getD controlRootRaw
  let joined : System.FilePath :=
    if projectArg.startsWith "/" then ⟨projectArg⟩
    else controlRoot / projectArg
  let root ← Io.Fs.resolveNonStrict joined
  if !(← isFileType .dir root) then
    return .error s!"PROJECT_ROOT not found: {root}"
  if root == controlRoot
      || PathAlg.isRelativeToStr root.toString controlRoot.toString then
    return .error "PROJECT_ROOT must not be inside CONTROL_ROOT."
  if root == pyParent controlRoot then
    return .error "PROJECT_ROOT must not be the workspace root itself."
  if pyParent root != pyParent controlRoot then
    return .error ("PROJECT_ROOT must be a sibling of CONTROL_ROOT "
      ++ "(<workspace>/" ++ d.controlDirName ++ " and <workspace>/<project>, META.md §5.1).")
  let title := root.fileName.getD ""
  pure (.ok {
    projectRoot := root
    title
    stateRoot := root / d.controlDirName
    stateDir := root / d.controlDirName / "state"
    essence := root / "ESSENCE.md"
    essencesDir := root / "essences"
    controlRoot
    domain := d
  })

/-! ## サブコマンド本体(読む → 純粋核 → 出力の 3 手) -/

private def controlRunsPath (ctx : Ctx) : System.FilePath :=
  ctx.controlRoot / ".agent" / "state" / "control_runs.jsonl"

/-- ドメインが要求した作業ツリー観測(対象 root 相対パス → 生バイト列の
`sha256:<hex>`、不在は none)。**パスを決めるのは純粋な軸**
(`Domain.observePaths`)であり、ここは読むだけである — 同じ観測を validate と
should-stop が共有する(§13.4-2 の単一観測規律)。 -/
private def observeDomainPaths (ctx : Ctx) (ledgers : List (String × RawFile)) :
    IO (List (String × Option String)) := do
  let docs := ledgers.map fun (name, raw) =>
    (name, match raw with
      | .text text =>
        match Json.parse text with
        | .ok v => v
        | .error _ => Json.Value.obj []
      | _ => Json.Value.obj [])
  (ctx.domain.observePaths docs).eraseDups.mapM fun (path : String) => do
    let fp := ctx.projectRoot / System.FilePath.mk path
    if ← isFileType .file fp then
      pure (path, some ("sha256:" ++ (← Io.Fs.sha256File fp)))
    else
      pure (path, (none : Option String))

/-- ドメイン台帳(`Domain.extraLedgers` の各面)の生読み取り。 -/
private def domainLedgers (ctx : Ctx) : IO (List (String × RawFile)) :=
  ctx.domain.extraLedgers.mapM fun n => do
    pure (n ++ ".json", ← readRawText (ctxState ctx (n ++ ".json")))

private def completionInputs (ctx : Ctx) : IO Predicates.CompletionInputs := do
  -- 台帳と観測は**1 経路**で組み立てる(§13.4-2 の単一観測規律): validate も
  -- should-stop も status も、同じ軸駆動の読みからしか観測を得ない。手で
  -- 面を並べる経路を残すと、軸が増えた瞬間に片方だけが古い集合を見る。
  let ledgers ← domainLedgers ctx
  pure {
    domain := ctx.domain
    todo := ← readRawText (ctxState ctx "todo.json")
    spec := ← readRawText (ctxState ctx "spec.json")
    context := ← readRawText (ctxState ctx "context.json")
    essence := ← readEssence ctx.essence
    ledgers
    observations := ← observeDomainPaths ctx ledgers
  }

private def emit (payload : Json.Value) (yes : Bool) : IO UInt32 := do
  IO.println payload.render
  pure (if yes then 0 else 1)

def stopInputs (ctx : Ctx) : IO Predicates.StopInputs := do
  let completion ← completionInputs ctx
  pure {
    domain := ctx.domain
    stateInitialized := ← isFileType .dir ctx.stateDir
    blockers := ← readRawText (ctxState ctx "blockers.json")
    recommendations := ← readRawText (ctxState ctx "recommendations.json")
    context := completion.context
    project := ← readRawText (ctxState ctx "project.json")
    reflection := ← readRawText (ctxState ctx "reflection.jsonl")
    runs := ← readRawText (ctxState ctx "runs.jsonl")
    ledgers := completion.ledgers
    observations := completion.observations
    attestations := ← readRawText (attestationPath ctx)
    spec := completion.spec
    todo := completion.todo
    essence := completion.essence
    essencesDir := ← readEssencesDir ctx.essencesDir
    projectTitle := ctx.title
  }

private def runShouldStop (ctx : Ctx) : IO UInt32 := do
  match Predicates.shouldStopPayload (← stopInputs ctx) with
  | .ok verdict => emit verdict.payload verdict.stop
  | .error e => throw (IO.userError e)

private def runShouldComplete (ctx : Ctx) : IO UInt32 := do
  match Predicates.completionPayload (← completionInputs ctx) with
  | .ok verdict => emit verdict.payload verdict.complete
  | .error e => throw (IO.userError e)

private def runShouldReset (ctx : Ctx) : IO UInt32 := do
  match Predicates.shouldResetPayload (← readRawText (ctxState ctx "context.json")) with
  | .ok (payload, reset) => emit payload reset
  | .error e => throw (IO.userError e)

/-- `cmd_status`: 人間向けサマリ。常に exit 0(診断は表示に落とす)だが、
Python が未捕捉例外で落ちる入力は「そこまでの行を出力してから exit 2」
(純粋核 `Status.statusRender` が部分出力を返す)。 -/
private def runStatus (ctx : Ctx) : IO UInt32 := do
  -- gate 入力は `stopInputs` の 1 経路だけ(I-017): should-stop と同じ観測を
  -- そのまま渡す。status 側で組み直さないことが、表示と述語の一致の根拠。
  let (lines, hardError) := Status.statusRender {
    projectRoot := ctx.projectRoot.toString
    stateIndex := ← readRawText (ctxState ctx "state_index.json")
    validation := ← readRawText (ctxState ctx "validation.json")
    stop := ← stopInputs ctx
    validationCheck := ← readRawText
      (ctx.stateRoot / "tmp" / Validate.checkStampFile)
  }
  for line in lines do
    IO.println line
  match hardError with
  | some e => throw (IO.userError e)
  | none => pure 0

/-- `just supervise` の read-only canonical preflight。対話 session を起動する
前に exact Todo / optional Recommendation / shared target を機械照合する。 -/
private def runSuperviseCheck (ctx : Ctx) (args : Args) : IO UInt32 := do
  let some todoId := args.todoId
    | return ← die ctx.domain.tool "supervise-check requires --todo T-..."
  let outcome := Supervise.preflight {
    tool := ctx.domain.tool
    todo := ← readRawText (ctxState ctx "todo.json")
    recommendations := ← readRawText (ctxState ctx "recommendations.json")
    todoId
    recommendationId := args.recommendationId
  }
  match outcome with
  | .ok payload =>
    IO.println payload.render
    pure 0
  | .error error =>
    IO.println (Json.Value.obj [
      ("ok", .bool false), ("error", .str error)]).render
    pure 1

/-! ## mutating サブコマンド(ensure / validate) -/

/-- 表示タイムゾーン付きの現在時刻(Python `now_local`。表示 TZ ENV は
オフセット方言 — META.md §8.4-2)。 -/
private def nowLocal (d : Domain) : IO String :=
  Io.Clock.nowLocal (d.envPrefix ++ "_TZ")

/-- Python `datetime.now(display_tz()).strftime("%Y%m%dT%H%M%S%z")`
(run_id / loop-gate id / lesson id のスタンプ)。 -/
private def compactNow (d : Domain) : IO String := do
  let offsetMinutes := (((← IO.getEnv (d.envPrefix ++ "_TZ")).getD "")
    |> Core.Time.parseTzOffset?).getD Core.Time.defaultOffsetMinutes
  pure (Core.Time.compactTimestamp (← Io.Clock.epochSeconds) offsetMinutes)

/-- Python `append_jsonl`(失敗は uncaught OSError = ハードエラー枠)。 -/
private def appendJsonlOrThrow (path : System.FilePath) (record : Json.Value) :
    IO Unit := do
  if let .error e := ← Io.Fs.appendJsonl path record then
    throw (IO.userError e)

/-- Python `project_worktree_changes`: git 不在扱い(rev-parse 失敗・status
失敗)は none。パースは純粋側 `Validate.parseWorktreeChanges`。 -/
private def projectWorktreeChanges (ctx : Ctx) : IO (Option (List String)) := do
  let top ← Io.Proc.git ctx.projectRoot ["rev-parse", "--show-toplevel"]
  let gitRoot := Text.pyStrip top.stdout
  if top.exitCode != 0 || gitRoot.isEmpty then
    return none
  let st ← Io.Proc.git ctx.projectRoot
    ["status", "--porcelain", "--untracked-files=all", "--", "."]
  if st.exitCode != 0 then
    return none
  pure (some (Validate.parseWorktreeChanges gitRoot ctx.projectRoot.toString st.stdout))

/-- `PROJECT_ROOT/*/recipe.lock.json`(パス順)を読む。dict にパースできない
もの(OSError / JSONDecodeError / 非 dict)は none。**dot 始まりの instance
ディレクトリも走査する** — 同梱レシピの既定 `loop_dir` は `.loop/` であり
(§29.5)、走査規約(§29.4「深さ 2」)に dot 除外は無い。旧 Python glob の
dot 除外をここに写すと、既定設置の instance が §29.4 の全突き合わせ
(未設置 warning の解消・major 不一致・source hash drift)から永久に消える。 -/
private def readRecipeLocks (ctx : Ctx) : IO (List Validate.RecipeLockObs) := do
  let entries ← try
      ctx.projectRoot.readDir
    catch _ =>
      pure #[]
  let names := ((entries.map (·.fileName)).toList.filter
    (fun n => n != ".git")).mergeSort (· ≤ ·)
  let mut locks : List Validate.RecipeLockObs := []
  for name in names do
    let path := ctx.projectRoot / name / "recipe.lock.json"
    if ← path.pathExists then
      let lock? := match ← readRawText path with
        | .text contents =>
          match Json.parse contents with
          | .ok v => match v with
            | .obj _ => some v
            | _ => none
          | .error _ => none
        | _ => none
      locks := locks ++ [⟨s!"{name}/recipe.lock.json", lock?⟩]
  pure locks

/-- ESSENCE.md のポインタ名ごとの recipes/ 観測。source hash は「dir 実在 +
同名の有効 lock あり」の名前だけ計算する(Python の遅延評価と同じ読み量)。 -/
private def readRecipeDirs (ctx : Ctx) (pointers : List (String × Nat))
    (lockNames : List String) : IO (List Validate.RecipeDirObs) := do
  let mut out : List Validate.RecipeDirObs := []
  for name in (pointers.map (·.1)).eraseDups do
    let dir := ctx.controlRoot / "recipes" / name
    let isDir ← isFileType .dir dir
    let hash? ← if isDir && lockNames.contains name then
        pure (some (← Io.Signature.recipeSourceHash dir))
      else
        pure none
    out := out ++ [⟨name, isDir, hash?⟩]
  pure out

private def collectValidateInputs (ctx : Ctx)
    (overrides : List (String × RawFile) := []) : IO Validate.Inputs := do
  let essence ← readEssence ctx.essence
  -- Python は won't 項目が無ければ git を呼ばない(fail-soft の読み量も同一)
  let worktree ← if (Validate.essenceWontItemsOf ctx.domain essence).isEmpty then
      pure none
    else
      projectWorktreeChanges ctx
  let pointers := Validate.essencePointersOf essence
  let locks ← readRecipeLocks ctx
  let dirs ← readRecipeDirs ctx pointers (Validate.recipeLockNames locks)
  -- 投影台帳(§8.2)は apply-projection の prospective 差し替えを受ける
  let readOr (name : String) : IO RawFile :=
    match overrides.find? (·.1 == name) with
    | some (_, raw) => pure raw
    | none => readRawText (ctxState ctx name)
  -- ドメイン台帳と、ドメインが要求する作業ツリー観測。
  -- **パスを決めるのは純粋な軸、読むのは IO シェル**という分業であり、
  -- ドメイン論理は IO へ漏れない。
  let ledgers ← ctx.domain.extraLedgers.mapM fun n => do
    pure (n ++ ".json", ← readOr (n ++ ".json"))
  let observations ← observeDomainPaths ctx ledgers
  pure {
    domain := ctx.domain
    ledgers
    observations
    title := ctx.title
    stateInitialized := ← isFileType .dir ctx.stateDir
    essence
    essences := ← readEssencesDir ctx.essencesDir
    stateIndex := ← readRawText (ctxState ctx "state_index.json")
    project := ← readRawText (ctxState ctx "project.json")
    spec := ← readOr "spec.json"
    todo := ← readOr "todo.json"
    recommendations := ← readOr "recommendations.json"
    blockers := ← readOr "blockers.json"
    context := ← readRawText (ctxState ctx "context.json")
    validation := ← readRawText (ctxState ctx "validation.json")
    reflection := ← readRawText (ctxState ctx "reflection.jsonl")
    runs := ← readRawText (ctxState ctx "runs.jsonl")
    highRisk := ← readRawText (ctxState ctx "high_risk_changes.jsonl")
    lessons := ← readRawText (ctxState ctx "lessons.jsonl")
    controlRuns := ← readRawText (controlRunsPath ctx)
    projectIndex := ← readRawText
      (ctx.controlRoot / ".agent" / "state" / "project_index.json")
    worktree
    recipeLocks := locks
    recipeDirs := dirs
    now := ← nowLocal ctx.domain
  }

/-- §20.5-3: 鮮度マーカーを `PROJECT_STATE_ROOT/tmp/` へ置く。git 追跡外なので
毎回書いても §20.5-1 の冪等性(同一診断の再検査で worktree を汚さない)は
崩れない。best-effort — 書けなくても validate の判定には一切影響しない。 -/
private def writeValidationCheckStamp (ctx : Ctx) (stamp : Json.Value) :
    IO Unit := do
  try
    let dir := ctx.stateRoot / "tmp"
    IO.FS.createDirAll dir
    Io.Fs.writeJsonPretty (dir / Validate.checkStampFile) stamp
  catch _ =>
    pure ()

private def runValidate (ctx : Ctx) : IO UInt32 := do
  match Validate.validateCore (← collectValidateInputs ctx) with
  | .error e => throw (IO.userError e)
  | .ok outcome =>
    if outcome.write then
      Io.Fs.writeJsonPretty (ctxState ctx "validation.json") outcome.payload
    writeValidationCheckStamp ctx outcome.checkStamp
    IO.println outcome.payload.renderPretty
    pure (if outcome.hasErrors then 1 else 0)

/-! ## projection mutation API

Agent-authored map state is submitted as one JSON bundle containing a non-empty
subset of `spec.json` / `todo.json` / `recommendations.json` / `blockers.json`.
The complete prospective state is validated before the first write; accepted
files are then replaced with the same per-file atomic writer used by every
framework transition. -/

private def runApplyProjection (ctx : Ctx) (args : Args) : IO UInt32 := do
  let some file := args.projectionFile
    | return ← die ctx.domain.tool "apply-projection requires --file <bundle.json>"
  let raw ← readRawText ⟨file⟩
  let contents ← match raw with
    | .absent => return ← die ctx.domain.tool s!"projection bundle does not exist: {file}"
    | .ioError e => return ← die ctx.domain.tool s!"projection bundle is unreadable: {e}"
    | .text text => pure text
  let bundle ← match Json.parse contents with
    | .error e => return ← die ctx.domain.tool s!"projection bundle is invalid JSON: {e}"
    | .ok (.obj entries) => pure entries
    | .ok _ => return ← die ctx.domain.tool "projection bundle top-level value must be an object"
  if bundle.isEmpty then
    return ← die ctx.domain.tool "projection bundle must contain at least one canonical projection file"
  -- 重複 key は JSON パーサのオブジェクト意味論(後勝ち)で既に 1 key に
  -- 畳まれており、ここに届く names に重複は存在しない(§20.2-8)。
  let names := bundle.map (·.1)
  if let some unknown := names.find? (!ctx.domain.projectionFiles.contains ·) then
    return ← die ctx.domain.tool s!"projection bundle contains unsupported file: {unknown}"
  if let some bad := bundle.find? fun (_, value) =>
      match value with | .obj _ => false | _ => true then
    return ← die ctx.domain.tool s!"projection bundle entry {bad.1} must be an object"

  -- §8.2 / §20.2-8: spec.json を含む bundle は、現在の ESSENCE.md から投影
  -- されたことを stamp(projected_from_essence_sha256)の一致で示さなければ
  -- ならない。stale 投影を書けないことが、読み取り側 validate が drift 中の
  -- per-ref trace error を集約 warning へ落とす §20.2-7 の安全前提である。
  -- ESSENCE.md 不在・不読はここでは黙過し、validateCore が error にする。
  if let some (_, specValue) := bundle.find? (·.1 == "spec.json") then
    if let .ok (some current) := Predicates.essenceSha256 (← readEssence ctx.essence) then
      let stamped := Validate.getN specValue "projected_from_essence_sha256"
      if !Validate.pyEq stamped (.str current) then
        return ← die ctx.domain.tool ("projection bundle spec.json must carry "
          ++ "projected_from_essence_sha256 equal to the current ESSENCE.md "
          ++ s!"SHA-256 ({current}); found {Status.pyRepr stamped} — re-project "
          ++ "Spec from the current Essence before applying (§8.2)")

  -- ドメインの**書込み前**拒否面(§8.2)。共通の受理条件を通っても、
  -- 「エージェントが自分の発見を握りつぶす」類の経路はドメインにしか判定
  -- できない。最初の書込みより前に落とすのが要件なので validate とは別口。
  let domainFaces := ctx.domain.extraLedgers.map (· ++ ".json")
  let prospective := bundle.filter (domainFaces.contains ·.1)
  if !prospective.isEmpty then
    let current ← prospective.mapM fun (name, _) => do
      pure (name, match ← readRawText (ctxState ctx name) with
        | .text text =>
          match Json.parse text with
          | .ok v => v
          | .error _ => Json.Value.obj []
        | _ => Json.Value.obj [])
    if let some msg := ctx.domain.projectionRefusal current prospective then
      return ← die ctx.domain.tool msg

  let outcome ← match Validate.validateCore (← collectValidateInputs ctx
      (bundle.map fun (name, value) => (name, .text value.render))) with
    | .error e => throw (IO.userError e)
    | .ok outcome => pure outcome
  if outcome.hasErrors then
    IO.println outcome.payload.renderPretty
    return 1
  for (name, value) in bundle do
    Io.Fs.writeJsonPretty (ctxState ctx name) value
  if outcome.write then
    Io.Fs.writeJsonPretty (ctxState ctx "validation.json") outcome.payload
  writeValidationCheckStamp ctx outcome.checkStamp
  IO.println (outcome.payload.set "applied" (.arr (names.map .str))).renderPretty
  pure 0

/-! ## append-reflection / append-lesson(§14.3、エージェント所有の追記面)

Edit ツールによる手書き追記が生んだ 3 種の実害(順序逆転・スキーマ揺れ・
run_id 転写漏れ)を、追記点を 1 つの遷移へ閉じることで同時に消す。判定は
すべて純粋核 `State.Append`、ここは「読む → 呼ぶ → 書く」だけ。 -/

private def runAppendLedger (ctx : Ctx) (args : Args)
    (ledger : State.Append.Ledger) : IO UInt32 := do
  let some file := args.projectionFile
    | return ← die ctx.domain.tool s!"{args.command} requires --file <entry.json>"
  let raw ← readRawText ⟨file⟩
  let contents ← match raw with
    | .absent => return ← die ctx.domain.tool s!"entry file does not exist: {file}"
    | .ioError e => return ← die ctx.domain.tool s!"entry file is unreadable: {e}"
    | .text text => pure text
  let entry ← match Json.parse contents with
    | .error e => return ← die ctx.domain.tool s!"entry file is invalid JSON: {e}"
    | .ok v => pure v
  let errs := State.Append.entryErrors ledger entry
  if !errs.isEmpty then
    return ← die ctx.domain.tool (State.Append.rejection ledger errs)
  -- I-021: project.json は cycle 連番と last_run_id のアンカー。刻印は
  -- canonical state の事実であって呼び出し側の申告ではないので、読めなければ
  -- 追記しない(誤った cycle 番号の恒久化は台帳を壊す)。
  if !(← isFileType .file (ctxState ctx "project.json")) then
    return ← die ctx.domain.tool ("project.json is missing from the initialized state directory; "
      ++ "restore it (git restore) before appending to a ledger.")
  match Loop.startRunGate (← readRawText (ctxState ctx "project.json")) with
  | .error msg =>
    -- gate の文言は start-run 向け(「start-run に再構築させるな」)なので、
    -- 追記コマンドの利用者には修復指示だけを残して主語を差し替える。
    die ctx.domain.tool ("project.json is unreadable or has lost its shape; "
      ++ "repair it (git restore) before appending to a ledger. "
      ++ s!"[{msg}]")
  | .ok project =>
    let (cycle, runId) := State.Append.stampsFromProject project
    let stamps : State.Append.Stamps := {
      now := ← nowLocal ctx.domain
      cycle
      runId
      lessonId := s!"L-{← compactNow ctx.domain}-{← Io.Rand.randomHex 2}" }
    let entryRecord := State.Append.record ledger stamps entry
    appendJsonlOrThrow (ctxState ctx ledger.fileName) entryRecord
    IO.println (State.Append.payload ledger entryRecord).render
    pure 0

/-! ## stage-projection(§8.2)

投影 7 面は Edit/Write が deny なので、変更は必ず bundle → `apply-projection`
を通る。ところが bundle の「現状」部分を作る手段が無かったため、実走行では
「`cp /dev/null` で空 .py を作り、ビルダースクリプトを Write し、`python3` で
bundle JSON を生成し、apply して、両ファイルを絶対パスで rm する」という
儀式が handoff で伝承されていた。現在の正本をそのまま雛形として吐けば、
エージェントは**それを編集して apply する**だけでよい。

出力先は gitignore 済みの `PROJECT_STATE_ROOT/tmp/` — 雛形が worktree を汚して
次 cycle の I-014 を落とすことがない。 -/

private def runStageProjection (ctx : Ctx) : IO UInt32 := do
  let dir := ctx.stateRoot / "tmp"
  IO.FS.createDirAll dir
  let mut entries : List (String × Json.Value) := []
  let mut missing : List String := []
  for name in ctx.domain.projectionFiles do
    match ← readRawText (ctxState ctx name) with
    | .text text =>
      match Json.parse text with
      | .ok v => entries := entries ++ [(name, v)]
      | .error e => return ← die ctx.domain.tool s!"{name} is invalid JSON ({e}); repair it first"
    | .absent => missing := missing ++ [name]
    | .ioError e => return ← die ctx.domain.tool s!"{name} is unreadable: {e}"
  if !missing.isEmpty then
    return ← die ctx.domain.tool ("cannot stage a projection bundle while canonical files are "
      ++ s!"missing: {String.intercalate ", " missing} — run `state ensure` first")
  let out := dir / "projection_bundle.json"
  Io.Fs.writeJsonPretty out (.obj entries)
  IO.println (Json.Value.obj [
    ("staged", .str out.toString),
    ("files", .arr (entries.map fun e => .str e.1)),
    ("next", .str ("edit the staged bundle, delete the files you are not "
      ++ "changing, then run: " ++ ctx.domain.binCommand
      ++ " state apply-projection --file "
      ++ out.toString ++ " --project <p>"))]).render
  pure 0

private def runEnsure (ctx : Ctx) : IO UInt32 := do
  -- I-021: 初期化済み state の gate-holding 欠損は die(再構築拒否)
  if ← isFileType .dir ctx.stateDir then
    let mut missing : List String := []
    for n in Validate.gateStateFiles ctx.domain do
      if !(← isFileType .file (ctxState ctx n)) then
        missing := missing ++ [n]
    if !missing.isEmpty then
      return ← die ctx.domain.tool (Validate.ensureRefusalMessage missing)
  let mut created : Array String := #[]
  for d in [ctx.stateDir, ctx.stateRoot / "tmp"] do
    if !(← isFileType .dir d) then
      IO.FS.createDirAll d
      created := created.push d.toString
  -- defaults の組み立て(Python 同様、書くものが無くても essence を読む)
  let essenceSha ← match Predicates.essenceSha256 (← readEssence ctx.essence) with
    | .ok v => pure v
    | .error e => throw (IO.userError e)
  -- essences/ anchor(§13.1-10 拡張): 読取不能はハードエラー(I-021)
  let essencesManifest ← match
      Predicates.essencesManifest (← readEssencesDir ctx.essencesDir) with
    | .ok m => pure m
    | .error e => throw (IO.userError e)
  let now ← nowLocal ctx.domain
  let defaults := Validate.initialState ctx.domain now ctx.title essenceSha
    essencesManifest
  for name in Validate.canonicalJson ctx.domain do
    let path := ctxState ctx name
    if !(← isFileType .file path) then
      Io.Fs.writeJsonPretty path (((defaults.find? (·.1 == name)).map (·.2)).getD (.obj []))
      created := created.push path.toString
  for name in Validate.canonicalJsonl do
    let path := ctxState ctx name
    if !(← isFileType .file path) then
      IO.FS.writeFile path ""
      created := created.push path.toString
  -- control-plane registry(§8.1)への登録
  let indexPath := ctx.controlRoot / ".agent" / "state" / "project_index.json"
  let alreadyRegistered ← isFileType .file indexPath
  let indexRaw ← readRawText indexPath
  let relRoot := Core.Path.relpath ctx.controlRoot.toString ctx.projectRoot.toString
  let relState := Core.Path.relpath ctx.controlRoot.toString ctx.stateRoot.toString
  match Validate.ensureIndexUpdate indexRaw alreadyRegistered ctx.title
      relRoot relState now with
  | .error msg => die ctx.domain.tool msg
  | .ok idx? =>
    if let some idx := idx? then
      Io.Fs.writeJsonPretty indexPath idx
      if !alreadyRegistered then
        created := created.push indexPath.toString
    IO.println (Validate.ensurePayload created.toList).renderPretty
    pure 0

/-! ## mutating サブコマンド(loop 系) -/

/-- Python `git_progress_file_entries`: `git ls-files --cached --others
--exclude-standard -z` の NUL 区切り出力から、除外ディレクトリと不在
(削除済み index エントリ等)を除いた `(rel, sha256)` を rel 順に返す。
git 不在・非リポジトリ(exit ≠ 0)は none = walk フォールバック。 -/
private def gitProgressEntries? (ctx : Ctx) :
    IO (Option (List (String × String))) := do
  let out ← Io.Proc.git ctx.projectRoot
    ["ls-files", "--cached", "--others", "--exclude-standard", "-z"]
  if out.exitCode != 0 then
    return none
  let mut entries : List (String × String) := []
  for slice in out.stdout.split (· == Char.ofNat 0) do
    let raw := slice.toString
    if raw.isEmpty then
      continue
    if Loop.isProgressExcluded raw (Loop.progressExcludedDirs ctx.domain) then
      continue
    let path := ctx.projectRoot / raw
    if ← isFileType .file path then
      entries := entries ++ [(raw, ← Io.Fs.sha256File path)]
  pure (some (entries.mergeSort (fun a b => a.1 ≤ b.1)))

/-- Python `compute_progress_signature` の観測収集 + 純粋核呼び出し。 -/
private def computeProgressSignature (ctx : Ctx) : IO String := do
  let projectEntries ← match ← gitProgressEntries? ctx with
    | some entries => pure entries
    | none =>
      Io.Signature.progressFileEntries ctx.projectRoot
        (Loop.progressExcludedDirs ctx.domain)
  let mut controlEntries : List (String × String) := []
  for rel in Loop.controlProgressPaths do
    for (entryRel, digest) in
        ← Io.Signature.progressFileEntries (ctx.controlRoot / rel)
          (Loop.progressExcludedDirs ctx.domain) do
      controlEntries := controlEntries ++ [(s!"{rel}/{entryRel}", digest)]
  let mut ledgers : List (String × RawFile) := []
  for name in ctx.domain.projectionFiles do
    ledgers := ledgers ++ [(name, ← readRawText (ctxState ctx name))]
  pure (Loop.progressSignature {
    ledgers
    highRisk := ← readRawText (ctxState ctx "high_risk_changes.jsonl")
    projectEntries
    controlEntries := controlEntries.mergeSort (fun a b => a.1 ≤ b.1)
  })

private def runRecordProgress (ctx : Ctx) (args : Args) : IO UInt32 := do
  -- I-021: 初期化済み state からの欠落は破損と同じ(再構築拒否)
  if !(← isFileType .file (ctxState ctx "context.json")) then
    return ← die ctx.domain.tool ("context.json is missing from the initialized state directory; "
      ++ "restore it (git restore) before recording progress.")
  match Loop.recordProgressGate (← readRawText (ctxState ctx "context.json")) with
  | .error msg => die ctx.domain.tool msg
  | .ok gate =>
    let current ← computeProgressSignature ctx
    let outcome := Loop.recordProgressApply ctx.domain gate current args.runStatus
      (← nowLocal ctx.domain)
    Io.Fs.writeJsonPretty (ctxState ctx "context.json") outcome.newContext
    IO.println outcome.payload.render
    pure 0

private def runRaiseLoopGates (ctx : Ctx) : IO UInt32 := do
  let stopVerdict ← match Predicates.shouldStopPayload (← stopInputs ctx) with
    | .ok v => pure v
    | .error e => throw (IO.userError e)
  let completion ← match Predicates.completionPayload (← completionInputs ctx) with
    | .ok v => pure v
    | .error e => throw (IO.userError e)
  let stamp ← compactNow ctx.domain
  -- 1 回の raise が使いうる suffix は gate 種別数の 5(実体化は must 境界と
  -- no_runnable_todos が排他なので同時に最大 4)。id は `R-LG-<stamp>-<suffix>` で
  -- stamp を共有する。suffix が衝突すると 2 つの gate Recommendation が同一 id
  -- を持ち、(a) validate の id 一意検査(S-T5)が error になり、(b) 人間の
  -- `resume --resolve <id>` が意図しない方の gate まで resolved にする
  -- (§13.3-4 の「1 件の確認が他の未確認ゲートまで消さない」破れ)。
  -- 4 hex(65536 通り)の誕生日衝突は約 1e-4/raise で無視できないため、
  -- pairwise distinct になるまで引き直す(引き直し回数は有界にし、尽きたら
  -- 決定的な連番接尾で必ず distinct を返す — 乱数枯渇でループしない)。
  let mut suffixes : List String := []
  let mut attempts := 0
  while suffixes.length < 5 && attempts < 64 do
    attempts := attempts + 1
    let s ← Io.Rand.randomHex 2
    unless suffixes.contains s do
      suffixes := suffixes ++ [s]
  for k in [suffixes.length:5] do
    suffixes := suffixes ++ [s!"x{k}"]
  let ids : List (String × String) := suffixes.map fun s => (stamp, s)
  let outcome := Loop.raiseLoopGatesCore {
    domain := ctx.domain
    stopPayload := stopVerdict.payload
    completion := completion.payload
    todo := ← readRawText (ctxState ctx "todo.json")
    recommendations := ← readRawText (ctxState ctx "recommendations.json")
    ids
    now := ← nowLocal ctx.domain }
  if let some recs := outcome.newRecs then
    Io.Fs.writeJsonPretty (ctxState ctx "recommendations.json") recs
  if let some reflection := outcome.reflection then
    appendJsonlOrThrow (ctxState ctx "reflection.jsonl") reflection
  IO.println outcome.payload.render
  pure 0

private def runStartRun (ctx : Ctx) : IO UInt32 := do
  -- I-021: project.json は attestation chain のアンカー(§13.1-10)—
  -- start レコードを書く前に検査する(後で die ctx.domain.tool すると dangling run が残る)
  if !(← isFileType .file (ctxState ctx "project.json")) then
    return ← die ctx.domain.tool ("project.json is missing from the initialized state directory; "
      ++ "restore it (git restore) before starting a run.")
  match Loop.startRunGate (← readRawText (ctxState ctx "project.json")) with
  | .error msg => die ctx.domain.tool msg
  | .ok project =>
    let runId := s!"R-{← compactNow ctx.domain}-{← Io.Rand.randomHex 3}"
    let cwd ← IO.currentDir
    let outcome := Loop.startRunApply project runId (← nowLocal ctx.domain) cwd.toString ctx.title
    appendJsonlOrThrow (ctxState ctx "runs.jsonl") outcome.record
    appendJsonlOrThrow (controlRunsPath ctx) outcome.record
    Io.Fs.writeJsonPretty (ctxState ctx "project.json") outcome.newProject
    IO.println runId
    pure 0

private def runEndRun (ctx : Ctx) (args : Args) : IO UInt32 := do
  -- Python `if not args.run_id`: 未指定も空文字も usage 側の die
  if (args.runId.getD "").isEmpty then
    return ← die ctx.domain.tool "end-run requires --run-id"
  let record := Loop.endRunRecord (args.runId.getD "") args.status
    (← nowLocal ctx.domain) ctx.title
  appendJsonlOrThrow (ctxState ctx "runs.jsonl") record
  appendJsonlOrThrow (controlRunsPath ctx) record
  IO.println record.render
  pure 0

private def runResetContext (ctx : Ctx) : IO UInt32 := do
  -- I-021: gate-holding context.json の欠落・破損は再構築せず die
  if !(← isFileType .file (ctxState ctx "context.json")) then
    return ← die ctx.domain.tool ("context.json is missing from the initialized state directory; "
      ++ "restore it (git restore) before resetting context.")
  match Loop.resetContextGate (← readRawText (ctxState ctx "context.json")) with
  | .error msg => die ctx.domain.tool msg
  | .ok context =>
    match Loop.resetContextApply context (← nowLocal ctx.domain) with
    | .error e => throw (IO.userError e)
    | .ok outcome =>
      Io.Fs.writeJsonPretty (ctxState ctx "context.json") outcome.newContext
      appendJsonlOrThrow (ctxState ctx "reflection.jsonl") outcome.reflection
      IO.println outcome.payload.render
      pure 0

/-! ## mutating サブコマンド(resume、human-only) -/

/-- 純粋核の `.error` を Python の uncaught 例外(exit 2 のハードエラー枠)へ
写す。 -/
private def liftE (x : Except String α) : IO α :=
  match x with
  | .ok v => pure v
  | .error e => throw (IO.userError e)

/-- Python `git_worktree_changes`(state.py L2567): PROJECT_ROOT を含む
worktree の未コミットパス(git root 相対、untracked 含む)。git 不在・
非リポジトリ・status 失敗は none = 「不明」(clean ではない — 呼び出し側の
noop 判定は `some []` のみを clean と読む)。`project_worktree_changes` と
違い `-- .` の範囲制限をせず、パスの引用剥ぎもしない。 -/
private def gitWorktreeChanges (ctx : Ctx) : IO (Option (List String)) := do
  let top ← Io.Proc.git ctx.projectRoot ["rev-parse", "--show-toplevel"]
  let gitRoot := Text.pyStrip top.stdout
  if top.exitCode != 0 || gitRoot.isEmpty then
    return none
  let st ← Io.Proc.git ⟨gitRoot⟩
    ["status", "--porcelain", "--untracked-files=all"]
  if st.exitCode != 0 then
    return none
  pure (some (Resume.gitStatusPaths st.stdout))

/-- Python `cmd_resume` + `_resume_transition`(L2776–3074)。拒否(exit 1)
と noop / 完了(exit 0)の決定はすべて純粋核 `State.Resume`。IO は観測
(state 読み・git・時刻)と Plan の適用(書き込み列 + post 再評価)のみ。 -/
private def runResume (ctx : Ctx) (args : Args) : IO UInt32 := do
  let refuse (error : String) : IO UInt32 := do
    IO.println (Resume.refusePayload error).render
    pure 1
  -- 前提(§13.3 0→1、L2794–2813 + §2.1.5 の essences 整合)
  let essence ← readEssence ctx.essence
  let essencesDir ← readEssencesDir ctx.essencesDir
  let pre? ← liftE (Resume.preconditionError? ctx.domain
    (← isFileType .dir ctx.stateDir) ctx.stateDir.toString essence essencesDir)
  if let some err := pre? then
    return ← refuse err
  -- I-021: 読めない runs.jsonl は「in-flight 不明」— --force でも拒否
  let (inFlight, runsDiags) ← liftE (Resume.unfinishedRunIds
    (← readRawText (ctxState ctx "runs.jsonl")))
  if !runsDiags.isEmpty then
    return ← refuse (Resume.runsUnreadableError runsDiags)
  if !inFlight.isEmpty && !args.force then
    return ← refuse (← liftE (Resume.inFlightError inFlight))
  -- 最初の書き込み前に全観測(L2841–2867)
  let preStop ← liftE (Predicates.shouldStopPayload (← stopInputs ctx))
  if let some err := Resume.stateUnreadableError? preStop.payload then
    return ← refuse err
  let inputs : Resume.TransitionInputs := {
    domain := ctx.domain
    stopPayload := preStop.payload
    blockersRaw := ← readRawText (ctxState ctx "blockers.json")
    recsRaw := ← readRawText (ctxState ctx "recommendations.json")
    contextRaw := ← readRawText (ctxState ctx "context.json")
    specRaw := ← readRawText (ctxState ctx "spec.json")
    todoRaw := ← readRawText (ctxState ctx "todo.json")
    essenceSha := ← liftE (Predicates.essenceSha256 essence)
    essencesManifest := ← liftE (Predicates.essencesManifest essencesDir)
    inFlight
    force := args.force
    noteArg := args.note
    resolveIds := args.resolveIds
    retractIds := args.retractIds
    adjudications := args.adjudications
    domainLedgers := ← domainLedgers ctx
    phaseDecision := if args.approveShould then some "approve_should"
      else if args.closeAtMust then some "close_at_must" else none
    steerOnly := args.steerOnly
    worktree := ← gitWorktreeChanges ctx
    now := ← nowLocal ctx.domain
    title := ctx.title
    projectRootRel := Core.Path.relpath ctx.controlRoot.toString
      ctx.projectRoot.toString
  }
  if let some err := Resume.selectionError? inputs then
    return ← refuse err
  match Resume.transition inputs with
  | .noop payload =>
    IO.println payload.renderPretty
    pure 0
  | .proceed plan =>
    for record in plan.runRecords do
      appendJsonlOrThrow (ctxState ctx "runs.jsonl") record
      appendJsonlOrThrow (controlRunsPath ctx) record
    if let some blockers := plan.newBlockers then
      Io.Fs.writeJsonPretty (ctxState ctx "blockers.json") blockers
    if let some recs := plan.newRecs then
      Io.Fs.writeJsonPretty (ctxState ctx "recommendations.json") recs
    -- I-033: ドメイン台帳への裁定書込みは resume の専有である(投影経路は
    -- 同じ集合を `projectionRefusal` が拒否する)
    if let some (name, doc) := plan.newDomainLedger then
      Io.Fs.writeJsonPretty (ctxState ctx name) doc
    Io.Fs.writeJsonPretty (ctxState ctx "context.json") plan.newContext
    appendJsonlOrThrow (ctxState ctx "reflection.jsonl") plan.reflection
    appendJsonlOrThrow (attestationPath ctx) plan.attestation
    -- 完了した resume は常に exit 0(L3050–3054): 解放済み latch を
    -- 未コミットのまま漂流させない。残る停止条件は post 再評価として報告
    -- するだけで、次の loop を再 gate する
    let postStop ← liftE (Predicates.shouldStopPayload (← stopInputs ctx))
    IO.println (Resume.finalPayload ctx.domain plan postStop.payload).renderPretty
    pure 0

/-- mutating 系の共通枠(state.py `main()` の if 分岐):
enforce_bound_project → I-018 スロット → コマンド本体。 -/
private def runMutating (ctx : Ctx) (args : Args) : IO UInt32 := do
  let indexRaw ← readRawText
    (ctx.controlRoot / ".agent" / "state" / "project_index.json")
  match Validate.enforceBoundDecision indexRaw with
  | .error msg => die ctx.domain.tool msg
  | .ok rel? =>
    let mismatch? ← match rel? with
      | none => pure none
      | some rel => do
        let root ← Io.Fs.resolveNonStrict (ctx.controlRoot / rel)
        if root == ctx.projectRoot then
          pure none
        else
          pure (some (Validate.boundMismatchMessage ctx.projectRoot.toString
            root.toString))
    match mismatch? with
    | some msg => die ctx.domain.tool msg
    | none =>
      Io.Lock.withSlot ctx.domain ctx.controlRoot (die ctx.domain.tool) <|
        match args.command with
        | "ensure" => runEnsure ctx
        | "record-progress" => runRecordProgress ctx args
        | "raise-loop-gates" => runRaiseLoopGates ctx
        | "start-run" => runStartRun ctx
        | "end-run" => runEndRun ctx args
        | "reset-context" => runResetContext ctx
        | "resume" => runResume ctx args
        | "apply-projection" => runApplyProjection ctx args
        | "append-reflection" =>
          runAppendLedger ctx args State.Append.Ledger.reflection
        | "append-lesson" =>
          runAppendLedger ctx args State.Append.Ledger.lessons
        | "stage-projection" => runStageProjection ctx
        | _ => runValidate ctx

/-- exit-code 規律(I-021、state.py `main()` の except 枠): 予期しない失敗は
「no」(exit 1)ではなく必ずハードエラー(exit 2)として表面化させる。 -/
private def hardErrorFrame (tool command : String) (act : IO UInt32) : IO UInt32 := do
  try
    act
  catch e =>
    IO.eprintln (toString e)
    die tool s!"unexpected failure in '{command}'; treating as a hard error, never as a gate answer (I-021)."

def run (d : Domain) (args : List String) : IO UInt32 := do
  match parseArgs d args with
  | .error e =>
    die d.tool s!"usage: {d.binCommand} state <command> --project <PROJECT_ROOT> ({e})"
  | .ok parsed =>
    match ← resolveCtx d parsed.project with
    | .error msg => die d.tool msg
    | .ok ctx =>
      hardErrorFrame d.tool parsed.command <|
        if mutatingCommands.contains parsed.command then
          runMutating ctx parsed
        else
          match parsed.command with
          | "should-stop" => runShouldStop ctx
          | "should-complete" => runShouldComplete ctx
          | "should-reset" => runShouldReset ctx
          | "status" => runStatus ctx
          | "supervise-check" => runSuperviseCheck ctx parsed
          | other => die ctx.domain.tool s!"unreachable command dispatch: {other}"

end Looper.Cli.State
