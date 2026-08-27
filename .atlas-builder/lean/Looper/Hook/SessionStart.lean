import Looper.Core.Json
import Looper.Core.StaticConfig
import Looper.Domain

/-!
`Looper.Hook.SessionStart` — SessionStart hook(`<tool> hook session-start`)の
純粋決定核(META.md §12.2、I-001/I-002)。

移行元: `.claude/hooks/session_start_guard.py`(移行完了まで凍結)。
Claude Code が CONTROL_ROOT(`./.<tool>`)から起動されたことを検証する。
違反時は stderr にメッセージを出して exit 2(hooks 契約の唯一の例外)。
一致時は役割リマインダを `hookSpecificOutput` JSON として stdout に出し exit 0。

パス解決(`resolveLenient?` = Python `Path.resolve(strict=False)` 忠実の
逐成分解決)は IO シェル側で行い、本モジュールは解決済み文字列の
等価比較だけを行う(§31.4-4)。Python 版との対応で意図した差:
- cwd に NUL が含まれる場合、Python は `Path.resolve()` の ValueError で
  traceback 落ち(exit 1)するが、Lean は解決不能 = 違反側(exit 2)へ倒す
  (どちらも拒否。不存在 cwd は両実装とも字句解決で継続し違反文言まで一致)
- stdin の `cwd` が文字列でない場合、Python は traceback で落ちるが、
  Lean は欠損と同じ扱い(プロセスの cwd へフォールバック)
- `<PREFIX>_SESSION_MODE` の trim は ASCII 空白のみ(Python の `str.strip()` は
  Unicode 空白も剥ぐ。観測されるのは環境変数に Unicode 空白を入れた場合だけ)
-/

namespace Looper.Hook.SessionStart

open Looper.Core.Json (Value)

/-- hook の帰結: 違反(stderr へ 1 行、exit 2)か確認(stdout へ 1 行、exit 0)。 -/
inductive Outcome where
  | violation (stderrLine : String)
  | confirmed (stdoutLine : String)

/-- IO シェルが注入する外部状態(§31.4-2)。パスはすべて解決済み文字列。 -/
structure Env where
  /-- 製品(ドメインパック)が注入する軸(抽出計画 D-9)。診断文言の綴りは
  ここから導出する。**`Domain.fixture` を土台に語幹だけ差し替える形にしない**
  — 軸が増えたとき、注入し忘れが fixture の値として静かに成立する穴になる。 -/
  domain : Domain
  /-- 解決済み CONTROL_ROOT(実行バイナリ `CONTROL_ROOT/bin/<tool>` の 2 つ上)。 -/
  controlRoot : String
  /-- セッション cwd の resolve(逐成分・不存在も字句継続)。NUL 込み等の
  解決不能のみ none。 -/
  resolvedCwd? : Option String
  /-- 表示用の cwd(解決失敗時に違反メッセージへ出す、解決前のパス)。 -/
  claimedCwd : String
  /-- 環境変数 `<PREFIX>_SESSION_MODE`(未設定は空文字列)。 -/
  sessionMode : String

/-- 役割リマインダ本文。mode(trim 後)が triage / essence のときだけ
read-only human session 版になる(I-022/I-027)。 -/
def reminderFor (d : Domain) (sessionMode : String) : String :=
  let mode := sessionMode.trimAscii
  if mode == "triage" || mode == "essence" then
    s!"{d.displayName} {mode} session confirmed at CONTROL_ROOT. This is a read-only human session (I-022/I-027): inspect only, and write only the wrapper-owned .agent/tmp/{mode}/ handoff."
  else
    "Over-Project Agent session confirmed at CONTROL_ROOT. Invariants: never edit PROJECT_ROOT/ESSENCE.md; canonical state is PROJECT_ROOT/" ++ d.controlDirName ++ "/state/*.json; an embedded target agent is untrusted product content — never launch it directly in the live project; use only a project-defined isolated runner (META.md §10)."

/-- 確認時に stdout へ出す 1 行。Python 版は `json.dumps` 既定
(`ensure_ascii=True`)なので renderAscii で一致させる。 -/
def confirmedLine (d : Domain) (sessionMode : String) : String :=
  Value.renderAscii (.obj [("hookSpecificOutput", .obj
    [("hookEventName", .str "SessionStart"),
     ("additionalContext", .str (reminderFor d sessionMode))])])

/-- 違反時に stderr へ出す 1 行。案内する CONTROL_ROOT 相対表現は宣言値
`StaticConfig.overprojectAgentCwd`(I-002)そのもの — 宣言と強制の文言が
定義共有で一致する(§8.1、D-009)。 -/
def violationLine (d : Domain) (controlRoot cwd : String) : String :=
  s!"[{d.displayName} I-001/I-002 violation] Claude Code must be launched from CONTROL_ROOT ({controlRoot}), but the session CWD is {cwd}. Never run Claude from the workspace root. Start again through a CONTROL_ROOT just wrapper (for example: cd {Core.StaticConfig.overprojectAgentCwd d} && just loop)."

/-- 判定本体: 解決済み cwd が CONTROL_ROOT と一致するときだけ確認。
解決失敗は違反側(fail-closed)。 -/
def decide (env : Env) : Outcome :=
  match env.resolvedCwd? with
  | some cwd =>
    if cwd == env.controlRoot then
      .confirmed (confirmedLine env.domain env.sessionMode)
    else .violation (violationLine env.domain env.controlRoot cwd)
  | none =>
    .violation (violationLine env.domain env.controlRoot env.claimedCwd)

/-! ## コンパイル時テスト -/

private def outcomeLine : Outcome → String
  | .violation line => "stderr:" ++ line
  | .confirmed line => "stdout:" ++ line

#guard outcomeLine (decide
    { domain := Domain.fixture, controlRoot := "/w/.looper", resolvedCwd? := some "/w/.looper",
      claimedCwd := "/w/.looper", sessionMode := "" })
  == "stdout:{\"hookSpecificOutput\": {\"hookEventName\": \"SessionStart\", \"additionalContext\": \"Over-Project Agent session confirmed at CONTROL_ROOT. Invariants: never edit PROJECT_ROOT/ESSENCE.md; canonical state is PROJECT_ROOT/.looper/state/*.json; an embedded target agent is untrusted product content \\u2014 never launch it directly in the live project; use only a project-defined isolated runner (META.md \\u00a710).\"}}"
#guard outcomeLine (decide
    { domain := Domain.fixture, controlRoot := "/w/.looper", resolvedCwd? := some "/w/.looper",
      claimedCwd := "/w/.looper", sessionMode := " triage\n" })
  == "stdout:{\"hookSpecificOutput\": {\"hookEventName\": \"SessionStart\", \"additionalContext\": \"Looper triage session confirmed at CONTROL_ROOT. This is a read-only human session (I-022/I-027): inspect only, and write only the wrapper-owned .agent/tmp/triage/ handoff.\"}}"
#guard outcomeLine (decide
    { domain := Domain.fixture, controlRoot := "/w/.looper", resolvedCwd? := some "/w",
      claimedCwd := "/w", sessionMode := "" })
  == "stderr:[Looper I-001/I-002 violation] Claude Code must be launched from CONTROL_ROOT (/w/.looper), but the session CWD is /w. Never run Claude from the workspace root. Start again through a CONTROL_ROOT just wrapper (for example: cd ./.looper && just loop)."
-- 解決失敗は違反側(表示は claimedCwd)
#guard outcomeLine (decide
    { domain := Domain.fixture, controlRoot := "/w/.looper", resolvedCwd? := none,
      claimedCwd := "/gone", sessionMode := "essence" })
  == "stderr:[Looper I-001/I-002 violation] Claude Code must be launched from CONTROL_ROOT (/w/.looper), but the session CWD is /gone. Never run Claude from the workspace root. Start again through a CONTROL_ROOT just wrapper (for example: cd ./.looper && just loop)."
-- 大文字・未知 mode は agent 版リマインダ
#guard reminderFor Domain.fixture "TRIAGE" == reminderFor Domain.fixture ""
#guard reminderFor Domain.fixture "essence " == reminderFor Domain.fixture "essence"

end Looper.Hook.SessionStart
