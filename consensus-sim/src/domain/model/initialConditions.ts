// Scenario initial conditions (初期条件) — the part of a scenario's identity
// that the protocol reads: validator count, seed, protocol parameters and
// each validator's initial stake. Everything derived from (slot, params,
// seed) — the proposer schedule and the committees — is public information
// every validator knows.

import type { ProtocolParams } from "./protocolParams";
import type { Stake, ValidatorIndex } from "./types";

export interface InitialConditions {
  readonly validatorCount: number;
  /** Drives every seeded derivation (sized committees); part of the
   * scenario identity, so the same scenario always replays identically. */
  readonly seed: number;
  readonly params: ProtocolParams;
  /** Initial stake (初期ステーク) per validator, indexed by ValidatorIndex.
   * Equal for everyone by default; chain state derives every later stake
   * from these and what the branch has included. */
  readonly initialStakes: readonly Stake[];
}

/** Indices 0..count-1, the identity of every validator in the run. The
 * model is agnostic to the count; the simulator's bound (4〜10) is a
 * constraint enforced in the sim module. */
export function validatorIndices(count: number): ValidatorIndex[] {
  return Array.from({ length: count }, (_, i) => i);
}

/** The initial stake everyone holds unless the scenario says otherwise. */
export const DEFAULT_STAKE: Stake = 32;

export function equalStakes(validatorCount: number): readonly Stake[] {
  return validatorIndices(validatorCount).map(() => DEFAULT_STAKE);
}
