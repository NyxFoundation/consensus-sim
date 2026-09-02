// Epochs and checkpoints — the minimal FFG vocabulary the Essence keeps:
// 4-slot epochs, and the epoch-boundary checkpoint that source/target votes
// point at. Justification and finalization themselves are chain state
// (chainState.ts): they are derived from the votes a branch has included.

import { pathToAnchor, type BlockTree } from "./blockTree";
import { ANCHOR_BLOCK_INDEX, type BlockIndex, type SlotIndex } from "./types";

/**
 * Epoch length in slots. The abstract model needs epochs only to place
 * checkpoint boundaries for source/target votes; 4 keeps finality visible
 * within a few slot advances.
 */
export const SLOTS_PER_EPOCH = 4;

export function epochOf(slot: SlotIndex): number {
  return Math.floor(slot / SLOTS_PER_EPOCH);
}

export function epochBoundarySlot(epoch: number): SlotIndex {
  return epoch * SLOTS_PER_EPOCH;
}

/**
 * The checkpoint of `epoch` on the chain ending at `head`: the last block on
 * that chain with slot ≤ the epoch's boundary slot (the epoch-boundary
 * block, or its most recent ancestor when the boundary slot is empty).
 */
export function checkpointFor(
  tree: BlockTree,
  head: BlockIndex,
  epoch: number,
): BlockIndex {
  const boundary = epochBoundarySlot(epoch);
  for (const block of pathToAnchor(tree, head)) {
    if (block.slot <= boundary) return block.index;
  }
  return ANCHOR_BLOCK_INDEX;
}
