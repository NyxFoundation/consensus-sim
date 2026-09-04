import Looper.Core.Json
import Looper.Core.Classify.Install
import Looper.Core.Classify.Profile
import Looper.Domain

/-!
`Looper.Guard.Types` — PreToolUse guard の型群(§31.4-2、
META.md §16・§23)。

移行元: `.claude/hooks/pre_tool_guard.py`(移行完了まで凍結)。guard の判定は
すべて純粋関数 `Guard.Decide.decide : GuardEnv → ToolCall → GuardOutput` で行い、
外部状態(解決済みパス・環境変数・ESSENCE `deps:` 宣言・登録プロジェクト
ルート)は本ファイルの `GuardEnv` として IO シェルが注入する。

**fail-closed / fail-open の型区別(§31.4-5)**: `GuardEnv.resolved` の解決失敗
(`none`)は Python `_resolve_lenient` と同じく「どのルールにもマッチしない」
であって guard 全体の失敗ではない。deny 側ルールはパス解決に依存しない生文字列
判定(`Core.Classify.Bash`)を併走させているため、解決不能が deny の素通りに
ならない構造は Python と同一。
-/

namespace Looper.Guard

open Looper.Core.Json (Value)
open Looper.Core.Classify (DeclaredPackages Profile)

/-- `permissionDecision` の 3 値。 -/
inductive Permission where
  | deny
  | ask
  | allow
deriving BEq, Repr

/-- JSON 出力の文字列表現。 -/
def Permission.tag : Permission → String
  | .deny => "deny"
  | .ask => "ask"
  | .allow => "allow"

/-- `decision(permission, reason)` が stdout へ出す判定。 -/
structure Decision where
  permission : Permission
  reason : String
deriving BEq, Repr

/-- `decision()` の stdout 1 行(Python `json.dumps` 既定 =
`ensure_ascii=True`・セパレータ `", "` / `": "` とバイト一致)。 -/
def Decision.render (d : Decision) : String :=
  (Value.obj
    [("hookSpecificOutput", .obj
      [("hookEventName", .str "PreToolUse"),
       ("permissionDecision", .str d.permission.tag),
       ("permissionDecisionReason", .str d.reason)])]).renderAscii

/-- main() の分岐対象。`write` は `WRITE_TOOLS = {Edit, Write, NotebookEdit}` の
生ターゲット(`file_path or notebook_path or ""` — 空文字列も Python どおり
保持)、`other` はどの分岐にも入らないツール(無意見)。 -/
inductive ToolCall where
  | write (targetRaw : String)
  | bash (command : String)
  | other
deriving BEq, Repr

/-- 判定が参照する外部状態(IO シェルが構築して注入する。§31.4-2)。

`resolved` は `Guard.Decide.familyARequests` / `familyBRequests` が列挙した
キーに対する解決結果の表で、IO シェルの契約は:

- **相対キー**(`/` 開始でない): `_resolve_lenient(Path(cwd or ".") / key)`
  (`resolve_target` / `cd_targets` / install cd フェンスの結合規約)
- **絶対キー**: `_resolve_lenient(Path(key))`
  (read-only セッション面の `base / raw` 結合済みキー)

いずれも失敗(OSError / NUL)は `none`。表にないキーの照合も `none` と同じ
「マッチしない」に落ちる(安全側)。 -/
structure GuardEnv where
  /-- `CONTROL_ROOT`(`Path(__file__).resolve()` 由来 = 解決済み)。 -/
  controlRoot : String
  /-- `registered_project_roots()`(`(CONTROL_ROOT / rel).resolve()` 済み)。 -/
  projectRoots : List String
  /-- `<PREFIX>_SESSION_MODE` の strip 済み値(未設定は `""`)。 -/
  sessionMode : String
  /-- `<PREFIX>_SESSION_ESSENCE_MODE` の strip 済み値(essence セッションの
  `new` / `update`。それ以外・未設定は `""`)。ESSENCE.md 直接設置 fallback
  (I-027 第二経路)は `sessionMode = "essence" ∧ essenceMode = "new"` に限る。 -/
  essenceMode : String := ""
  /-- `(CONTROL_ROOT / ".claude" / "settings.json")` の解決済みパス
  (read-only セッションの live settings 修復 ask 面の照合先、§28.5-3)。
  read-only モード以外では `""`(未使用)。 -/
  settingsFile : String := ""
  /-- read-only 面の結合基点 `_resolve_lenient(Path(cwd or CONTROL_ROOT)) or
  CONTROL_ROOT`。 -/
  base : String
  /-- `(CONTROL_ROOT / ".agent" / "tmp" / <mode>).resolve()`。read-only モード
  以外では未使用。 -/
  handoffRoot : String
  /-- `<PREFIX>_SESSION_PROJECT_ROOT` の解決結果(未設定・空・解決不能は
  `none`)。 -/
  expectedProject? : Option String
  /-- `(CONTROL_ROOT / "bin" / <tool>).resolve()`(triage の
  `exact_script` 照合先 — state 読み取り面)。 -/
  stateScript : String
  /-- 精選リスト外の信頼源: 各登録ルートの ESSENCE.md から
  `Core.Classify.essenceDeclaredInto` で集めた `deps:` 宣言。 -/
  declared : DeclaredPackages
  /-- ESSENCE 宣言の実行 profile(§11.5、`ProfileScan.effective` 済み —
  absent / invalid / conflict は `.standard` へ縮退済み)。default 付きなので
  既存の構造リテラル・proofs は無修正でコンパイルする。read-only セッションは
  IO シェルが profile を読まず既定のままであり、決定木の read-only 分岐も
  profile を参照しない(構造的二重化、I-022/I-027)。 -/
  profile : Profile := .standard
  /-- ESSENCE 宣言の `writable:` 許可パターン(§11.6、生綴り — 各登録ルートの
  ESSENCE.md から `Core.GlobHier.writablePatterns` で収集)。パース不能な
  パターンは判定核が不発効に落とす(安全側)。無宣言 = 対象は全面 read-only
  (I-007)。 -/
  writablePatterns : List String := []
  /-- 解決要求キー → 解決結果(上記の契約)。 -/
  resolved : List (String × Option String)
  /-- 製品が注入するドメイン軸(抽出計画 D-9)。**default を置かない** —
  構築点を全部直させることが目的であり、既定値は「注入し忘れた env」を
  黙って通す穴になる。決定木がドメイン軸を消費し始めるのは 6b 以降で、
  この時点ではまだどの分岐も参照しない。 -/
  domain : Domain

/-- 解決表の照合(表にないキー = 解決失敗と同じ安全側)。 -/
def GuardEnv.resolved? (env : GuardEnv) (key : String) : Option String :=
  (env.resolved.lookup key).getD none

/-- 判定結果。`highRiskPre` は `record_high_risk_pre` に渡す raw_target 引数の
列(write 経路は生ターゲット、Bash 経路は解決済みパス文字列 — Python が
`str(resolved)` を渡す実挙動)。IO シェルは decide 後にこの列を before-hash
として `high_risk_pre.jsonl` へ stage し(§20.4-3、best-effort)、その後
`decision?` を出力する。 -/
structure GuardOutput where
  highRiskPre : List String
  decision? : Option Decision
deriving BEq, Repr

/-- `record_high_risk_pre` が `.agent/tmp/high_risk_pre.jsonl` へ stage する
1 レコード(キーは挿入順、`ensure_ascii=False` = `Value.render`)。
`sessionId` は `payload.get("session_id")`(欠損は null)。 -/
def pendingRecord (now : String) (sessionId : Value) (path sha : String) :
    Value :=
  .obj
    [("at", .str now),
     ("session_id", sessionId),
     ("path", .str path),
     ("before_sha256", .str sha)]

/-- **pre-tool 側の監査行**(§20.4-4、2026-08-12 追加)。

tool_audit.jsonl は post-tool フックだけが書いていた。ところが PreToolUse の
`deny` はツール実行そのものを止めるので PostToolUse は発火せず、**拒否された
コールは監査ログに 1 行も残らなかった** — ガードの誤判定率も、エージェントが
どこで壁に当たっているかも、ログからは観測できない状態だった(実走行
2026-08-12 で「grep でも拒否される」という誤った学習が伝承されたとき、それを
裏づけ/反証するデータがログ側に存在しなかった)。さらに、拒否された high-risk
Bash は before-hash だけが `high_risk_pre.jsonl` に残り、対応する after-hash も
監査行も無い孤児レコードになり得た。

意見のある判定(allow / ask / deny)だけを書く: 無意見の passthrough は
post-tool 行が既に覆っており、二重に書けば監査ログは倍量になって deny の
シグナルが薄まる。`phase` キーで post-tool 行と区別する(このキーを持たない
行は post-tool 行 = 後方互換)。 -/
def preToolAuditRecord (now : String) (sessionId tool file command : Value)
    (permission reason : String) : Value :=
  .obj
    [("at", .str now),
     ("phase", .str "pre_tool"),
     ("session_id", sessionId),
     ("tool", tool),
     ("file", file),
     ("command", command),
     ("decision", .str permission),
     ("reason", .str reason)]

-- pendingRecord は Python `json.dumps(..., ensure_ascii=False)` 出力とバイト一致
#guard (pendingRecord "2026-07-16T00:00:00+09:00" (.str "s1") "/ws/proj/prompts/x.md" "ABSENT").render
  == "{\"at\": \"2026-07-16T00:00:00+09:00\", \"session_id\": \"s1\", \"path\": \"/ws/proj/prompts/x.md\", \"before_sha256\": \"ABSENT\"}"
#guard (preToolAuditRecord "T" (.str "s1") (.str "Bash") .null
    (.str "rm -rf /") "deny" "dangerous").render
  == "{\"at\": \"T\", \"phase\": \"pre_tool\", \"session_id\": \"s1\", "
    ++ "\"tool\": \"Bash\", \"file\": null, \"command\": \"rm -rf /\", "
    ++ "\"decision\": \"deny\", \"reason\": \"dangerous\"}"

end Looper.Guard
