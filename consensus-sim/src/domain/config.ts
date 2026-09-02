// Scenario initial conditions (初期条件) — the part of a scenario's identity
// that the protocol reads: validator count, seed and protocol parameters.
// Everything derived from (slot, params, seed) — the proposer schedule and
// the committees — is public information every validator knows.

import type { ProtocolParams } from "./protocolParams";

export interface SimulationConfig {
  readonly validatorCount: number;
  /** Drives every seeded derivation (sized committees); part of the
   * scenario identity, so the same scenario always replays identically. */
  readonly seed: number;
  readonly params: ProtocolParams;
}
