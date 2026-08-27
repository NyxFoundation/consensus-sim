// Protocol skeleton (簡約プロトコル骨格) — who proposes, how a proposal is
// built, and how an attester votes. Pure functions; the simulation driver
// decides when they run.

import { type BlockTree } from "./blockTree";
import { ghostHead } from "./forkChoice";
import { checkpointFor, epochOf, type FinalityState } from "./finality";
import {
  ANCHOR_BLOCK_INDEX,
  type Block,
  type BlockIndex,
  type SlotIndex,
  type ValidatorIndex,
  type Vote,
} from "./types";

/** Round-robin proposer schedule: deterministic and committee-free. */
export function proposerForSlot(
  slot: SlotIndex,
  validatorCount: number,
): ValidatorIndex {
  return ((slot % validatorCount) + validatorCount) % validatorCount;
}

/**
 * Build the block a proposer publishes at `slot`, extending its current
 * fork-choice head. `index` is assigned by the caller (the simulation keeps
 * the next free index).
 */
export function buildProposal(
  tree: BlockTree,
  votes: readonly Vote[],
  finality: FinalityState,
  slot: SlotIndex,
  proposer: ValidatorIndex,
  index: BlockIndex,
): Block {
  const parent = ghostHead(tree, votes, finality.justifiedHead);
  return { index, parent, slot, proposer };
}

/**
 * The vote an attester casts at `slot` from its view: head by GHOST from the
 * justified checkpoint, source = that justified checkpoint, target = the
 * current epoch's checkpoint on the head's chain.
 */
export function buildAttestation(
  tree: BlockTree,
  votes: readonly Vote[],
  finality: FinalityState,
  slot: SlotIndex,
  validator: ValidatorIndex,
): Vote {
  const head = ghostHead(tree, votes, finality.justifiedHead);
  const target = checkpointFor(tree, head, epochOf(slot));
  return { validator, slot, head, source: finality.justifiedHead, target };
}

/**
 * The second vote of a double vote (二重投票): same validator and slot as the
 * primary, but endorsing the primary head's parent — deterministic, and a
 * genuine equivocation whenever the head is not the anchor. Returns
 * undefined when no distinct alternative exists (head = anchor).
 */
export function buildEquivocalAttestation(
  tree: BlockTree,
  primary: Vote,
): Vote | undefined {
  const headBlock = tree.blocks.get(primary.head);
  if (headBlock === undefined || headBlock.index === ANCHOR_BLOCK_INDEX) {
    return undefined;
  }
  const altHead = headBlock.parent;
  const target = checkpointFor(tree, altHead, epochOf(primary.slot));
  return {
    validator: primary.validator,
    slot: primary.slot,
    head: altHead,
    source: primary.source,
    target,
  };
}
