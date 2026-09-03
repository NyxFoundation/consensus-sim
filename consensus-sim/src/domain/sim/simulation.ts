// Simulation driver — advances the abstract model one slot at a time,
// fully deterministically (決定性): the state at any slot is a pure function
// of the scenario, so rewind (巻き戻し) is recomputation from the anchor.
//
// Protocol sequencing within a slot s (all order-independent by design):
//   1. the proposer builds on its view of slots < s (parent by fork choice,
//      body by inclusion of everything unincluded on that branch),
//   2. the slot's committee attests on blocks through s (the timely proposal
//      of s carrying the proposer boost) but votes through s-1,
//   3. observers read end-of-slot views (blocks and votes through s).
// Delivery decides who sees what; the default is instant broadcast, and
// interventions plug in as stricter Delivery rules. Who acts — proposer and
// committee — comes from (slot, ProtocolParams, seed) via schedule.ts.

import { addBlock, createBlockTree, type BlockTree } from "../model/blockTree";
import { chainStatesOf, type ChainStateIndex } from "../model/chainState";
import { validatorIndices, type SimulationConfig } from "../model/config";
import type { Omission } from "../model/inclusion";
import { instantDelivery, viewOf, type Delivery } from "./localView";
import { emptyLog, publishBlock, publishVotes, type MessageLog } from "./messages";
import {
  buildAttestation,
  buildEquivocalAttestation,
  buildProposal,
  resolveView,
  type VoteOverride,
} from "../model/protocol";
import { committeeForSlot, proposerForSlot } from "../model/schedule";
import {
  ANCHOR_BLOCK_INDEX,
  START_SLOT,
  type Block,
  type BlockIndex,
  type SlotIndex,
  type ValidatorIndex,
  type Vote,
} from "../model/types";
import { assertValidatorCount } from "./validatorSet";

/** The complete model state after advancing to `slot`. */
export interface SimulationState {
  readonly slot: SlotIndex;
  /** Every message ever published — the source of truth for all views. */
  readonly log: MessageLog;
  /** God view (神視点): every published block, regardless of delivery. */
  readonly tree: BlockTree;
  /** Every vote cast so far, in casting order (deterministic). */
  readonly votes: readonly Vote[];
  /** ChainState(block) for every block of the god view. */
  readonly chainStates: ChainStateIndex;
  /** Each validator's local fork-choice head (from its own view). */
  readonly heads: ReadonlyMap<ValidatorIndex, BlockIndex>;
  readonly nextBlockIndex: BlockIndex;
}

/** State at slot 0: only the anchor block, no votes, everyone on the anchor. */
export function initialState(config: SimulationConfig): SimulationState {
  assertValidatorCount(config.validatorCount);
  const tree = createBlockTree();
  const heads = new Map<ValidatorIndex, BlockIndex>(
    validatorIndices(config.validatorCount).map((v) => [v, ANCHOR_BLOCK_INDEX]),
  );
  return {
    slot: START_SLOT,
    log: emptyLog(),
    tree,
    votes: [],
    chainStates: chainStatesOf(tree, config),
    heads,
    nextBlockIndex: ANCHOR_BLOCK_INDEX + 1,
  };
}

/**
 * Per-slot protocol directives — how interventions bend one slot's protocol
 * actions. Delivery stays a separate axis (who sees what); directives decide
 * who acts and whether they equivocate. Absent fields mean honest behaviour.
 */
export interface SlotDirectives {
  /** Validators that neither propose nor vote this slot (停止/オフライン).
   * Whether they still receive is the Delivery axis's concern, not this
   * one's: this set only silences a validator's own actions. */
  readonly stopped?: ReadonlySet<ValidatorIndex>;
  /** The slot's proposer publishes two blocks on the same parent (二重提案). */
  readonly doublePropose?: boolean;
  /** These validators each cast a second, conflicting vote (二重投票), for
   * the designated head when there is one, else for the first head's parent. */
  readonly doubleVote?: ReadonlyMap<ValidatorIndex, BlockIndex | undefined>;
  /** The proposer builds on this block instead of its fork-choice head
   * (フォーク作成) — ignored when the block is not in the proposer's view. */
  readonly proposeParent?: BlockIndex;
  /** The proposer leaves these votes / this evidence out of its block body
   * (取り込みの省略); everything else follows the inclusion rule. */
  readonly omit?: Omission;
  /** These attesters' votes are steered to designated blocks (投票先指定);
   * unspecified components follow fork choice and the FFG rule. */
  readonly voteOverrides?: ReadonlyMap<ValidatorIndex, VoteOverride>;
}

/**
 * Advance one slot: the slot's proposer publishes a block built on its own
 * view, every validator attests from its own view, then the god view and
 * every validator's local head are recomputed. `directives` bends the slot's
 * protocol actions (stops, equivocations, parent / vote designation,
 * omitted inclusions); a stopped proposer leaves the slot empty.
 */
export function advanceSlot(
  config: SimulationConfig,
  state: SimulationState,
  delivery: Delivery = instantDelivery,
  directives: SlotDirectives = {},
): SimulationState {
  const slot = state.slot + 1;
  const validators = validatorIndices(config.validatorCount);
  const stopped = directives.stopped ?? new Set<ValidatorIndex>();

  // 1. Proposal, from the proposer's view of everything before this slot
  // (a fork choice computed at this slot, so no earlier proposal is boosted).
  // A stopped proposer publishes nothing; a double proposal is a second
  // block on the same parent (conflicting siblings in the same slot).
  const proposer = proposerForSlot(slot, config);
  const proposals: Block[] = [];
  if (!stopped.has(proposer)) {
    const proposerView = viewOf(state.log, proposer, slot - 1, delivery);
    const resolution = resolveView(proposerView, config, slot);
    const proposal = buildProposal(
      proposerView,
      resolution,
      slot,
      proposer,
      state.nextBlockIndex,
      directives.proposeParent ?? resolution.head,
      directives.omit,
    );
    proposals.push(proposal);
    if (directives.doublePropose) {
      proposals.push({ ...proposal, index: proposal.index + 1 });
    }
  }
  let log = state.log;
  for (const block of proposals) log = publishBlock(log, block, slot);

  // 2. Attestations by the slot's committee: blocks through this slot,
  // votes through the previous one, so every attester of the slot votes
  // simultaneously. Stopped validators skip; double voters add a
  // conflicting second vote.
  const committee = committeeForSlot(slot, config);
  const attestations: Vote[] = [];
  for (const validator of validators) {
    if (stopped.has(validator) || !committee.has(validator)) continue;
    const view = viewOf(log, validator, slot, delivery, slot - 1);
    const resolution = resolveView(view, config);
    const vote = buildAttestation(
      view,
      resolution,
      slot,
      validator,
      directives.voteOverrides?.get(validator),
    );
    attestations.push(vote);
    if (directives.doubleVote?.has(validator)) {
      const second = buildEquivocalAttestation(
        view.blockTree,
        vote,
        directives.doubleVote.get(validator),
      );
      if (second !== undefined) attestations.push(second);
    }
  }
  log = publishVotes(log, attestations, slot);

  // 3. God view and per-validator end-of-slot heads.
  let tree = state.tree;
  for (const block of proposals) tree = addBlock(tree, block);
  const votes = [...state.votes, ...attestations];
  const heads = new Map<ValidatorIndex, BlockIndex>(
    validators.map((v) => [
      v,
      resolveView(viewOf(log, v, slot, delivery), config).head,
    ]),
  );
  return {
    slot,
    log,
    tree,
    votes,
    chainStates: chainStatesOf(tree, config),
    heads,
    nextBlockIndex: state.nextBlockIndex + proposals.length,
  };
}

/**
 * The state at `slot`, recomputed from the anchor with honest per-slot
 * behaviour. `delivery` filters what each validator sees, but no slot
 * directives apply — for a scenario whose interventions also silence or
 * equivocate validators, use `scenarioStates`, which compiles both axes.
 */
export function stateAtSlot(
  config: SimulationConfig,
  slot: SlotIndex,
  delivery: Delivery = instantDelivery,
): SimulationState {
  if (!Number.isInteger(slot) || slot < START_SLOT) {
    throw new Error(`slot must be an integer ≥ ${START_SLOT}, got ${slot}`);
  }
  let state = initialState(config);
  while (state.slot < slot) {
    state = advanceSlot(config, state, delivery);
  }
  return state;
}
