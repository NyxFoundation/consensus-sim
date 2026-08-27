import Looper.Asl.Hooks
import Looper.Core.Json
import Looper.Core.PathAlg
import Looper.Io.Fs
import Looper.Io.Clock

/-!
`Looper.Cli.AslHook` — レシピ agentic-state-loop の vendored Python hooks 3 本
(`pre_tool_guard.py` / `session_start_guard.py` / `post_tool_audit.py`)の
IO シェル(`asl-loop hook pre-tool|post-tool|session-start`)。

§3.3-3 の 3 手だけ(読む → 純粋核 `Looper.Asl.Hooks` を呼ぶ → 出力する)で、
判定ロジックは持たない。stdin/stdout/stderr/exit code の契約は Python hooks と
同一(シャドー差分でバイト一致を目標)。

LOOP_ROOT の解決は `Cli/Asl.lean` の `resolveCtx` と同一規約(`--loop-root`
明示、なければ実行ファイルの 2 つ上 = `<loop_dir>/bin/asl-loop` 配置規約)。
`Cli/Asl` の `resolveCtx` は private で `Ctx` 構造も異なる(state エンジン用の
stateDir/tmpDir を持つ)ため、hooks が要する派生物(TARGET_ROOT・LOOP_DIR 名・
SCHEMA_PATH・AUDIT_LOG)を持つ本ファイル固有の `HookCtx` を同等の規約で組む。

Python との裁定済み仕様差(META.md §31.2-29):
- `LOOP_TZ` はオフセット方言(`Cli/Asl` の nowLocal と同一)。
- 病的入力形状(非 object tool_input・非文字列 file_path/command/cwd・NUL 込み
  パス)は Python が未捕捉例外 exit 1(無決定)だが、Lean は無意見 / lenient
  スキップで判定を発しない(安全同値)。
-/

namespace Looper.Cli.AslHook

open Looper
open Looper.Core.Json (Value)
open Looper.Asl

/-- hooks 用の実行文脈(Python の TARGET_ROOT / LOOP_DIR / SCHEMA_PATH /
AUDIT_LOG に対応)。 -/
private structure HookCtx where
  targetRoot : String
  loopDir : String
  schemaPath : System.FilePath
  auditLog : System.FilePath

private def mkCtx (loopRoot : System.FilePath) : Except String HookCtx :=
  match loopRoot.parent, loopRoot.fileName with
  | some parent, some loopDir =>
    .ok { targetRoot := parent.toString, loopDir,
          schemaPath := loopRoot / "schema.json",
          auditLog := loopRoot / "state" / "tool_audit.jsonl" }
  | _, _ =>
    .error s!"cannot derive TARGET_ROOT / LOOP_DIR from LOOP_ROOT: {loopRoot}"

/-- LOOP_ROOT: `--loop-root` 明示なら `resolveNonStrict`、なければ実行ファイルの
2 つ上(`Cli/Asl.resolveCtx` と同一規約)。 -/
private def resolveCtx (flag : Option String) : IO (Except String HookCtx) := do
  match flag with
  | some p => pure (mkCtx (← Io.Fs.resolveNonStrict ⟨p⟩))
  | none =>
    let exe ← IO.appPath
    match exe.parent.bind (·.parent) with
    | some root => pure (mkCtx root)
    | none => pure (.error "cannot determine LOOP_ROOT from the binary location; pass --loop-root")

/-- stdin 全読み。読めなければ(不正 UTF-8 等)`none`。書き手側の EPIPE を避ける
ため必ず消費する(live `Cli/Hook.readStdin?` イディオム)。 -/
private def readStdin? : IO (Option String) := do
  try
    pure (some (← (← IO.getStdin).readToEnd))
  catch _ =>
    pure none

/-- Python `now_local()`: `LOOP_TZ`(オフセット方言)、既定 +09:00。 -/
private def nowLocal : IO String := Io.Clock.nowLocal "LOOP_TZ"

/-! ## schema.json 読み(`load_dynamic_rules` の IO 部) -/

/-- schema.json をパースして純粋 Value にする。読取/パース失敗・非 object は
`.null`(純粋核 `dynamicRules` が全空に落とす fail-open)。 -/
private def readSchemaValue (ctx : HookCtx) : IO Value := do
  match ← Io.Fs.readFile? ctx.schemaPath with
  | none => pure .null
  | some text =>
    match Core.Json.parse text with
    | .ok v => pure v
    | .error _ => pure .null

/-! ## pre-tool の path 解決(`path_candidates` の IO 部) -/

/-- Python の `resolved`: 絶対パスは `str(Path(raw))`(字句のみ・symlink 解決
なし)、相対パスは `(Path(cwd or ".") / raw).resolve()`(symlink 解決あり)。
OSError(NUL 込み等)は `none` で cand2/cand3 をスキップさせる。 -/
private def resolvePathTarget (raw cwd : String) : IO (Option String) := do
  if raw.toList.contains (Char.ofNat 0) then
    return none
  if raw.startsWith "/" then
    -- 絶対: 字句正規化のみ(Python `Path(raw)` は resolve しない)
    return some (Core.PathAlg.pureStr raw)
  else
    -- 相対: cwd(空・欠損は ".")と結合して resolve
    let joined := Core.PathAlg.childPath (if cwd.isEmpty then "." else cwd) raw
    try
      return some (← Io.Fs.resolveNonStrict ⟨joined⟩).toString
    catch _ =>
      return none

/-- `payload.get("cwd")`(欠損・null・非文字列は Python の `cwd or "."` 経路で
`"."` 相当。ここでは文字列のみ採り、それ以外は空文字列 = 後段で `"."`)。 -/
private def cwdOf (payload : Value) : String :=
  match (payload.get? "cwd").getD .null with
  | .str s => s
  | _ => ""

/-- WRITE_TOOLS の生ターゲット `file_path or notebook_path or ""`(falsy 連鎖)。
非文字列 file_path/notebook_path は Python では `Path(raw)` TypeError(無決定)
だが、裁定どおり欠損扱いで `""`(判定を発しない側、§31.2-29-b)。 -/
private def writeTargetRaw (payload : Value) : String :=
  let ti := (payload.get? "tool_input").getD (.obj [])
  let fp := (ti.get? "file_path").getD .null
  let nb := (ti.get? "notebook_path").getD .null
  match Hooks.orValue3 fp nb with
  | .str s => s
  | _ => ""

/-- Bash の `command`(欠損は ""、非文字列は裁定どおり "" = 判定を発しない)。 -/
private def bashCommandRaw (payload : Value) : String :=
  match (payload.get? "tool_input").getD (.obj []) |>.get? "command" with
  | some (.str s) => s
  | _ => ""

/-! ## `hook pre-tool`(pre_tool_guard.py) -/

private def runPreTool (ctx : HookCtx) (payload : Value) : IO UInt32 := do
  let tool := (payload.get? "tool_name").getD (.str "")
  let schema ← readSchemaValue ctx
  let (protectedPats, denyPats, denyBashPats) := Hooks.dynamicRules schema
  let decision? : Option Hooks.Decision ←
    if Hooks.isWriteTool tool then do
      let target := writeTargetRaw payload
      let resolved? ← if target.isEmpty then pure none
        else resolvePathTarget target (cwdOf payload)
      let cands := Hooks.pathCandidates target resolved? ctx.targetRoot
      pure (Hooks.decideWrite ctx.loopDir target cands protectedPats denyPats)
    else if tool == .str "Bash" then do
      pure (Hooks.decideBash ctx.loopDir (bashCommandRaw payload) denyBashPats)
    else
      pure none
  match decision? with
  | some d => IO.println d.render
  | none => pure ()
  pure 0

/-! ## `hook session-start`(session_start_guard.py) -/

private def runSessionStart (ctx : HookCtx) (payload? : Option Value) : IO UInt32 := do
  -- Python: `Path(payload.get("cwd") or Path.cwd()).resolve()`
  let claimedCwd : String ←
    match (payload?.bind (·.get? "cwd")).getD .null with
    | .str s => if s.isEmpty then pure (← IO.currentDir).toString else pure s
    | _ => pure (← IO.currentDir).toString
  let resolvedCwd := (← Io.Fs.resolveNonStrict ⟨claimedCwd⟩).toString
  -- TARGET_ROOT は Python では resolve 済み。ctx.targetRoot は loopRoot(解決済み)
  -- の parent で既に解決済み。
  if resolvedCwd == ctx.targetRoot then
    IO.println (Hooks.sessionConfirmedLine ctx.loopDir)
    pure 0
  else
    IO.eprintln (Hooks.sessionCwdMismatchMessage ctx.targetRoot resolvedCwd)
    pure 2

/-! ## `hook post-tool`(post_tool_audit.py) -/

/-- Python の try ブロックは `json.dumps` が例外を投げる前に
`AUDIT_LOG.parent.mkdir(parents=True)` と `open(AUDIT_LOG, "a")` を実行する。
病的形状で追記をスキップする場合も、この副作用(state/ ディレクトリと空の
監査ファイルの作成)を写す(best-effort、失敗は無視 — Python なら except が
別文言で拾う同型のパス)。 -/
private def touchAuditFile (ctx : HookCtx) : IO Unit := do
  try
    if let some parent := ctx.auditLog.parent then
      IO.FS.createDirAll parent
    IO.FS.withFile ctx.auditLog .append fun _ => pure ()
  catch _ =>
    pure ()

/-- `tool_input.get("command")` の値の分類。非文字列 truthy は Python の
`[:500]` スライス TypeError = 監査スキップ(§31.2-29 の裁定: Python に合わせ
「文字列でも null でも欠損でもない場合は追記スキップ + stderr 1 行 + exit 0」)。 -/
private inductive CmdField where
  | str (s : String)
  | absent
  | badType

private def commandField (payload : Value) : CmdField :=
  match (payload.get? "tool_input").getD (.obj []) |>.get? "command" with
  | some (.str s) => .str s
  | none => .absent
  | some .null => .absent
  | some v => if v.truthy then .badType else .absent

private def runPostTool (ctx : HookCtx) (payload : Value) : IO UInt32 := do
  let now ← nowLocal
  let ti := (payload.get? "tool_input").getD (.obj [])
  -- Python は truthy な非 object の tool_input を try 内 `.get` の
  -- AttributeError で捕捉する(追記なし + stderr 1 行 + exit 0)。写す。
  let isObj := match ti with | .obj _ => true | _ => false
  if ti.truthy && !isObj then
    touchAuditFile ctx
    IO.eprintln "[post_tool_audit] audit append failed: tool_input has no attribute 'get'"
    return 0
  let sessionId := (payload.get? "session_id").getD .null
  let tool := (payload.get? "tool_name").getD (.str "")
  let file := Hooks.orValue3 ((ti.get? "file_path").getD .null)
    ((ti.get? "notebook_path").getD .null)
  match commandField payload with
  | .badType =>
    -- Python の `[:500]` 例外パス相当: 追記せず stderr 1 行 + exit 0
    touchAuditFile ctx
    IO.eprintln "[post_tool_audit] audit append failed: command is not sliceable"
    pure 0
  | .absent =>
    let record := Hooks.auditRecord now sessionId tool file none
    match ← Io.Fs.appendJsonl ctx.auditLog record with
    | .error e => IO.eprintln s!"[post_tool_audit] audit append failed: {e}"
    | .ok () => pure ()
    pure 0
  | .str s =>
    let record := Hooks.auditRecord now sessionId tool file (some s)
    match ← Io.Fs.appendJsonl ctx.auditLog record with
    | .error e => IO.eprintln s!"[post_tool_audit] audit append failed: {e}"
    | .ok () => pure ()
    pure 0

/-! ## ディスパッチ -/

/-- 受け付ける hook イベント(下の `run` の判定と対)。 -/
def events : List String := ["pre-tool", "post-tool", "session-start"]

private def usage : String :=
  "usage: asl-loop hook <" ++ String.intercalate "|" events ++ "> [--loop-root <path>]"

/-- `--loop-root <path>` を取り出し、残りに未知フラグがないか検査する。 -/
private def parseHookArgs (args : List String) :
    Except String (Option String) :=
  go args none
where
  go : List String → Option String → Except String (Option String)
    | [], acc => .ok acc
    | "--loop-root" :: v :: rest, _ => go rest (some v)
    | ["--loop-root"], _ => .error "argument --loop-root: expected one argument"
    | arg :: _, _ => .error s!"unrecognized arguments: {arg}"

def run (args : List String) : IO UInt32 := do
  match args with
  | event :: rest =>
    if !(events.contains event) then do
      IO.eprintln usage
      return 2
    match parseHookArgs rest with
    | .error e =>
      IO.eprintln s!"{usage} ({e})"
      pure 2
    | .ok loopRoot? =>
      match ← resolveCtx loopRoot? with
      | .error msg =>
        IO.eprintln msg
        pure 2
      | .ok ctx =>
        -- stdin は必ず消費する(EPIPE 回避)
        let raw? ← readStdin?
        let payload? := raw?.bind fun s => (Core.Json.parse s).toOption
        match event with
        | "pre-tool" =>
          -- パース失敗は無出力 exit 0(fail-open)
          match payload? with
          | some p => runPreTool ctx p
          | none => pure 0
        | "post-tool" =>
          match payload? with
          | some p => runPostTool ctx p
          | none => pure 0
        | "session-start" =>
          -- パース失敗は payload={} 扱いで処理継続
          runSessionStart ctx payload?
        | _ => pure 2
  | [] =>
    IO.eprintln usage
    pure 2

end Looper.Cli.AslHook
