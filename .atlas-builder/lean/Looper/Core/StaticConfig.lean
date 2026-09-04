import Looper.Core.Json
import Looper.Domain

/-!
`Looper.Core.StaticConfig` — 制御プレーン静的設定の SSOT(META.md §8.1)。

`CONTROL_ROOT/.agent/state/` の静的設定 JSON(workspace.json と未束縛
project_index.json シード)の正本。配布ファイルは本モジュールの rendered
バイト列を maintainer plane の再生成レシピ(製品の `just render-static`。標準配布では installer が設置時に同じ面をエンジンに書かせる — §18.4)で書き出した投影で
あり、`<tool> util static-config <name>` がその出力面を提供する。乖離は
sync テスト(D-008)が `just test` で、配備済みプレーンでは doctor が warn で
検出する。投影の忠実性は機械証明済み(§31.3 W-T1)。

昇格判定基準(docs/archive/STATIC_CONFIG_LEAN_PROMOTION.md §2): (a) ランタイム不変・
(b) 内容がフレームワーク自身の契約・(c) JSON 形の要求が配布面に限られる、の
3 条件を満たす静的設定だけを本モジュールへ置く。ESSENCE.md 由来の値は絶対に
置かない(I-004)。ランタイム可変状態(束縛後 index、context、JSONL)も対象外。

構造は「typed structure + toJson」ではなく「名前付き定義 + Json.Value 直組み」を
採る: 消費者は個別の宣言値と全体バイト列の 2 種だけであり、中間の構造体は現時点で
読者がいない(§2.1.3 anti-bloat)。構造体化は消費者が現れたときに行う。
-/

namespace Looper.Core.StaticConfig

open Looper.Core.Json (Value)

/-! ## framework の自己記述(META.md §8.1 workspace.json) -/

def frameworkName (d : Domain) : String := d.displayName
def frameworkVersion : String := "1.0.0"
def frameworkMode : String := "two_root_claude_code"

/-- schema_version の唯一の定義点(D-009)。`State/Validate.schemaVersion` は
本定義への名前参照(単一定義への収斂)。framework version と現在は同値だが
意味が違う(state スキーマの版 vs framework の版)ため定義は共有しない。 -/
def schemaVersion : String := "1.0.0"

/-! ## invariants の宣言値(I-001〜I-004)

enforcement 側はこの定義を import して使う(宣言 = 強制が読む定義):
`overprojectAgentCwd` は `Hook/SessionStart` の I-001/I-002 違反文言が参照する。
Bool 3 面の強制実体は I-001/I-002 が SessionStart の判定、I-003 が guard の
分類、I-004 が G-T2/G-T3 の証明済み面(§31.3)。 -/

def overprojectAgentCwd (d : Domain) : String := "./" ++ d.controlDirName
def neverRunClaudeFromWorkspaceRoot : Bool := true
def embeddedAgentLiveLaunch : Bool := false
def projectEssenceIsHumanOnly : Bool := true

/-! ## workspace.json -/

/-- workspace.json の正本値(META.md §8.1)。 -/
def workspace (d : Domain) : Value :=
  .obj [
    ("schema_version", .str schemaVersion),
    ("framework", .obj [
      ("name", .str (frameworkName d)),
      ("version", .str frameworkVersion),
      ("mode", .str frameworkMode)]),
    ("paths", .obj [
      ("control_root", .str "."),
      ("workspace_root", .str "..")]),
    ("invariants", .obj [
      ("never_run_claude_from_workspace_root", .bool neverRunClaudeFromWorkspaceRoot),
      ("overproject_agent_cwd", .str (overprojectAgentCwd d)),
      ("embedded_agent_live_launch", .bool embeddedAgentLiveLaunch),
      ("project_essence_is_human_only", .bool projectEssenceIsHumanOnly)])]

/-- 配布ファイルの正確なバイト列(pretty 2-space + 末尾 LF)。 -/
def workspaceRendered (d : Domain) : String := (workspace d).renderPretty ++ "\n"

/-! ## project_index.json(未束縛シードのみ)

束縛後の index は `<tool> state ensure` / init が変異するランタイム正本で
あり、昇格対象外(§8.1)。prune 後の unbound 形がこのシードと一致することは
`Core/ProjectIndex` の `#guard` が凍結する。 -/

/-- 未束縛の配布シード(§8.1 registry の unbound 形)。 -/
def projectIndexSeed : Value :=
  .obj [("schema_version", .str schemaVersion), ("project", .null)]

def projectIndexSeedRendered : String := projectIndexSeed.renderPretty ++ "\n"

/-- `util static-config <name>` の純粋核: 配布名 → rendered バイト列。 -/
def rendered? (d : Domain) : String → Option String
  | "workspace" => some (workspaceRendered d)
  | "project-index-seed" => some projectIndexSeedRendered
  | _ => none

/-! ## コンパイル時バイト凍結(D-008 のモジュール内側の半分)

`ProjectIndex.lean` / `Hook/PreCompact.lean` と同じ手法。render 形式の非互換
変更(将来 `renderPretty` を触る)は必ずここで顕在化する。 -/

#guard workspaceRendered Domain.fixture ==
  "{\n  \"schema_version\": \"1.0.0\",\n  \"framework\": {\n    \"name\": \"Looper\",\n    \"version\": \"1.0.0\",\n    \"mode\": \"two_root_claude_code\"\n  },\n  \"paths\": {\n    \"control_root\": \".\",\n    \"workspace_root\": \"..\"\n  },\n  \"invariants\": {\n    \"never_run_claude_from_workspace_root\": true,\n    \"overproject_agent_cwd\": \"./.looper\",\n    \"embedded_agent_live_launch\": false,\n    \"project_essence_is_human_only\": true\n  }\n}\n"
#guard projectIndexSeedRendered ==
  "{\n  \"schema_version\": \"1.0.0\",\n  \"project\": null\n}\n"
#guard rendered? Domain.fixture "workspace" == some (workspaceRendered Domain.fixture)
#guard rendered? Domain.fixture "project-index-seed" == some projectIndexSeedRendered
#guard rendered? Domain.fixture "control-context-seed" == none

end Looper.Core.StaticConfig
