import Looper.Hook.StopCheck
import Looper.Hook.SessionStart
import Looper.Hook.PreCompact
import Looper.Hook.PostTool
import Looper.Guard.Decide
import Looper.Core.ProjectIndex
import Looper.Io.Fs
import Looper.Io.Clock
import Looper.Io.Env
import Looper.Domain

/-!
`Looper.Cli.Hook` — `<tool> hook <event>` の IO シェル。

§31.4-3 の規約どおり「読む → 純粋関数を呼ぶ → 出力する」の 3 手だけで、
分岐ロジックは `Looper.Hook.*` の純粋核に置く。stdin/stdout/exit code の
契約は Python hooks と同一(§2.1): stdout に JSON を 1 行出すか無出力、
exit は常に 0(fail-open)。
-/

namespace Looper.Cli.Hook

open Looper

private def controlRoot? : IO (Option System.FilePath) :=
  Io.Env.controlRoot?

/-- stdin 全読み。読めなければ(不正 UTF-8 等)`none`。書き手側の EPIPE を
避けるため、内容を無視する hook でも必ず消費する。 -/
private def readStdin? : IO (Option String) := do
  try
    let contents ← (← IO.getStdin).readToEnd
    pure (some contents)
  catch _ =>
    pure none

/-- stop_check.py と同じく stdin は読み捨てる(JSON でなくても無視、fail-open)。 -/
private def drainStdin : IO Unit := do
  discard readStdin?

/-- 表示タイムゾーン付きの現在時刻(Python `now_local`。表示 TZ ENV は
LEAN_MIGRATION_PLAN.md §4.4 のとおりオフセット形式、既定 +09:00)。 -/
private def nowLocal (d : Domain) : IO String :=
  Io.Clock.nowLocal (d.envPrefix ++ "_TZ")

/-- `<tool> hook stop` — stop_check.py と同一契約。
project_index.json → 対象 project → validation.json の順に読み、
警告があれば `systemMessage` JSON を 1 行出す。exit は常に 0。 -/
def runStop (d : Domain) : IO UInt32 := do
  drainStdin
  let warnings ← do
    match ← controlRoot? with
    | none => pure []
    | some root => do
      let index? ← Io.Fs.readJson? (root / ".agent" / "state" / "project_index.json")
      match Hook.StopCheck.projectOf index? with
      | none => pure []
      | some (projectRoot, title) => do
        let validation? ←
          Io.Fs.readJson? (root / projectRoot / d.controlDirName / "state" / "validation.json")
        pure (Hook.StopCheck.warningOf title validation?).toList
  if let some line := Hook.StopCheck.outputLine d warnings then
    IO.println line
  pure 0

/-- `<tool> hook session-start` — session_start_guard.py と同一契約
(META.md §12.2、I-001/I-002)。cwd を解決して CONTROL_ROOT と比較し、
違反は stderr + exit 2、確認は stdout に `hookSpecificOutput` JSON + exit 0。 -/
def runSessionStart (d : Domain) : IO UInt32 := do
  let payload? := (← readStdin?).bind fun s => (Core.Json.parse s).toOption
  -- Python: `payload.get("cwd") or Path.cwd()` — 欠損・null・空文字列は
  -- プロセスの cwd へフォールバック(文字列でない値も同様に扱う)
  let claimedCwd ← match payload?.bind (·.get? "cwd") |>.bind Core.Json.Value.asStr?
      |>.filter (· ≠ "") with
    | some s => pure s
    | none => do pure (← IO.currentDir).toString
  match ← controlRoot? with
  | none =>
    IO.eprintln s!"{d.tool}: cannot determine CONTROL_ROOT from the binary location"
    pure 2
  | some root => do
    let controlRoot := (← Io.Fs.realPath? root).getD root
    -- Python `Path(cwd).resolve()` 対応: 不存在 cwd も字句解決で継続する
    -- (`none` に残るのは NUL 込みの ValueError 対応のみ、§31.5)
    let resolvedCwd? ← Io.Fs.resolveLenient? claimedCwd
    let env : Hook.SessionStart.Env :=
      { domain := d
        controlRoot := controlRoot.toString
        resolvedCwd?
        claimedCwd
        sessionMode := (← IO.getEnv (d.envPrefix ++ "_SESSION_MODE")).getD "" }
    match Hook.SessionStart.decide env with
    | .confirmed line =>
      IO.println line
      pure 0
    | .violation line =>
      IO.eprintln line
      pure 2

/-- 既存 canonical file を `CanonicalRead` へ読み取る(I-021 の入力側)。
不存在 = absent(Python の `is_file()` に合わせ、ディレクトリも absent 扱いで
後続の rename が自然に失敗する)、存在するのに読めない/パースできない =
unreadable(理由つき)。 -/
private def readCanonical (path : System.FilePath) :
    IO Hook.PreCompact.CanonicalRead := do
  if !(← path.pathExists) then
    pure .absent
  else if ← path.isDir then
    pure .absent
  else
    match ← Io.Fs.readFileResult path with
    | .error e => pure (.unreadable e)
    | .ok text =>
      match Core.Json.parse text with
      | .ok v => pure (.readable v)
      | .error e => pure (.unreadable e)

/-- `<tool> hook pre-compact` — pre_compact_snapshot.py と同一契約
(META.md §14.1)。コンパクション breadcrumb を control_context.json へ
アトミックに追記する。I-021 のスキップを含め exit は常に 0。 -/
def runPreCompact (d : Domain) : IO UInt32 := do
  let payload? := (← readStdin?).bind fun s => (Core.Json.parse s).toOption
  -- read-only human session は snapshot を持たない(I-022/I-027)。
  -- Python 版と同じく strip なしの完全一致比較。
  let mode := (← IO.getEnv (d.envPrefix ++ "_SESSION_MODE")).getD ""
  if mode == "triage" || mode == "essence" then
    return 0
  match ← controlRoot? with
  | none =>
    IO.eprintln s!"{d.tool}: cannot determine CONTROL_ROOT from the binary location"
    return 0
  | some root => do
    let contextFile := root / ".agent" / "state" / "control_context.json"
    IO.FS.createDirAll (contextFile.parent.getD root)
    let read ← readCanonical contextFile
    let breadcrumb : Hook.PreCompact.Breadcrumb :=
      { atTime := ← nowLocal d
        sessionId := (payload?.bind (·.get? "session_id")).getD .null
        trigger := (payload?.bind (·.get? "trigger")).getD .null }
    match Hook.PreCompact.decide d read breadcrumb with
    | .skip line => IO.eprintln line
    | .write contents => Io.Fs.writeFileAtomic contextFile contents
    pure 0

/-! ## `<tool> hook post-tool`(post_tool_audit.py、META.md §20.4) -/

/-- `find_project_state_root`: 候補列(純粋)の先頭から、state ディレクトリが
実在する最初の `(projectRoot, stateDir)`。 -/
private def firstStateRoot (cands : List (String × String)) :
    IO (Option (String × String)) := do
  for (parent, stateDir) in cands do
    if ← System.FilePath.isDir ⟨stateDir⟩ then
      return some (parent, stateDir)
  return none

/-- `resolve_target` 相当: 絶対パスは表記正規化のみ(Python `Path(raw)` の
str)、相対パスは `cwd or "."` と合成して resolve(strict=False)する。
cwd の検査(truthy 非文字列 = 例外パス)は Python 同様、相対パスのときだけ
行われる。 -/
private def resolveTarget (payload : Core.Json.Value) (raw : String) :
    IO (Except String String) := do
  if (Hook.PostTool.pathParts raw).1.isEmpty then
    match Hook.PostTool.cwd? payload with
    | .error e => return .error e
    | .ok cwd =>
      return .ok (← Io.Fs.resolveNonStrict ⟨Hook.PostTool.childPath cwd raw⟩).toString
  else
    return .ok (Hook.PostTool.pyPathStr raw)

/-- `record_high_risk`: pending の before-hash と現在の after-hash を対にし、
プロジェクト側(あれば)または制御プレーン側の high_risk_changes.jsonl へ
追記する(§20.4-3)。 -/
private def recordHighRisk (root : System.FilePath) (now : String)
    (payload tool : Core.Json.Value) (targetStr : String)
    (stateDir? : Option String) (command? : Option String) :
    IO (Except String Unit) := do
  let pendingText? ← Io.Fs.readFile? (root / ".agent" / "tmp" / "high_risk_pre.jsonl")
  let sessionId := (payload.get? "session_id").getD .null
  match Hook.PostTool.pendingBefore pendingText? targetStr sessionId with
  | .error e => return .error e
  | .ok before =>
    match ← Io.Fs.sha256OrAbsent ⟨targetStr⟩ with
    | .error e => return .error e
    | .ok after =>
      let log : System.FilePath := match stateDir? with
        | some stateDir => System.FilePath.mk stateDir / "high_risk_changes.jsonl"
        | none => root / ".agent" / "state" / "high_risk_changes.jsonl"
      Io.Fs.appendJsonl log
        (Hook.PostTool.highRiskRecord now tool targetStr before (.str after) command?)

/-- Edit / Write / NotebookEdit の high-risk 記録(main() の WRITE_TOOLS 分岐)。 -/
private def writeHighRisk (d : Domain) (root : System.FilePath)
    (controlRoot now : String) (payload tool : Core.Json.Value) :
    IO (Except String Unit) := do
  match Hook.PostTool.writeTarget? payload with
  | .error e => return .error e
  | .ok none => return .ok ()
  | .ok (some raw) =>
    match ← resolveTarget payload raw with
    | .error e => return .error e
    | .ok targetStr =>
      let stateRoot? ← firstStateRoot
        (Hook.PostTool.stateRootCandidates d targetStr controlRoot)
      if Hook.PostTool.isHighRiskTarget raw targetStr (stateRoot?.map (·.1))
          controlRoot then
        recordHighRisk root now payload tool targetStr (stateRoot?.map (·.2)) none
      else
        return .ok ()

/-- Bash mutator の high-risk 記録(main() の Bash 分岐 +
`bash_high_risk_targets`)。Python 同様、全トークンの判定を終えてから記録し、
判定途中の例外は 1 件も記録しない。 -/
private def bashHighRisk (d : Domain) (root : System.FilePath)
    (controlRoot now : String) (payload tool : Core.Json.Value) :
    IO (Except String Unit) := do
  match Hook.PostTool.bashCommand? payload with
  | .error e => return .error e
  | .ok command =>
    if command.isEmpty || !Core.Classify.hasWriteRedirectOrMutator command then
      return .ok ()
    let mut targets : List (String × Option (String × String)) := []
    for tok in Hook.PostTool.bashCandidateTokens command do
      match ← resolveTarget payload tok with
      | .error e => return .error e
      | .ok targetStr =>
        let stateRoot? ← firstStateRoot
          (Hook.PostTool.stateRootCandidates d targetStr controlRoot)
        if Hook.PostTool.isHighRiskTarget tok targetStr (stateRoot?.map (·.1))
            controlRoot then
          targets := targets ++ [(targetStr, stateRoot?)]
    for (targetStr, stateRoot?) in targets do
      match ← recordHighRisk root now payload tool targetStr
          (stateRoot?.map (·.2)) (some command) with
      | .error e => return .error e
      | .ok _ => pure ()
    return .ok ()

/-- `<tool> hook post-tool` — post_tool_audit.py と同一契約(META.md §20.4)。
全ツール呼び出しを tool_audit.jsonl へ追記し、High-Risk Zone への書き込みは
before/after ハッシュ対で high_risk_changes.jsonl へ記録する。best-effort:
どの失敗も stderr 1 行に落とし、exit は常に 0(fail-open)。stdin の JSON が
object でない場合、Python は traceback(exit 1、記録なし)で落ちるが、Lean は
pre_compact 同様 `{}` と同じ扱いにする(意図差、§5.3)。 -/
def runPostTool (d : Domain) : IO UInt32 := do
  let some payload := (← readStdin?).bind fun s => (Core.Json.parse s).toOption
    | return 0
  -- I-022/I-027: 対話 read-only セッションの許可済み検分を監査ログへ書くこと
  -- 自体が read-only 保証への違反になるため、無条件で無作用。
  let mode ← IO.getEnv (d.envPrefix ++ "_SESSION_MODE")
  if mode == some "triage" || mode == some "essence" then
    return 0
  match ← controlRoot? with
  | none =>
    IO.eprintln s!"{d.tool}: cannot determine CONTROL_ROOT from the binary location"
    pure 0
  | some root => do
    let controlRoot := ((← Io.Fs.realPath? root).getD root).toString
    let now ← nowLocal d
    let auditResult ← match Hook.PostTool.auditRecord now payload with
      | .error e => pure (Except.error e)
      | .ok record =>
        Io.Fs.appendJsonl (root / ".agent" / "state" / "tool_audit.jsonl") record
    if let .error e := auditResult then
      IO.eprintln s!"[post_tool_audit] audit append failed: {e}"
    let tool := Hook.PostTool.toolValue payload
    if Hook.PostTool.isWriteTool tool then
      if let .error e ← writeHighRisk d root controlRoot now payload tool then
        IO.eprintln s!"[post_tool_audit] high-risk record failed: {e}"
    else if tool == .str "Bash" then
      if let .error e ← bashHighRisk d root controlRoot now payload tool then
        IO.eprintln s!"[post_tool_audit] bash high-risk record failed: {e}"
    pure 0

/-! ## `<tool> hook pre-tool`(pre_tool_guard.py、META.md §16・§23)

判定はすべて純粋核 `Guard.decide`。この IO シェルは
§31.4-3 の 3 手 — (1) stdin・環境・project_index・ESSENCE を読み、
`familyARequests` / `familyBRequests` が列挙した解決要求キーを解決して
`GuardEnv` を組む → (2) `decide` を呼ぶ → (3) `highRiskPre` を
`high_risk_pre.jsonl` へ stage(best-effort、§20.4-3)し `decision?` を
stdout へ出す — だけで、分岐ロジックを持たない。exit は常に 0。

(かつての併走モード `<PREFIX>_GUARD_SHADOW` — Python hook との差分コーパス
収集の足場 — は移行完了で撤去した。guard 全体を無意見化する環境変数は、
役目を終えたあとはただの undocumented kill switch である。stale 配線の検出は
`Core.SettingsDoctor` が、残骸 `guard_shadow.jsonl` の掃除は bootstrap の
sweep が引き続き持つ。) -/

/-- stdin payload から `ToolCall` を組む。`.error` は Python の未捕捉
TypeError(truthy 非 object の `tool_input`、truthy 非文字列の
`file_path` / `command`)= traceback で判定なしに落ちる fail-open 経路。 -/
private def toolCallOf (payload : Core.Json.Value) :
    Except String Guard.ToolCall :=
  let tool := Hook.PostTool.toolValue payload
  if Hook.PostTool.isWriteTool tool then
    (Hook.PostTool.writeTarget? payload).map fun
      | some raw => .write raw
      | none => .write ""
  else if tool == .str "Bash" then
    (Hook.PostTool.bashCommand? payload).map .bash
  else
    .ok .other

/-- `registered_project_roots()`: §8.1 registry の単一 `project` から
`(CONTROL_ROOT / rel).resolve()` を返す。読取不能・形状外れは `[]`。
`project_root` が truthy 非文字列の壊れ形(`.malformed`)も `[]` に写す —
Python は最初の `registered_project_roots()` 呼び出しで TypeError = fail-open
クラッシュ(発火位置は判定経路依存)であり、登録なし扱いは cd フェンス・
zone 候補・ESSENCE 宣言をすべて狭める厳格側。唯一の緩和窓(curated install
が「クラッシュ = 無意見」でなく allow になり得る)は裁定済みの意図差。 -/
private def registeredProjectRoots (rootFp : System.FilePath)
    (controlRoot : String) : IO (List String) := do
  let index? ← Io.Fs.readJson? (rootFp / ".agent" / "state" / "project_index.json")
  match index?.map Core.ProjectIndex.shape with
  | some (.registered _ (some rel)) =>
    -- Python `CONTROL_ROOT / rel` は絶対 rel をそのまま採る(truediv 規約)
    let joined := if rel.startsWith "/" then rel
      else Hook.PostTool.childPath controlRoot rel
    pure [(← Io.Fs.resolveNonStrict ⟨joined⟩).toString]
  | _ => pure []

/-- `<tool> hook pre-tool` — pre_tool_guard.py と同一契約(§2.1)。
stdout に `hookSpecificOutput` JSON を 1 行出すか無出力 = 無意見、exit 常に 0。
stdin の JSON パース失敗は無意見(fail-open、§31.5)。truthy 非文字列の `cwd`
は Python の未捕捉 TypeError(fail-open クラッシュ — ただしテキスト判定の
deny はその手前で発火済み)に対応して「全解決要求の失敗 = マッチしない」に
写す: deny 面は解決に依存せず保存され、解決依存の allow 面だけが潰れる、
厳格方向のみの差。 -/
def runPreTool (d : Domain) : IO UInt32 := do
  let some payload := (← readStdin?).bind fun s => (Core.Json.parse s).toOption
    | return 0
  match toolCallOf payload with
  | .error e =>
    IO.eprintln s!"[pre_tool_guard] unusable payload (no opinion): {e}"
    return 0
  | .ok toolCall =>
  match ← controlRoot? with
  | none =>
    IO.eprintln s!"{d.tool}: cannot determine CONTROL_ROOT from the binary location"
    return 0
  | some rootPath => do
    let rootFp := (← Io.Fs.realPath? rootPath).getD rootPath
    let controlRoot := rootFp.toString
    let projectRoots ← registeredProjectRoots rootFp controlRoot
    let sessionMode := Core.Text.pyStrip
      ((← IO.getEnv (d.envPrefix ++ "_SESSION_MODE")).getD "")
    let readOnly := sessionMode == "triage" || sessionMode == "essence"
    -- family A の解決アンカー `Path(cwd or ".")`(truthy 非文字列 = none)
    let anchorA? := (Hook.PostTool.cwd? payload).toOption
    -- read-only 面の結合基点 `_resolve_lenient(Path(cwd or CONTROL_ROOT)) or CONTROL_ROOT`
    let base ← match (payload.get? "cwd").getD .null with
      | .str s =>
        if s.isEmpty then pure controlRoot
        else pure ((← Io.Fs.resolveLenient? s).getD controlRoot)
      | _ => pure controlRoot
    let handoffRoot ← if readOnly then do
        pure (← Io.Fs.resolveNonStrict
          ⟨Hook.PostTool.childPath controlRoot (".agent/tmp/" ++ sessionMode)⟩).toString
      else pure ""
    let expectedProjectRaw := (← IO.getEnv (d.envPrefix ++ "_SESSION_PROJECT_ROOT")).getD ""
    -- triage は state 読み取り面、essence(new)は ESSENCE.md 直接設置 fallback
    -- (I-027 第二経路)の照合先として使う。
    let expectedProject? ←
      if readOnly && !expectedProjectRaw.isEmpty then
        Io.Fs.resolveLenient? expectedProjectRaw
      else pure none
    let essenceMode := Core.Text.pyStrip
      ((← IO.getEnv (d.envPrefix ++ "_SESSION_ESSENCE_MODE")).getD "")
    let stateScript ← if sessionMode == "triage" then do
        pure (← Io.Fs.resolveNonStrict
          ⟨Hook.PostTool.childPath controlRoot ("bin/" ++ d.tool)⟩).toString
      else pure ""
    -- read-only セッションの live settings 修復 ask 面(§28.5-3)の照合先。
    let settingsFile ← if readOnly then do
        pure (← Io.Fs.resolveNonStrict
          ⟨Hook.PostTool.childPath controlRoot ".claude/settings.json"⟩).toString
      else pure ""
    -- 精選リスト外の信頼源(§11.2)・実行 profile(§11.5)・対象書込み許可
    -- (`writable:`、§11.6): ESSENCE を読むのは判定がそれらに届く経路のみ —
    -- `deps:` は Bash の install 判定、`profile:` は Bash / Write の ask 緩和
    -- 面、`writable:` は Bash / Write の read-only 反転面(I-007)。read-only
    -- セッション(I-022/I-027)はいずれも読まず、profile は GuardEnv 既定の
    -- standard、writable は空(= 全面 read-only)のまま(§11.5 — 決定木の
    -- read-only 分岐も profile を参照しない構造的二重化)。
    let (declared, profile, writablePatterns) ← match toolCall, readOnly with
      | .bash _, false | .write _, false => do
        let mut d : Core.Classify.DeclaredPackages := {}
        let mut payloads : List String := []
        let mut writable : List String := []
        for root in projectRoots do
          if let some text ← Io.Fs.readFile? (System.FilePath.mk root / "ESSENCE.md") then
            if let .bash _ := toolCall then
              d := Core.Classify.essenceDeclaredInto d text
            payloads := payloads ++ Core.Classify.profileLinePayloads text
            writable := writable ++ Core.GlobHier.writablePatterns text
        pure (d, (Core.Classify.scanProfilePayloads payloads).effective, writable)
      | _, _ =>
        pure (({} : Core.Classify.DeclaredPackages),
          Core.Classify.Profile.standard, [])
    -- 解決要求キー → 解決結果(GuardEnv.resolved の契約は Guard/Types 頭注)
    let mut resolved : List (String × Option String) := []
    for key in Guard.familyARequests toolCall do
      -- `Path(cwd) / key` は Python 同様に絶対キー側を優先する(`childPath` の
      -- 契約は相対 rel なので分岐で表す)。絶対キーの解決結果が要るのは、
      -- `..` を畳んだ位置でだけ containment 判定が健全になるためである。
      let v? ← match anchorA? with
        | some anchor =>
          Io.Fs.resolveLenient?
            (if key.startsWith "/" then key else Hook.PostTool.childPath anchor key)
        | none => pure none
      resolved := resolved ++ [(key, v?)]
    for key in Guard.familyBRequests base sessionMode toolCall do
      let v? ← if anchorA?.isSome then Io.Fs.resolveLenient? key else pure none
      resolved := resolved ++ [(key, v?)]
    let env : Guard.GuardEnv :=
      { controlRoot, projectRoots, sessionMode, essenceMode, settingsFile,
        base, handoffRoot, expectedProject?, stateScript, declared, resolved,
        profile, writablePatterns, domain := d }
    let out := Guard.decide env toolCall
    -- §20.4-3: before-hash の staging(best-effort)は decision 出力に先行する
    for raw in out.highRiskPre do
      let staged ← do
        match env.resolveTarget? raw with
        | none => pure (Except.error s!"unresolvable target: {raw}")
        | some target =>
          match ← Io.Fs.sha256OrAbsent ⟨target⟩ with
          | .error e => pure (Except.error e)
          | .ok sha =>
            Io.Fs.appendJsonl (rootFp / ".agent" / "tmp" / "high_risk_pre.jsonl")
              (Guard.pendingRecord (← nowLocal d)
                ((payload.get? "session_id").getD .null) target sha)
      if let .error e := staged then
        IO.eprintln s!"[pre_tool_guard] high-risk prehash failed: {e}"
    -- §20.4-4: 意見のある判定を監査ログへ残す。deny はここでしか観測できない
    -- (PreToolUse の deny は PostToolUse を発火させない)。I-022/I-027 の
    -- read-only セッションは無条件に無作用 — 許可済み検分を書くこと自体が
    -- read-only 保証の違反になる(post_tool_audit と同じ規律)。
    if let some decision := out.decision? then
      unless readOnly do
        let ti := (payload.get? "tool_input").getD .null
        let fileOf (k : String) : Core.Json.Value := (ti.get? k).getD .null
        let file := match fileOf "file_path" with
          | .null => fileOf "notebook_path"
          | v => v
        let record := Guard.preToolAuditRecord (← nowLocal d)
          ((payload.get? "session_id").getD .null)
          (Hook.PostTool.toolValue payload) file
          ((ti.get? "command").getD .null) decision.permission.tag decision.reason
        if let .error e ← Io.Fs.appendJsonl
            (rootFp / ".agent" / "state" / "tool_audit.jsonl") record then
          IO.eprintln s!"[pre_tool_guard] audit append failed: {e}"
      IO.println decision.render
    pure 0

end Looper.Cli.Hook
