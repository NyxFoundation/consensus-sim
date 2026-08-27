// Simulation driver — advances the abstract model one slot at a time,
// fully deterministically (決定性): the state at any slot is a pure function
// of the scenario, so rewind (巻き戻し) is recomputation from the anchor.
//
// Protocol sequencing within a slot s (all order-independent by design):
//   1. the proposer builds on its view of slots < s,
//   2. every validator attests on blocks through s but votes through s-1,
//   3. observers read end-of-slot views (blocks and votes through s).
// Delivery decides who sees what; the default is instant broadcast, and
// interventions later plug in as stricter Delivery rules.

import { addBlock, createBlockTree, type BlockTree } from "./blockTree";
import { computeFinality, type FinalityState } from "./finality";
import {
  instantDelivery,
  localFinalityOf,
  localHeadOf,
  viewOf,
  type Delivery,
} from "./localView";
import { emptyLog, publishBlock, publishVotes, type MessageLog } from "./messages";
import { buildAttestation, buildProposal, proposerForSlot } from "./protocol";
import {
  ANCHOR_BLOCK_INDEX,
  START_SLOT,
  type BlockIndex,
  type SlotIndex,
  type ValidatorIndex,
  type Vote,
} from "./types";
import { assertValidatorCount, validatorIndices } from "./validatorSet";

/**
 * Scenario initial conditions. `seed` is part of the scenario identity
 * (ESSENCE: same scenario including seed ⇒ same result); the current
 * skeleton has no random choice yet, but the seed is carried so recorded
 * scenarios stay stable when a stochastic knob appears.
 */
export interface SimulationConfig {
  readonly validatorCount: number;
  readonly seed: number;
}

/** The complete model state after advancing to `slot`. */
export interface SimulationState {
  readonly slot: SlotIndex;
  /** Every message ever published — the source of truth for all views. */
  readonly log: MessageLog;
  /** God view (神視点): every published block, regardless of delivery. */
  readonly tree: BlockTree;
  /** Every vote cast so far, in casting order (deterministic). */
  readonly votes: readonly Vote[];
  /** Finality over the god view. */
  readonly finality: FinalityState;
  /** Each validator's local fork-choice head (from its own view). */
  readonly heads: ReadonlyMap<ValidatorIndex, BlockIndex>;
  readonly nextBlockIndex: BlockIndex;
}

/** State at slot 0: only the anchor block, no votes, everyone on the anchor. */
export function initialState(config: SimulationConfig): SimulationState {
  assertValidatorCount(config.validatorCount);
  const tree = createBlockTree();
  const finality = computeFinality(tree, [], config.validatorCount);
  const heads = new Map<ValidatorIndex, BlockIndex>(
    validatorIndices(config.validatorCount).map((v) => [v, ANCHOR_BLOCK_INDEX]),
  );
  return {
    slot: START_SLOT,
    log: emptyLog(),
    tree,
    votes: [],
    finality,
    heads,
    nextBlockIndex: ANCHOR_BLOCK_INDEX + 1,
  };
}

/**
 * Advance one slot: the slot's proposer publishes a block built on its own
 * view, every validator attests from its own view, then the god view and
 * every validator's local head are recomputed.
 */
export function advanceSlot(
  config: SimulationConfig,
  state: SimulationState,
  delivery: Delivery = instantDelivery,
): SimulationState {
  const slot = state.slot + 1;
  const validators = validatorIndices(config.validatorCount);

  // 1. Proposal, from the proposer's view of everything before this slot.
  const proposer = proposerForSlot(slot, config.validatorCount);
  const proposerView = viewOf(state.log, proposer, slot - 1, delivery);
  const proposerFinality = localFinalityOf(proposerView, config.validatorCount);
  const proposal = buildProposal(
    proposerView.blockTree,
    proposerView.votes,
    proposerFinality,
    slot,
    proposer,
    state.nextBlockIndex,
  );
  let log = publishBlock(state.log, proposal, slot);

  // 2. Attestations: blocks through this slot, votes through the previous
  // one, so every attester of the slot votes simultaneously.
  const attestations: Vote[] = [];
  for (const validator of validators) {
    const view = viewOf(log, validator, slot, delivery, slot - 1);
    const finality = localFinalityOf(view, config.validatorCount);
    attestations.push(
      buildAttestation(view.blockTree, view.votes, finality, slot, validator),
    );
  }
  log = publishVotes(log, attestations, slot);

  // 3. God view and per-validator end-of-slot heads.
  const tree = addBlock(state.tree, proposal);
  const votes = [...state.votes, ...attestations];
  const finality = computeFinality(tree, votes, config.validatorCount);
  const heads = new Map<ValidatorIndex, BlockIndex>(
    validators.map((v) => {
      const view = viewOf(log, v, slot, delivery);
      return [v, localHeadOf(view, localFinalityOf(view, config.validatorCount))];
    }),
  );
  return {
    slot,
    log,
    tree,
    votes,
    finality,
    heads,
    nextBlockIndex: proposal.index + 1,
  };
}

/**
 * The state at `slot`, recomputed from the anchor. This is both the initial
 * run and the rewind path: rewinding never replays mutable history, it
 * re-derives it.
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
