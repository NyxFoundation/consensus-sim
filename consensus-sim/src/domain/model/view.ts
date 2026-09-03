// View (ビュー) — the knowledge one validator holds at one instant.
// Reference type from ESSENCE.md:
//   View = {blockTree, votes}
// The validator and the instant are the view's coordinates (where it is
// read: the arguments of the function that computes it), not its content —
// so the merge of several attackers' views is a View with no coordinate.

import type { BlockTree } from "./blockTree";
import type { Vote } from "./types";

export interface View {
  readonly blockTree: BlockTree;
  readonly votes: readonly Vote[];
}
