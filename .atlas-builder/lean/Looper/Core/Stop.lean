import Looper.Core.Json
import Looper.Domain

/-!
`Looper.Core.Stop` — stop-reason 優先順の唯一の定義箇所(D-005)。

シェル側は `<bin> util stop-status` 経由で本モジュールを実体として使い、
state エンジンの emit 順もここに揃う。reasons は payload JSON の現行契約の
まま文字列リストで持つ(抽象語彙への持ち上げは証明層 `Proofs.Spec.Model`
の `StopReason` が担い、`canonical_matches_runtime` で本定義に接地する)。
-/

namespace Looper.Core.Stop

/-- 停止理由の優先順(高い順)。`should_stop_payload` が reasons を append
する順序と同一でなければならない(D-005)。

**ドメイン固有理由(`domainReasons`)は `human_input_required` の直後**へ
挿す(§13.4): 人間へのハンドオフ系より後、完了・予算・環境系より先という
位置である。挿入点を軸にしたのは、ドメインが増えても「どの停止が人間の
番で、どれが予算・環境の都合か」という読み方が動かないためである。

環境系 2 種の順序(`usage_limited` → `infra_unreachable`)は「具体が総称に
先行する」規律である: プラン利用上限は「Claude が走れない」の**特定された**
原因であり、Run-Status に総称の `infra_unreachable` が出ると人間は到達性・認証を
調べに行ってしまう(実走行 2026-08-12 の 9.5 時間停止の直接原因は、上限到達が
`idle_cycles`(意味的停滞)として提示されたことだった、§28.6)。 -/
def reasonPriority (domainReasons : List String) : List String :=
  [ "state_unreadable",
    "essence_missing",
    "essence_placeholder",
    "essence_structure",
    "essence_asset_integrity",
    "essence_unreviewed_change",
    "essence_blocking",
    "blocking_recommendation",
    "human_input_required" ]
  ++ domainReasons
  ++ [ "must_complete_awaiting_phase_approval",
       "idle_cycles",
       "usage_limited",
       "infra_unreachable" ]

/-- reasons のうち最優先のものを Run-Status として返す。未知の理由しか
含まない・空の場合は `"stopped"`(META.md §24.3 のフォールバック)。 -/
def runStatusFromReasons (domainReasons reasons : List String) : String :=
  ((reasonPriority domainReasons).find? reasons.contains).getD "stopped"

/-- should-stop payload(JSON object)から Run-Status を決める。

Python 側(旧 `_lib.sh` インライン)の `payload.get("reasons", [])` に対応:
- `reasons` キー欠落 → 空リスト → `"stopped"`
- `reasons` が文字列の配列 → 優先探索(文字列でない要素は一致し得ないため無視)
- トップレベルが object でない・`reasons` が配列でない(null 含む)→ エラー。
  Python はここで TypeError 等により非ゼロ終了しており(fail-closed)、
  その扱いを明示的なエラーとして保存する。 -/
def runStatusFromJson (domainReasons : List String) :
    Json.Value → Except String String
  | .obj entries =>
    match (Json.Value.obj entries).get? "reasons" with
    | none => .ok (runStatusFromReasons domainReasons [])
    | some (.arr items) =>
      .ok (runStatusFromReasons domainReasons
        (items.filterMap Json.Value.asStr?))
    | some _ => .error "reasons must be an array"
  | _ => .error "should-stop payload must be a JSON object"

#guard runStatusFromReasons Domain.fixture.domainStopReasons [] == "stopped"
#guard runStatusFromReasons Domain.fixture.domainStopReasons
    ["some_future_reason"] == "stopped"
#guard runStatusFromReasons Domain.fixture.domainStopReasons
    ["idle_cycles", "essence_blocking"] == "essence_blocking"
#guard runStatusFromReasons Domain.fixture.domainStopReasons
    ["infra_unreachable", "idle_cycles"] == "idle_cycles"
-- 環境系: 特定された原因(利用上限)が総称(到達不能)に先行する
#guard runStatusFromReasons Domain.fixture.domainStopReasons
    ["infra_unreachable", "usage_limited"] == "usage_limited"
#guard runStatusFromReasons Domain.fixture.domainStopReasons
    ["usage_limited", "idle_cycles"] == "idle_cycles"
-- 文書自身の形(§13.1-15)は、文書から essences/ への相互参照より先に成立する
#guard runStatusFromReasons Domain.fixture.domainStopReasons
    ["essence_asset_integrity", "essence_structure"] == "essence_structure"
#guard runStatusFromReasons Domain.fixture.domainStopReasons
    ["essence_structure", "essence_placeholder"] == "essence_placeholder"
#guard runStatusFromReasons Domain.fixture.domainStopReasons
    (reasonPriority Domain.fixture.domainStopReasons).reverse == "state_unreadable"
#guard (reasonPriority Domain.fixture.domainStopReasons).all
    (fun r => runStatusFromReasons Domain.fixture.domainStopReasons [r] == r)
-- ドメイン軸: 固有理由は human_input_required の直後(§13.4)に挿さる —
-- ハンドオフ系より後、完了・予算・環境系より先。軸が空のドメインでは
-- そもそも語彙に現れない(未知理由として "stopped" に落ちる)。
#guard reasonPriority Domain.fixtureRich.domainStopReasons
  == ["state_unreadable", "essence_missing", "essence_placeholder",
      "essence_structure", "essence_asset_integrity",
      "essence_unreviewed_change", "essence_blocking",
      "blocking_recommendation", "human_input_required", "domain_stop",
      "must_complete_awaiting_phase_approval", "idle_cycles",
      "usage_limited", "infra_unreachable"]
#guard runStatusFromReasons Domain.fixtureRich.domainStopReasons
    ["idle_cycles", "domain_stop"] == "domain_stop"
#guard runStatusFromReasons Domain.fixtureRich.domainStopReasons
    ["domain_stop", "human_input_required"] == "human_input_required"
#guard runStatusFromReasons Domain.fixture.domainStopReasons
    ["domain_stop"] == "stopped"
#guard (runStatusFromJson Domain.fixture.domainStopReasons
    (Json.Value.obj [])).toOption == some "stopped"
#guard (runStatusFromJson Domain.fixture.domainStopReasons
    (Json.Value.obj [("reasons", .arr [.str "idle_cycles"])])).toOption
    == some "idle_cycles"
#guard (runStatusFromJson Domain.fixture.domainStopReasons
    (Json.Value.obj [("reasons", .arr [.num 1 0, .str "idle_cycles"])])).toOption
    == some "idle_cycles"
#guard (runStatusFromJson Domain.fixture.domainStopReasons
    (Json.Value.obj [("reasons", .null)])).isOk == false
#guard (runStatusFromJson Domain.fixture.domainStopReasons
    (Json.Value.arr [])).isOk == false

end Looper.Core.Stop
