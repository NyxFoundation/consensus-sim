import Lake
open Lake DSL

package «atlas-builder»

/-- 共有実装(抽出計画 Phase 9 でこのツリーが atlas-looper から sync される)。 -/
lean_lib Looper

/-- 製品所有のドメインパック。Looper は製品トークンを持たず、製品ごとに違う
軸だけをこのライブラリが与える(抽出計画 §4.2)。 -/
lean_lib AtlasBuilder

@[default_target]
lean_exe «atlas-builder» where
  root := `AtlasBuilder.Main

/-- レシピ agentic-state-loop の別エントリポイント(R-8、共通コアを共有)。 -/
@[default_target]
lean_exe «asl-loop» where
  root := `Looper.Cli.AslMain
