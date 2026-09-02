// View (ビュー) — the local state one validator observes at one instant.
// Reference type from ESSENCE.md:
//   View = {validator, slot, blockTree, votes}

import type { BlockTree } from "./blockTree";
import type { SlotIndex, ValidatorIndex, Vote } from "./types";

export interface View {
  readonly validator: ValidatorIndex;
  readonly slot: SlotIndex;
  readonly blockTree: BlockTree;
  readonly votes: readonly Vote[];
}
