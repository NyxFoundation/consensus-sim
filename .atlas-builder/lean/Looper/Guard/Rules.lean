import Looper.Domain

/-!
`Looper.Guard.Rules` — PreToolUse guard の判定理由文言(META.md §16・§23)。

移行元: `.claude/hooks/pre_tool_guard.py` の各 `decision(permission, reason)`
呼び出し。文言は Python の f-string / 隣接文字列連結の評価結果とバイト一致で
転記する(§5.3: 消費側が読む範囲は一致必須。ここの文言は Claude Code が
そのまま利用者に表示し、シャドー検証が stdout ごと比較する)。

判定ロジックは `Guard.Decide`、パターン由来の可変文言(DANGEROUS_BASH の
一致パターン)は `Core.Classify.Bash.dangerousBashReason?` が単一定義で持つ。
read-only セッションの allow 理由 3 種は `Core.Classify.ReadOnly` 側
(`handoffWriteReason` 等)にあり、本ファイルは deny/ask 側を持つ。

Python 完全排除(M3、META.md §31.2-43)以降の枠組み変更はバイト一致契約の
対象外である: read-only セッションの WRITE_TOOLS 面(`readOnlyWriteDenyReason`、
§13.6-3/§2.1.4-2)と `readOnlyDenyReason` の Write ツール案内、および
read-only セッションの ask 面 2 種(`liveSettingsAskReason` /
`essenceDirectInstallAskReason` — live settings 修復 §28.5-3 と ESSENCE.md
直接設置 fallback I-027 第二経路)はその追加分。
-/

namespace Looper.Guard.Rules

/-- WRITE_TOOLS の DENY_PATTERNS 一致(I-004・§2.1.5・§13.1-10 アンカー、および
§8.2 の投影台帳)。理由は 2 系統を正しく言い分ける — human-owned/secret/
attestation 面は「決して編集不可」、投影ファイルは「apply-projection 経由のみ」。
台帳の綴り(`ledgers` = `Domain.projectionLedgers`)はドメイン軸なので
呼び出し側が渡す(抽出計画 6b)。 -/
def writeDenyReason (d : Domain) (ledgers : List String) (target : String) :
    String :=
  s!"{d.displayName} invariant: '{target}' is not directly agent-editable. Human-owned / secret / attestation-anchoring paths (ESSENCE.md / essences/ / .env / secrets / essence_attestations.jsonl / {d.controlDirName}/state/project.json) are never editable; the §8.2 projection files ({d.controlDirName}/state/{String.intercalate "|" ledgers}.json) are written only via `{d.binCommand} state apply-projection --file <bundle>`."

/-- WRITE_TOOLS の ASK_PATTERNS 一致(§11.2 依存マニフェスト)。 -/
def manifestAskReason (target : String) : String :=
  s!"Dependency-manifest file '{target}' requires explicit approval before editing (META.md §11.2)."

/-- WRITE_TOOLS の制御プレーン面一致(§11.3)。 -/
def controlPlaneDenyReason (d : Domain) (target : String) : String :=
  s!"{d.displayName} control-plane file (META.md §11.3): '{target}'. A target-project Agent session never self-modifies its enforcement plane; framework work belongs to the separate maintainer plane."

/-- WRITE_TOOLS の High-Risk Zone 一致(§12)。 -/
def zoneAskReason (target : String) : String :=
  s!"Agent Runtime High-Risk Zone (META.md §12): '{target}'. Requires an explicit high-risk Todo, before/after hashes, and an entry in high_risk_changes.jsonl."

/-- Bash: 保護パスへの書き込み形状(protected_write_target × mutator)。 -/
def protectedWriteDenyReason : String :=
  "Bash command appears to modify a human-only, canonical, or secret path directly."

/-- Bash: SECRET_BASH(§11.4)。 -/
def secretDenyReason : String :=
  "Bash command references a secret path (.env / secrets / credentials)."

/-- Bash: DENIED_BASH(I-015: stage/commit は loop の所有)。 -/
def commitDenyReason (_d : Domain) : String :=
  let loopScript := scriptPath "loop"
  s!"Cycle commits are owned by {loopScript}; agents may inspect git status/diff but must not stage or commit directly."

/-- Bash: HUMAN_ONLY_BASH / `resume` サブコマンド(I-011、§13.3・§18.2)。 -/
def humanOnlyDenyReason (d : Domain) : String :=
  s!"Human-only {d.displayName} transition (I-011, META.md §13.3, §18.2): resume / loop / stop / once / init / doctor / trust / trust-check / triage / supervise / new-essence / update-essence / watch are operated by the human. Agents never release their own stop conditions, pace or drain the loop (§19.1-7), spawn their own loop / triage / essence-interview sessions, re-bind the control plane, grant trust, or author ESSENCE.md."

/-- Bash: LOOP_ONLY_BASH / loop-only サブコマンド(§19.1)。 -/
def loopOnlyDenyReason (d : Domain) : String :=
  let loopScript := scriptPath "loop"
  s!"Loop-owned {d.displayName} transition (META.md §19.1): start-run / end-run / record-progress / reset-context / raise-loop-gates are invoked by {loopScript} at the cycle boundary. Running them mid-cycle corrupts run records and the idle-progress signal; record your findings in canonical state instead."

/-- Bash: DANGEROUS_BASH(pat は一致した Python 正規表現リテラル —
`Core.Classify.Bash.dangerousBashReason?`)。 -/
def dangerousDenyReason (pat : String) : String :=
  s!"Forbidden Bash pattern (safety rule): {pat}"

/-- Bash: 生の Claude ネスト起動(§10、I-003)。 -/
def claudeLaunchDenyReason : String :=
  "Direct nested Claude launch is not an isolated verification boundary (META.md §10). Use a project-defined isolated runner, or raise a Human-input Recommendation when none exists."

/-- Bash: ASK_BASH(bootstrap / build)。 -/
def bootstrapAskReason (d : Domain) : String :=
  s!"{d.displayName} maintenance transition requires explicit human approval (bootstrap re-seeds project files outside the normal cycle flow)."

/-- Bash: 制御プレーン面のシェル変異(§11.3)。 -/
def controlSurfaceBashDenyReason (d : Domain) : String :=
  s!"Bash command appears to modify an {d.displayName} control-plane file (scripts / bind templates / recipes / prompts / META.md / README.md / justfile); target-project Agent sessions never self-modify the framework (META.md §11.3)."

/-- §11.6-4(I-007)の read-only 対象 deny。教示: 拒否は回避対象ではなく
設計信号 — 解除は人間の `writable:` directive だけである。 -/
def readOnlyTargetDenyReason (target : String) : String :=
  s!"read-only target (I-007, META.md §11.6): '{target}' is target implementation outside proofs/** and the current `writable:` grants. Verification never edits the target by default — record the change you need as a finding/Recommendation, or have the human grant the path with a `writable:` line in ESSENCE.md."

/-- 同 deny の Bash mutator 面(対象パスは列挙して教示)。 -/
def readOnlyTargetBashDenyReason (targets : List String) : String :=
  s!"read-only target (I-007, META.md §11.6): Bash mutation names target-implementation path(s) outside proofs/** and the current `writable:` grants ({String.intercalate ", " targets}). Verification never edits the target by default — write results under proofs/**, or have the human grant the path with a `writable:` line in ESSENCE.md."

/-- Bash: High-Risk Zone のシェル変異(§12・§20.4)。 -/
def zoneBashAskReason : String :=
  "Bash command appears to modify an Agent Runtime High-Risk Zone path (META.md §12); it requires an explicit high-risk Todo and before/after hash records (§20.4). Prefer the Edit/Write tools for such changes."

/-- Bash: 依存解決入力のシェル変異(§11.2)。 -/
def dependencyInputAskReason : String :=
  "Bash command appears to modify a dependency-resolution input (manifest / lockfile / package-manager config). The dependency set and its source are the human's decision (META.md §11.2), and this is the single gate the materialization allow relies on. Prefer Edit/Write, which is gated identically."

/-- Bash: 許可ルート外への cd(§11.2 の cd フェンス)。target は Python の
`str(Path)` 表記(解決済み、または解決不能時の生綴り)。 -/
def unsafeCdAskReason (target : String) : String :=
  s!"Bash command changes directory outside CONTROL_ROOT or registered PROJECT_ROOT: {target}"

/-- Bash: 依存ゲートの ask 面(auto-allow の 2 形状に該当しないインストール、
§11.2)。 -/
def installAskReason : String :=
  "Dependency change requires the human (META.md §11.2): this is not a plain materialization, and not every package is on the curated trusted list or declared in the project's ESSENCE.md. Batch the whole dependency decision into ONE install command, and have the human declare the recurring ones in the Essence (`deps: npm:<pkg>, pypi:<pkg>, ...`) so future installs run unattended."

/-- relaxed profile(ESSENCE の `profile:` 宣言、META.md §11.5)による自動許可。
ask 6 葉と Bash 最終無意見葉だけがこの理由で allow になり、deny 床(I-030)と
High-Risk staging(§20.4-3)は不変である。`surface` は緩和された面の名指し
(監査ログ・permission 表示上の識別子)。 -/
def profileAllowReason (surface : String) : String :=
  s!"Auto-approved by the ESSENCE-declared relaxed profile (META.md §11.5): {surface}. The deny floor is unchanged (I-030); the profile only replaces a human-approval prompt with an audited allow, and high-risk hash staging still records the change (§20.4-3)."

/-- read-only セッション(I-022/I-027)の handoff ファイル名(教示文の共有部)。 -/
def readOnlyHandoffFile (mode : String) : String :=
  if mode == "triage" then "resume_note.txt" else "ESSENCE.draft.md"

/-- read-only セッション(I-022/I-027)の Bash deny。受理される正確な形を教える
(handoff への道を断つと triage/essence 全体が座礁するため)。`handoffDir` は
`str(CONTROL_ROOT / ".agent" / "tmp" / mode)`(表示用・未解決の合成)。
Write ツール面の開放(§13.6-3/§2.1.4-2)に伴い、第一の出口として Write を
案内する(旧 Python 文言からの意図的拡張 — heredoc レシピ部は不変)。 -/
def readOnlyDenyReason (d : Domain) (mode handoffDir : String) : String :=
  let stateInspection :=
    if mode == "triage" then
      s!"exact state inspection ({d.binCommand} state status|should-stop --project <bound-project>) and "
    else ""
  let handoffFile := readOnlyHandoffFile mode
  let marker := d.envPrefix ++ "_HANDOFF"
  s!"{mode} is a read-only human session (I-022/I-027). Bash is limited to {stateInspection}one single-command quoted heredoc into the wrapper-owned handoff directory — nothing chained before or after it (an optional `mkdir -p {handoffDir} && ` prefix is the sole exception). To write the handoff, use the Write tool on {handoffDir}/{handoffFile}, or run exactly:\ncat > '{handoffDir}/{handoffFile}' <<'{marker}'\n<content>\n{marker}"

/-- read-only セッション(I-022/I-027)の WRITE_TOOLS deny。handoff 外への
Write/Edit/NotebookEdit を封じ、受理される正確な出口(Write ツール ×
handoff パス)と、残る ask 面(live settings 修復、essence-new では加えて
ESSENCE.md fallback)を教える(Bash 面 `readOnlyDenyReason` と同じ教示原則)。 -/
def readOnlyWriteDenyReason (mode handoffDir : String)
    (essenceNew : Bool := false) : String :=
  let askFaces :=
    if essenceNew then
      "surfaces are the live settings file .claude/settings.json (deployment repair, META.md §28.5-3), PROJECT_ROOT/ESSENCE.md (interview fallback install, I-027 second path), and files under PROJECT_ROOT/essences/ up to 3 path segments deep (asset fallback install, same path — §2.1.5)"
    else
      "surface is the live settings file .claude/settings.json (deployment repair, META.md §28.5-3)"
  s!"{mode} is a read-only human session (I-022/I-027): the only freely writable path is the wrapper-owned handoff directory {handoffDir}/. Write the handoff with the Write tool to {handoffDir}/{readOnlyHandoffFile mode} (supporting drafts may use other names inside the same directory). Beyond the handoff, the only human-approvable (ask) write {askFaces}; everything else is denied."

/-- read-only セッションの live settings 修復 ask 面(§28.5-3)。人間が
permission prompt で明示承認したときだけ書ける — project settings は
hot-reload されるため、承認された修復は同一セッションの以降の呼び出しに
効く。 -/
def liveSettingsAskReason (mode : String) : String :=
  s!"{mode} read-only session: editing the live project settings (CONTROL_ROOT/.claude/settings.json) is the sanctioned deployment-repair surface (META.md §28.5-3) and proceeds only with the human's explicit approval on this prompt. Project settings hot-reload, so an approved repair takes effect for the rest of this session; no other surface outside the handoff opens up."

/-- essence(new)セッションの ESSENCE.md 直接設置 fallback ask 面
(I-027 第二経路)。主経路は handoff 経由の wrapper 確認設置のまま。 -/
def essenceDirectInstallAskReason : String :=
  "new-Essence interview fallback (I-027 second path): writing PROJECT_ROOT/ESSENCE.md directly proceeds only with the human's explicit approval on this prompt. The primary install path remains the handoff draft reviewed in full and confirmed (y) through the wrapper; use this fallback only when the handoff surface is defective, and only with a draft whose full text the human has already reviewed on screen."

/-- essence(new)セッションの essences/ 資産設置 ask 面(I-027 第二経路の
§2.1.5 面)。essences/ 配下の最大 3 階層までのファイルのみ — それより深い
パスは validate が拒否する。設置内容は人間が画面で確認済みのものに限る。 -/
def essenceAssetInstallAskReason : String :=
  "new-Essence interview asset install (I-027 second path, §2.1.5): writing a file under PROJECT_ROOT/essences/ (at most 3 path segments deep) proceeds only with the human's explicit approval on this prompt. essences/ is the human-owned asset directory ESSENCE.md refers to — every installed file must be covered in ESSENCE.md by its exact 'essences/<path>' mention or by one of its parent directories, and only content the human has already reviewed on screen may be installed."

end Looper.Guard.Rules
