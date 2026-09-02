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
import type { Attack, ProposerSchedule, Strategy } from "./attack";
import type { AttackGoal } from "./attackGoal";
import { leavesUnder, type BlockTree } from "./blockTree";
import { validatorIndices } from "./config";
import { SLOTS_PER_EPOCH, slotsSinceEpochStart } from "./finality";
import type { BlockIndex, SlotIndex, ValidatorIndex } from "./types";

/** Emit `actions` once, at the very first boundary (slot 0), and nothing
 * afterwards — the shape of a fixed-action-list strategy. */
function once(actions: readonly Action[]): Strategy {
  return (observation) => (observation.slot === 0 ? actions : []);
}

/** The same vote designation for every attacker at `slot`. */
function voteAll(
  attackers: readonly ValidatorIndex[],
  slot: SlotIndex,
  head: BlockIndex,
): Action[] {
  return attackers.map((validator) => ({ kind: "vote-target", slot, validator, head }));
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

// ── A07 avalanche (秘匿エクイボケーションブロック列の一斉公開) ───────────────
// The attacker (validator 1) builds a withheld chain B1 (slot 1) → B5 (slot
// 5, its next proposal) and votes for it every slot, withholding those votes
// too — at slot 5 with a double vote whose two halves (B5 and its parent B1)
// both fall inside the withheld subtree. Meanwhile the honest chain grows
// anchor→B2→B3→B4 and the attacker delays the honest votes so that, at the
// reveal, each honest validator still sees only its own recent votes plus
// one or two stale ones. Everything is revealed at slot 6. Under GHOST every
// stale and equivocal vote counts: the withheld subtree carries six of the
// attacker's votes (6 × 32) against at most five honest ones, so the honest
// head moves B4 → B5 — a reorg — and the honest votes that follow keep it
// there. Under LMD-GHOST only the attacker's latest vote counts (one half of
// the pair, 32) against at least two honest latest votes (64), and the
// equivocation discount zeroes it outright, so the merge preset (LMD +
// discount, plus boost on the honest proposal) never moves (成功条件 19).
// Premise phase0 + forkChoice GHOST, d = 5.
export const avalancheA07: Strategy = once([
  { kind: "delay", message: { kind: "proposal", proposer: 1, slot: 1 }, untilSlot: 6 },
  { kind: "delay", message: { kind: "attestation", validator: 1, slot: 1 }, untilSlot: 6 },
  { kind: "delay", message: { kind: "attestation", validator: 1, slot: 2 }, untilSlot: 6 },
  { kind: "delay", message: { kind: "attestation", validator: 1, slot: 3 }, untilSlot: 6 },
  { kind: "delay", message: { kind: "attestation", validator: 1, slot: 4 }, untilSlot: 6 },
  { kind: "delay", message: { kind: "attestation", validator: 1, slot: 5 }, untilSlot: 6 },
  ...voteAll([1], 2, 1),
  ...voteAll([1], 3, 1),
  ...voteAll([1], 4, 1),
  { kind: "propose-parent", slot: 5, parent: 1 },
  ...voteAll([1], 5, 5),
  { kind: "double-vote", slot: 5, validator: 1 },
  { kind: "delay", message: { kind: "attestation", validator: 0, slot: 2 }, untilSlot: 7 },
  { kind: "delay", message: { kind: "attestation", validator: 2, slot: 2 }, untilSlot: 7, observers: [0] },
  { kind: "delay", message: { kind: "attestation", validator: 0, slot: 3 }, untilSlot: 7 },
  { kind: "delay", message: { kind: "attestation", validator: 2, slot: 3 }, untilSlot: 7 },
  { kind: "delay", message: { kind: "attestation", validator: 3, slot: 3 }, untilSlot: 7 },
  { kind: "delay", message: { kind: "attestation", validator: 0, slot: 4 }, untilSlot: 8 },
  { kind: "delay", message: { kind: "attestation", validator: 2, slot: 4 }, untilSlot: 8 },
  { kind: "delay", message: { kind: "attestation", validator: 3, slot: 4 }, untilSlot: 8 },
  { kind: "delay", message: { kind: "attestation", validator: 0, slot: 5 }, untilSlot: 9 },
  { kind: "delay", message: { kind: "attestation", validator: 2, slot: 5 }, untilSlot: 9 },
  { kind: "delay", message: { kind: "attestation", validator: 3, slot: 5 }, untilSlot: 9 },
]);

export const ATTACK_A07: Attack = {
  attackers: { kind: "count", atLeast: 1 },
  goal: [REORG],
  strategy: avalancheA07,
};

// ── A10 double finality by 34% double voting (34% 二重投票) ─────────────────
// The attackers (validators 2 and 3, half the stake) split the two honest
// validators' views (分割): validator 0 never sees the attacker block B3
// (built on B1 at slot 3) and validator 1 never sees the honest B4, so from
// slot 4 on each honest validator extends its own branch — A: B1→B2→B4→…,
// B: B1→B3→B5→…. The attackers cast their FFG votes of the same epoch for
// both branches' checkpoints in different slots (時機: B4 at slot 4, B3 at
// slot 5, then B8 at slot 8 and B7 at slot 9), extend both branches from
// their own proposal slots, and each branch's honest validator completes
// its link: {0,2,3} on A, {1,2,3} on B, 3/4 each. Both branches finalize —
// B4 on A, B3 on B — two finalized checkpoints in conflict (安全性違反).
// Slashing (on under merge) never fires: the contradictory target votes are
// cast in different slots, and only same-slot conflicts are evidence in
// this model (the FFG-level double vote is the simplification recorded for
// this attack). Premise merge.
const SPLIT_HONEST: readonly Action[] = [
  { kind: "drop", message: { kind: "proposal", proposer: 3, slot: 3 }, observers: [0] },
  { kind: "drop", message: { kind: "proposal", proposer: 0, slot: 4 }, observers: [1] },
  { kind: "drop", message: { kind: "attestation", validator: 0, slot: 2 }, observers: [1] },
  { kind: "drop", message: { kind: "attestation", validator: 0, slot: 3 }, observers: [1] },
];

export const doubleFinalityA10: Strategy = once([
  { kind: "propose-parent", slot: 3, parent: 1 },
  ...SPLIT_HONEST,
  ...voteAll([2, 3], 3, 3),
  ...voteAll([2, 3], 4, 4),
  ...voteAll([2, 3], 5, 5),
  { kind: "propose-parent", slot: 6, parent: 4 },
  ...voteAll([2, 3], 6, 6),
  { kind: "propose-parent", slot: 7, parent: 5 },
  ...voteAll([2, 3], 7, 7),
  ...voteAll([2, 3], 8, 8),
  ...voteAll([2, 3], 9, 9),
  { kind: "propose-parent", slot: 10, parent: 8 },
  { kind: "propose-parent", slot: 11, parent: 9 },
]);

const SAFETY: AttackGoal = { kind: "safety-violation" };

export const ATTACK_A10: Attack = {
  attackers: { kind: "stake-ratio", atLeast: 1 / 3 },
  goal: [SAFETY],
  strategy: doubleFinalityA10,
};

// ── A12 66% history domination (66% 履歴支配) ──────────────────────────────
// The attackers (validators 0, 1, 2 — three quarters of the stake) first
// behave, so the honest chain finalizes B4 at slot 9. At slot 12 validator 0
// proposes on the anchor — beside the finalized history — and the attackers
// steer their votes to the new branch, extending it from their own slots
// (13, 14). Their supermajority justifies the branch's epoch-3 checkpoint
// (slot 12) and, once the epoch-4 checkpoint is built and voted at slot 16,
// finalizes it at slot 17: a finalized checkpoint that conflicts with the
// already finalized B4 (安全性違反). Premise merge.
export const historyDominationA12: Strategy = once([
  { kind: "propose-parent", slot: 12, parent: 0 },
  ...voteAll([0, 1, 2], 12, 12),
  { kind: "propose-parent", slot: 13, parent: 12 },
  ...voteAll([0, 1, 2], 13, 13),
  { kind: "propose-parent", slot: 14, parent: 13 },
  ...voteAll([0, 1, 2], 14, 14),
  ...voteAll([0, 1, 2], 15, 14),
]);

export const ATTACK_A12: Attack = {
  attackers: { kind: "stake-ratio", atLeast: 2 / 3 },
  goal: [SAFETY],
  strategy: historyDominationA12,
};

// ── A14 inactivity-leak amplification (inactivity leak 増幅) ────────────────
// A reactive strategy (the observation decides the actions, not a fixed
// list). The attackers isolate one honest validator from the rest by
// dropping the two proposals that start the split — the isolated
// validator's first proposal of epoch 1 is dropped for the others, and the
// next honest proposal after it is dropped for the isolated one — so the
// honest validators build two branches, A (the isolated one's) and B (the
// rest's), neither seeing the other's blocks. The attackers see both and
// vote on both every epoch: the second slot of each epoch on A's tip, the
// third on B's tip. On A only the isolated validator and the attackers are
// active, so finality stalls and, once it lags by more than N epochs, the
// rest leak stake there every epoch (罰則 inactivity leak) while the
// attackers never leak. Stage 1: the attackers' share of A's chain state,
// read at the isolated validator's head, reaches 1/3. Stage 2: the same
// erosion makes the isolated validator and the attackers a 2/3 supermajority
// of A, so A finalizes its own checkpoints — in conflict with B's, which the
// attackers' votes kept finalizing all along (安全性違反). Premise merge.
function proposalSlotOf(
  schedule: ProposerSchedule,
  proposers: readonly ValidatorIndex[],
  from: SlotIndex,
  validatorCount: number,
): SlotIndex | undefined {
  for (let slot = from; slot < from + validatorCount * SLOTS_PER_EPOCH; slot++) {
    if (proposers.includes(schedule.proposerOf(slot))) return slot;
  }
  return undefined;
}

/** The block a validator proposed at `slot`, when the view holds it. */
function blockBy(
  tree: BlockTree,
  proposer: ValidatorIndex,
  slot: SlotIndex,
): BlockIndex | undefined {
  for (const block of tree.blocks.values()) {
    if (block.proposer === proposer && block.slot === slot) return block.index;
  }
  return undefined;
}

/** The deepest leaf under `root` (latest slot, then smallest index). */
function tipUnder(tree: BlockTree, root: BlockIndex): BlockIndex {
  let tip = root;
  for (const leaf of leavesUnder(tree, root)) {
    const a = tree.blocks.get(leaf)!;
    const b = tree.blocks.get(tip)!;
    if (a.slot > b.slot || (a.slot === b.slot && a.index < b.index)) tip = leaf;
  }
  return tip;
}

export const leakAmplificationA14: Strategy = ({ slot, attackers, view, schedule, config }) => {
  const honest = validatorIndices(config.validatorCount).filter((v) => !attackers.includes(v));
  const isolated = honest[0];
  const rest = honest.slice(1);
  if (isolated === undefined || rest.length === 0) return [];
  const splitA = proposalSlotOf(schedule, [isolated], SLOTS_PER_EPOCH, config.validatorCount);
  if (splitA === undefined) return [];
  const splitB = proposalSlotOf(schedule, rest, splitA + 1, config.validatorCount);
  if (splitB === undefined) return [];

  const actions: Action[] = [];
  if (slot === 0) {
    actions.push(
      { kind: "drop", message: { kind: "proposal", proposer: isolated, slot: splitA }, observers: rest },
      {
        kind: "drop",
        message: { kind: "proposal", proposer: schedule.proposerOf(splitB), slot: splitB },
        observers: [isolated],
      },
    );
  }
  const next = slot + 1;
  const phase = slotsSinceEpochStart(next);
  const fork =
    phase === 1
      ? blockBy(view.blockTree, isolated, splitA)
      : phase === 2
        ? blockBy(view.blockTree, schedule.proposerOf(splitB), splitB)
        : undefined;
  if (fork !== undefined) actions.push(...voteAll(attackers, next, tipUnder(view.blockTree, fork)));
  return actions;
};

export const ATTACK_A14: Attack = {
  attackers: { kind: "count", atLeast: 1 },
  goal: [{ kind: "attacker-stake-ratio", threshold: 1 / 3 }, SAFETY],
  strategy: leakAmplificationA14,
};
