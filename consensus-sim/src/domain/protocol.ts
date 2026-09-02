// Protocol skeleton (簡約プロトコル骨格) — who proposes, how a proposal is
// built (parent by fork choice, body by inclusion), and how an attester
// votes. Pure functions over a view; the simulation driver decides when they
// run.
//
// Fork choice reads the message layer (the view's votes); the checkpoints a
// vote carries read the chain-state layer (the head's ChainState).

import { type BlockTree } from "./blockTree";
import {
  chainStatesOf,
  forkChoiceRoot,
  type ChainState,
  type ChainStateIndex,
} from "./chainState";
import { checkpointFor, epochOf } from "./finality";
import { ghostHead } from "./forkChoice";
import { buildBody, type Omission } from "./inclusion";
import {
  ANCHOR_BLOCK_INDEX,
  type Block,
  type BlockIndex,
  type SlotIndex,
  type Stake,
  type ValidatorIndex,
  type Vote,
} from "./types";
import type { View } from "./view";

/** Round-robin proposer schedule: deterministic and committee-free. */
export function proposerForSlot(
  slot: SlotIndex,
  validatorCount: number,
): ValidatorIndex {
  return ((slot % validatorCount) + validatorCount) % validatorCount;
}

/** What a validator concludes from its view: chain states, root and head. */
export interface Resolution {
  readonly states: ChainStateIndex;
  /** The justified checkpoint fork choice started from. */
  readonly root: BlockIndex;
  readonly head: BlockIndex;
  /** ChainState(head) — the view's justified / finalized / stakes. */
  readonly chainState: ChainState;
}

/** Run chain-state derivation and fork choice over a view. */
export function resolveView(
  view: View,
  initialStakes: ReadonlyMap<ValidatorIndex, Stake>,
): Resolution {
  const states = chainStatesOf(view.blockTree, initialStakes);
  const root = forkChoiceRoot(view.blockTree, states);
  const head = ghostHead(view.blockTree, view.votes, root);
  return { states, root, head, chainState: states.get(head)! };
}

/**
 * Build the block a proposer publishes at `slot`: parent = its fork-choice
 * head (or `parent` when designated and visible — フォーク作成), body = the
 * honest inclusion of everything unincluded on that branch minus `omit`.
 * `index` is assigned by the caller (the simulation keeps the next free one).
 */
export function buildProposal(
  view: View,
  resolution: Resolution,
  slot: SlotIndex,
  proposer: ValidatorIndex,
  index: BlockIndex,
  parent: BlockIndex = resolution.head,
  omit: Omission = {},
): Block {
  const tree: BlockTree = view.blockTree;
  const chosen = tree.blocks.has(parent) ? parent : resolution.head;
  return {
    index,
    parent: chosen,
    slot,
    proposer,
    body: buildBody(tree, view.votes, chosen, omit),
  };
}

/**
 * The vote an attester casts at `slot` from its view: head by fork choice,
 * source = the justified checkpoint of the head's chain state, target = the
 * current epoch's checkpoint on the head's chain.
 */
export function buildAttestation(
  view: View,
  resolution: Resolution,
  slot: SlotIndex,
  validator: ValidatorIndex,
): Vote {
  const head = resolution.head;
  const target = checkpointFor(view.blockTree, head, epochOf(slot));
  return {
    validator,
    slot,
    head,
    source: resolution.chainState.justified,
    target,
  };
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
