// Attack (攻撃) — the formal system: an attack is the triple
// (attacker set, attack goal, strategy) (必須 17).
//
// - The attacker set (攻撃者集合) is a non-empty subset of the validators. A
//   library attack fixes it up to a condition (攻撃者集合の条件); a scenario
//   binds one concrete set, which may fall short of the condition.
// - The attack goal (攻撃目標) is a non-empty sequence of predicates
//   (attackGoal.ts), judged stage by stage.
// - The strategy (戦略) is a rule that, at every slot boundary, maps what the
//   attackers observe — the merge of their views (attackers share everything
//   instantly and completely) and the schedule — to their actions for the
//   slots ahead, within the capability range (必須 18). A fixed action list
//   is the special case of a strategy that ignores its input.
//
// Changing the triple, the capability range or the predicates' semantics is
// a human decision (ESSENCE 思想 (c)); this module states them as they are.

import type { Action } from "./action";
import type { AttackGoal } from "./attackGoal";
import { addBlock, createBlockTree, type BlockTree } from "./blockTree";
import type { InitialConditions } from "./initialConditions";
import { voteKey } from "./inclusion";
import { isExactRef } from "./messageRef";
import type { Schedule } from "./schedule";
import type { Block, SlotIndex, ValidatorIndex, Vote } from "./types";
import type { View } from "./view";

/**
 * Attack parameters (攻撃パラメータ): per-attack numbers the strategy and the
 * default configuration read. `maxDelay` (d) is common to every attack — the
 * bound on network control: a delay may hold a message back at most d slots
 * past its publication (必須 18).
 */
export interface AttackParams {
  readonly maxDelay: number;
  readonly [name: string]: number;
}

/** The condition an attacker set must satisfy: at least `atLeast`
 * validators, or at least the fraction `atLeast` of the total initial stake. */
export type AttackerCondition =
  | { readonly kind: "count"; readonly atLeast: number }
  | { readonly kind: "stake-ratio"; readonly atLeast: number };

/** The attackers' share of the total initial stake. */
export function attackerStakeRatio(
  attackers: readonly ValidatorIndex[],
  config: InitialConditions,
): number {
  let mine = 0;
  let total = 0;
  config.initialStakes.forEach((stake, v) => {
    total += stake;
    if (attackers.includes(v)) mine += stake;
  });
  return total === 0 ? 0 : mine / total;
}

export function satisfiesCondition(
  condition: AttackerCondition,
  attackers: readonly ValidatorIndex[],
  config: InitialConditions,
): boolean {
  return condition.kind === "count"
    ? attackers.length >= condition.atLeast
    : attackerStakeRatio(attackers, config) >= condition.atLeast;
}

/**
 * What the attackers observe at a slot boundary (攻撃者の観測状態): the end
 * of `slot`, the merge of every attacker's view at that instant, and the
 * schedule. `config` carries the protocol parameters and the initial stakes
 * the attackers reason about (thresholds, presets).
 */
export interface AttackerObservation {
  readonly slot: SlotIndex;
  readonly attackers: readonly ValidatorIndex[];
  /** The merged view: every block and vote any attacker holds. */
  readonly view: View;
  readonly schedule: Schedule;
  readonly config: InitialConditions;
}

/**
 * The merge of views taken at one instant: the union of their blocks (a
 * block whose parent no view holds stays out, as in any view) and of their
 * votes (deduplicated, first occurrence kept). A View like any other — the
 * merge has no coordinate of its own.
 */
export function mergeViews(views: readonly View[]): View {
  if (views.length === 0) throw new Error("mergeViews needs at least one view");
  const blocks = new Map<number, Block>();
  for (const view of views) {
    for (const block of view.blockTree.blocks.values()) blocks.set(block.index, block);
  }
  let blockTree: BlockTree = createBlockTree();
  const ordered = [...blocks.values()].sort((a, b) => a.slot - b.slot || a.index - b.index);
  for (const block of ordered) {
    if (block.kind === "anchor" || !blockTree.blocks.has(block.parent)) continue;
    blockTree = addBlock(blockTree, block);
  }
  const seen = new Set<string>();
  const votes: Vote[] = [];
  for (const view of views) {
    for (const vote of view.votes) {
      const key = voteKey(vote);
      if (seen.has(key)) continue;
      seen.add(key);
      votes.push(vote);
    }
  }
  return { blockTree, votes };
}

/** The attackers' observation at the end of `slot` from their individual
 * views at that instant (one per attacker, in attacker order). */
export function observeAsAttackers(
  attackers: readonly ValidatorIndex[],
  views: readonly View[],
  slot: SlotIndex,
  config: InitialConditions,
  schedule: Schedule,
): AttackerObservation {
  if (attackers.length === 0) throw new Error("the attacker set must not be empty");
  if (views.length !== attackers.length) {
    throw new Error("one view per attacker is required");
  }
  return { slot, attackers, view: mergeViews(views), schedule, config };
}

/** A strategy: the attackers' actions for the slots after the observed
 * boundary. Pure — the same observation and parameters always yield the
 * same actions, which is what makes an attack replay identically. */
export type Strategy = (
  observation: AttackerObservation,
  params: AttackParams,
) => readonly Action[];

/** The triple (攻撃者集合の条件, 攻撃目標, 戦略). */
export interface Attack {
  readonly attackers: AttackerCondition;
  /** Non-empty; judged from the first stage on. */
  readonly goal: readonly AttackGoal[];
  readonly strategy: Strategy;
}

/**
 * The attacker capabilities (攻撃者に必要な能力, 必須 18), one per way an
 * action may fall inside the range: equivocation, parent designation, vote
 * designation and silence of an attacker's own validator; withholding and
 * selective delivery of its own messages; omitted inclusion in its own
 * proposal; delay, drop and partition of honest validators' messages.
 */
export type Capability =
  | "equivocation"
  | "propose-parent"
  | "vote-target"
  | "silence"
  | "withhold"
  | "omit-inclusion"
  | "delay-honest"
  | "drop-honest"
  | "partition";

/**
 * The capability `action` exercises for these attackers, or undefined when
 * the action lies outside the range: acting as a validator that is not an
 * attacker, proposing (parent / omission) in a slot an honest validator
 * proposes, naming an honest message by its individual (an honest message
 * is named ahead of its publication — by sender, slot and kind — because
 * its content is not the attacker's to know in advance; the attacker's own
 * messages it may name either way), or delaying a message more than
 * `maxDelay` slots past its publication.
 */
export function capabilityOf(
  action: Action,
  attackers: readonly ValidatorIndex[],
  schedule: Schedule,
  maxDelay: number,
): Capability | undefined {
  const own = (v: ValidatorIndex): boolean => attackers.includes(v);
  switch (action.kind) {
    case "double-propose":
    case "double-vote":
      return own(action.validator) ? "equivocation" : undefined;
    case "vote-target":
      return own(action.validator) ? "vote-target" : undefined;
    case "stop":
      return action.validators.every(own) ? "silence" : undefined;
    case "propose-parent":
      return own(schedule.proposerOf(action.slot)) ? "propose-parent" : undefined;
    case "omit-inclusion":
      return own(schedule.proposerOf(action.slot)) ? "omit-inclusion" : undefined;
    case "partition":
      return "partition";
    case "delay":
    case "drop": {
      const { sender, slot } = action.message;
      if (
        (!own(sender) && isExactRef(action.message)) ||
        (action.kind === "delay" && action.untilSlot - slot > maxDelay)
      ) {
        return undefined;
      }
      if (own(sender)) return "withhold";
      return action.kind === "delay" ? "delay-honest" : "drop-honest";
    }
  }
}
