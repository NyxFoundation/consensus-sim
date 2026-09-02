// Attack library strategies (攻撃ライブラリの戦略) — the concrete attacks of
// the formal system, one Strategy and one Attack triple per attack. A strategy
// is a pure rule from the attackers' observation to their actions for the
// slots ahead (attack.ts); a fixed action list emitted once at the first
// boundary is the special case ESSENCE names (固定の介入列は戦略の特殊ケース).
//
// These live in the model module because a strategy and the attack triple are
// part of the essential specification (本質的仕様) — what a Lean formalization
// of the attack system targets. Their library metadata and default runs (the
// simulator's execution concern) live in sim/attackLibrary.ts.
//
// Each strategy is tuned to its attack's declared premise and default run:
// the validator set is round-robin (proposer of slot s is s mod n) and the
// honest chain is linear, so block B_k sits at slot k. The comments state the
// mechanism each attack reproduces (ESSENCE 思想: a reduced version is enough
// as long as the essence is reproduced).

import type { Action } from "./action";
import type { Attack, Strategy } from "./attack";
import type { AttackGoal } from "./attackGoal";

/** Emit `actions` once, at the very first boundary (slot 0), and nothing
 * afterwards — the shape of a fixed-action-list strategy. */
function once(actions: readonly Action[]): Strategy {
  return (observation) => (observation.slot === 0 ? actions : []);
}

// ── A01 Ex-Ante reorg (保留+時機) ────────────────────────────────────────
// The attacker (validator 1) proposes at slot 1 and withholds both its block
// and its vote until slot 3; the honest chain anchor→B2→B3 is defended only by
// proposer boost because the honest attestations are delayed. Revealing at
// slot 3 flips the honest head from B2 to the attacker's B1 — a reorg — under
// phase0 (no boost); under the merge preset the boost saves the honest block,
// so the goal stays out of reach (成功条件 19). d = 2.
export const exAnteReorgA01: Strategy = once([
  { kind: "delay", message: { kind: "proposal", proposer: 1, slot: 1 }, untilSlot: 3 },
  { kind: "delay", message: { kind: "attestation", validator: 1, slot: 1 }, untilSlot: 3 },
  { kind: "delay", message: { kind: "attestation", validator: 0, slot: 2 }, untilSlot: 4 },
  { kind: "delay", message: { kind: "attestation", validator: 2, slot: 2 }, untilSlot: 4 },
  { kind: "delay", message: { kind: "attestation", validator: 3, slot: 2 }, untilSlot: 4 },
  { kind: "delay", message: { kind: "attestation", validator: 0, slot: 3 }, untilSlot: 5 },
  { kind: "delay", message: { kind: "attestation", validator: 2, slot: 3 }, untilSlot: 5 },
  { kind: "delay", message: { kind: "attestation", validator: 3, slot: 3 }, untilSlot: 5 },
]);

const REORG: AttackGoal = { kind: "reorg", count: 1 };

export const ATTACK_A01: Attack = {
  attackers: { kind: "count", atLeast: 1 },
  goal: [REORG],
  strategy: exAnteReorgA01,
};

// ── A02 proposer-boost reversal reorg (boost 逆用) ────────────────────────
// The attacker (validator 1) proposes at slot 5 on the grandparent B3, skipping
// the honest B4, and withholds its own slot-4 vote for B4 (steering it to B3)
// while delaying the other honest slot-4 votes. B4 is then defended by a single
// honest vote (32), below the proposer boost (0.4 × 128 = 51.2) the attacker's
// B5 carries, so the honest head moves B4 → B5 — a reorg that the boost itself
// enables (前提 merge). d = 2.
export const boostReversalA02: Strategy = once([
  { kind: "vote-target", slot: 4, validator: 1, head: 3 },
  { kind: "delay", message: { kind: "attestation", validator: 0, slot: 4 }, untilSlot: 6 },
  { kind: "delay", message: { kind: "attestation", validator: 2, slot: 4 }, untilSlot: 6 },
  { kind: "delay", message: { kind: "attestation", validator: 3, slot: 4 }, untilSlot: 6 },
  { kind: "propose-parent", slot: 5, parent: 3 },
]);

export const ATTACK_A02: Attack = {
  attackers: { kind: "count", atLeast: 1 },
  goal: [REORG],
  strategy: boostReversalA02,
};

// ── A09 finality stall by ≥1/3 abstention (1/3 超の棄権) ───────────────────
// The attackers (validators 2 and 3, half the stake) fall silent from slot 1
// on. With only two validators voting, no source→target link ever reaches the
// two-thirds supermajority, so finalized never leaves the anchor and the god
// view stalls indefinitely (前提 merge; 活性停止).
export const abstainStallA09: Strategy = once([
  { kind: "stop", fromSlot: 1, validators: [2, 3] },
]);

/** Liveness stall threshold L: above the honest start-up stall (≤ 8 slots to
 * the first finalization) so an honest run never trips it. */
const STALL: AttackGoal = { kind: "liveness-stall", slots: 12 };

export const ATTACK_A09: Attack = {
  attackers: { kind: "stake-ratio", atLeast: 1 / 3 },
  goal: [STALL],
  strategy: abstainStallA09,
};

// ── A11 majority fork-choice domination reorg (51% 多数派支配) ─────────────
// The attackers hold a majority of the stake (validators 0, 1, 2). Validator 0
// proposes at slot 4 on the anchor — a fork beside the honest chain — and all
// three attackers steer their slot-4 and slot-5 votes to it. Their weight
// dominates LMD fork choice, so the honest head moves onto the fork, a block
// that does not descend from its slot-3 head: a reorg (前提 merge). A11's
// censorship is out of scope (no transactions); it is treated as majority
// fork-choice domination (ESSENCE 前提事項).
export const majorityReorgA11: Strategy = once([
  { kind: "propose-parent", slot: 4, parent: 0 },
  { kind: "vote-target", slot: 4, validator: 0, head: 4 },
  { kind: "vote-target", slot: 4, validator: 1, head: 4 },
  { kind: "vote-target", slot: 4, validator: 2, head: 4 },
  { kind: "vote-target", slot: 5, validator: 0, head: 4 },
  { kind: "vote-target", slot: 5, validator: 1, head: 4 },
  { kind: "vote-target", slot: 5, validator: 2, head: 4 },
]);

export const ATTACK_A11: Attack = {
  attackers: { kind: "stake-ratio", atLeast: 0.5 },
  goal: [REORG],
  strategy: majorityReorgA11,
};
