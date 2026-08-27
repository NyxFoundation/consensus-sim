// Finality (FFG-lite) — the minimal notion the Essence keeps: source/target
// votes between epoch-boundary checkpoints, supermajority justification, and
// finalization of a justified checkpoint whose direct successor-epoch
// checkpoint is justified. No committees, no full epoch processing.

import { getBlock, isAncestor, pathToAnchor, type BlockTree } from "./blockTree";
import { ANCHOR_BLOCK_INDEX, type BlockIndex, type SlotIndex, type Vote } from "./types";

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

/** Supermajority threshold: the least integer ≥ 2/3 of the validator count. */
export function supermajority(validatorCount: number): number {
  return Math.ceil((2 * validatorCount) / 3);
}

export interface FinalityState {
  /** All justified checkpoints (block indices). Always contains the anchor. */
  readonly justified: ReadonlySet<BlockIndex>;
  /** The highest justified checkpoint — the fork-choice root. */
  readonly justifiedHead: BlockIndex;
  /** The highest finalized checkpoint. Never regresses below the anchor. */
  readonly finalized: BlockIndex;
}

const higher = (tree: BlockTree, a: BlockIndex, b: BlockIndex): BlockIndex => {
  const blockA = getBlock(tree, a);
  const blockB = getBlock(tree, b);
  if (!blockA) return b;
  if (!blockB) return a;
  if (blockA.slot !== blockB.slot) return blockA.slot > blockB.slot ? a : b;
  return Math.min(a, b);
};

/**
 * Compute justification and finalization from every vote in a view.
 *
 * A link source→target is supermajority when distinct validators voting that
 * exact pair reach the 2/3 threshold. Justification is the fixpoint of:
 * anchor is justified; a supermajority link from a justified source to a
 * descendant target justifies the target. A justified source is finalized
 * when a supermajority link justifies a target in the epoch directly after
 * the source's epoch (FFG 1-finality, the minimal rule).
 */
export function computeFinality(
  tree: BlockTree,
  votes: readonly Vote[],
  validatorCount: number,
): FinalityState {
  const threshold = supermajority(validatorCount);

  // Distinct voters per (source, target) link; a validator voting the same
  // link at several slots still counts once.
  const linkVoters = new Map<string, Set<number>>();
  for (const vote of votes) {
    const key = `${vote.source}->${vote.target}`;
    let voters = linkVoters.get(key);
    if (!voters) {
      voters = new Set();
      linkVoters.set(key, voters);
    }
    voters.add(vote.validator);
  }
  const links: Array<{ source: BlockIndex; target: BlockIndex }> = [];
  for (const [key, voters] of linkVoters) {
    if (voters.size < threshold) continue;
    const [source, target] = key.split("->").map(Number) as [number, number];
    if (!tree.blocks.has(source) || !tree.blocks.has(target)) continue;
    if (source === target || !isAncestor(tree, source, target)) continue;
    links.push({ source, target });
  }

  const justified = new Set<BlockIndex>([ANCHOR_BLOCK_INDEX]);
  let grew = true;
  while (grew) {
    grew = false;
    for (const { source, target } of links) {
      if (justified.has(source) && !justified.has(target)) {
        justified.add(target);
        grew = true;
      }
    }
  }

  let finalized: BlockIndex = ANCHOR_BLOCK_INDEX;
  for (const { source, target } of links) {
    if (!justified.has(source) || !justified.has(target)) continue;
    const sourceBlock = getBlock(tree, source)!;
    const targetBlock = getBlock(tree, target)!;
    if (epochOf(targetBlock.slot) === epochOf(sourceBlock.slot) + 1) {
      finalized = higher(tree, finalized, source);
    }
  }

  let justifiedHead: BlockIndex = ANCHOR_BLOCK_INDEX;
  for (const checkpoint of justified) {
    justifiedHead = higher(tree, justifiedHead, checkpoint);
  }

  return { justified, justifiedHead, finalized };
}
