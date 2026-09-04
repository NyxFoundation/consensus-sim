// View(ビュー) — あるバリデータがある観測時点に持つ知識。
// ESSENCE.md の参照型:
//   View = {blockTree, votes}
// バリデータと観測時点は View の座標(それを算出する関数の引数、すなわち
// どこで読むか)であり、内容ではない — そのため複数の攻撃者の View を
// 統合したものは座標を持たない View となる。

import type { BlockTree } from "./blockTree";
import type { Vote } from "./types";

/** View: あるバリデータがある観測時点に持つ知識 `{blockTree, votes}`。 */
export interface View {
  readonly blockTree: BlockTree;
  readonly votes: readonly Vote[];
}
