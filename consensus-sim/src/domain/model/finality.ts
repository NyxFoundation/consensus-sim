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

export function slotsSinceEpochStart(slot: SlotIndex): number {
  return slot - epochBoundarySlot(epochOf(slot));
}

/**
 * The head section of an epoch in which the fork-choice root may switch to
 * a conflicting justified checkpoint (justified チェックポイント切替 =
 * window): Ethereum's SAFE_SLOTS_TO_UPDATE_JUSTIFIED is a quarter of its
 * epoch, which is one slot of this model's four.
 */
export const JUSTIFIED_SWITCH_WINDOW_SLOTS = 1;

export function inJustifiedSwitchWindow(slot: SlotIndex): boolean {
  return slotsSinceEpochStart(slot) < JUSTIFIED_SWITCH_WINDOW_SLOTS;
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
