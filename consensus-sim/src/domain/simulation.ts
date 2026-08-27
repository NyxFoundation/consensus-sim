// Simulation driver — advances the abstract model one slot at a time,
// fully deterministically (決定性): the state at any slot is a pure function
// of the scenario, so rewind (巻き戻し) is recomputation from the anchor.
//
// At this stage every message is delivered to everyone instantly; the
// per-validator message-visibility model (局所視点) and interventions plug in
// on top of this driver in later Todos without changing its shape.

import { addBlock, createBlockTree, type BlockTree } from "./blockTree";
import { computeFinality, type FinalityState } from "./finality";
import { ghostHead } from "./forkChoice";
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
  readonly tree: BlockTree;
  /** Every vote cast so far, in casting order (deterministic). */
  readonly votes: readonly Vote[];
  readonly finality: FinalityState;
  /** Fork-choice head of each validator (identical while views are shared). */
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
    tree,
    votes: [],
    finality,
    heads,
    nextBlockIndex: ANCHOR_BLOCK_INDEX + 1,
  };
}

/**
 * Advance one slot: the slot's proposer publishes a block on its head, then
 * every validator attests on the updated tree, then justification/finality
 * and every validator's head are recomputed.
 */
export function advanceSlot(
  config: SimulationConfig,
  state: SimulationState,
): SimulationState {
  const slot = state.slot + 1;
  const proposer = proposerForSlot(slot, config.validatorCount);
  const proposal = buildProposal(
    state.tree,
    state.votes,
    state.finality,
    slot,
    proposer,
    state.nextBlockIndex,
  );
  const tree = addBlock(state.tree, proposal);

  const votes = [...state.votes];
  for (const validator of validatorIndices(config.validatorCount)) {
    // Attesters vote after seeing this slot's proposal (instant delivery).
    const finalitySoFar = computeFinality(tree, votes, config.validatorCount);
    votes.push(buildAttestation(tree, votes, finalitySoFar, slot, validator));
  }

  const finality = computeFinality(tree, votes, config.validatorCount);
  const heads = new Map<ValidatorIndex, BlockIndex>(
    validatorIndices(config.validatorCount).map((v) => [
      v,
      ghostHead(tree, votes, finality.justifiedHead),
    ]),
  );
  return {
    slot,
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
): SimulationState {
  if (!Number.isInteger(slot) || slot < START_SLOT) {
    throw new Error(`slot must be an integer ≥ ${START_SLOT}, got ${slot}`);
  }
  let state = initialState(config);
  while (state.slot < slot) {
    state = advanceSlot(config, state);
  }
  return state;
}
