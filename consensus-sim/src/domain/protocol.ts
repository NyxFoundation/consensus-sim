// Protocol skeleton (簡約プロトコル骨格) — how a proposal is built (parent by
// fork choice, body by inclusion), how an attester votes, and how a view is
// resolved into a head under the protocol parameters. Pure functions over a
// view; the simulation driver decides when they run, and schedule.ts says
// who (proposer, committee).
//
// Fork choice reads the message layer (the view's votes); the checkpoints a
// vote carries read the chain-state layer (the head's ChainState).

import { type BlockTree } from "./blockTree";
import {
  chainStatesOf,
  forkChoiceRoot,
  viableBlocks,
  type ChainState,
  type ChainStateIndex,
} from "./chainState";
import type { SimulationConfig } from "./config";
import { checkpointFor, epochOf } from "./finality";
import { ghostHead, type ForkChoiceWeights } from "./forkChoice";
import { buildBody, equivocatingVoters, type Omission } from "./inclusion";
import { committeeForSlot, proposerForSlot } from "./schedule";
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

/** What a validator concludes from its view: chain states, root and head. */
export interface Resolution {
  readonly states: ChainStateIndex;
  /** The justified checkpoint fork choice started from. */
  readonly root: BlockIndex;
  readonly head: BlockIndex;
  /** ChainState(head) — the view's justified / finalized / stakes. */
  readonly chainState: ChainState;
  /** The weights this fork choice ran with (stakes and any proposer boost). */
  readonly weights: ForkChoiceWeights;
}

/**
 * The block that receives the proposer boost in a fork choice run at
 * `atSlot` over `view`: the proposal of `atSlot`'s scheduled proposer that
 * the view holds — received during the slot it was proposed in. A proposal
 * that arrives later (delay) belongs to an earlier slot and never qualifies;
 * under a double proposal the smaller index counts as the one received first.
 */
export function boostedBlock(
  view: View,
  atSlot: SlotIndex,
  config: SimulationConfig,
): BlockIndex | undefined {
  if (config.params.boost <= 0) return undefined;
  const proposer = proposerForSlot(atSlot, config);
  let boosted: BlockIndex | undefined;
  for (const block of view.blockTree.blocks.values()) {
    if (block.slot !== atSlot || block.proposer !== proposer) continue;
    if (boosted === undefined || block.index < boosted) boosted = block.index;
  }
  return boosted;
}

/** Total stake of `slot`'s committee in `stakes`. */
export function committeeWeight(
  slot: SlotIndex,
  config: SimulationConfig,
  stakes: ReadonlyMap<ValidatorIndex, Stake>,
): Stake {
  let total = 0;
  for (const v of committeeForSlot(slot, config)) total += stakes.get(v) ?? 0;
  return total;
}

/**
 * Run chain-state derivation and fork choice over a view, as a fork choice
 * computed at `atSlot` (the view's own slot unless the caller acts later,
 * as a proposer does on its view of the slots before its own). A vote
 * weighs the voter's stake in the chain state of the head it votes for
 * (ESSENCE 必須 25: a validator's weight is its stake in its head's chain
 * state), so a penalty included on a branch bites exactly there; the timely
 * proposal of `atSlot` gets its committee's weight × boost on top. The
 * mitigations (緩和策, 必須 27) apply here: the fork-choice rule picks the
 * counted votes, the equivocation discount zeroes a voter this view has
 * seen double-voting, and the checkpoint-switching rule chooses the root
 * (`window`) or prunes the candidates (`unrealized`).
 */
export function resolveView(
  view: View,
  config: SimulationConfig,
  atSlot: SlotIndex = view.slot,
): Resolution {
  const { params } = config;
  const states = chainStatesOf(view.blockTree, config);
  const root = forkChoiceRoot(view.blockTree, states, params.checkpointSwitch, atSlot);
  const discounted = params.equivocationDiscount
    ? equivocatingVoters(view.votes)
    : undefined;
  const weightOf = (vote: Vote): Stake =>
    discounted?.has(vote.validator)
      ? 0
      : (states.get(vote.head)?.stakes.get(vote.validator) ?? 0);
  const boosted = boostedBlock(view, atSlot, config);
  const weights: ForkChoiceWeights = {
    weightOf,
    boost:
      boosted === undefined
        ? undefined
        : {
            block: boosted,
            weight:
              committeeWeight(atSlot, config, states.get(boosted)!.stakes) *
              config.params.boost,
          },
  };
  const head = ghostHead(view.blockTree, view.votes, root, {
    weights,
    rule: params.forkChoice,
    candidates:
      params.checkpointSwitch === "unrealized"
        ? viableBlocks(view.blockTree, states, root)
        : undefined,
  });
  return { states, root, head, chainState: states.get(head)!, weights };
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
