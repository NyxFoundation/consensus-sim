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
// An attack declares its premise (前提): the protocol parameters it holds
// under (a preset plus overrides) and the network assumption d, the bound
// on how long an honest message may be held back.
//
// Changing the triple, the capability range or the predicates' semantics is
// a human decision (ESSENCE 思想 (c)); this module states them as they are.

import type { Action } from "./action";
import type { AttackGoal } from "./attackGoal";
import { addBlock, createBlockTree, type BlockTree } from "./blockTree";
import type { InitialConditions } from "./initialConditions";
import { voteKey } from "./inclusion";
import { isExactRef, type MessageRef } from "./messageRef";
import type { PresetName, ProtocolParams } from "./protocolParams";
import type { Schedule } from "./schedule";
import type { Block, SlotIndex, ValidatorIndex, Vote } from "./types";
import type { View } from "./view";

/**
 * The premise (前提) an attack holds under: the protocol parameters as a
 * preset name plus field overrides, and the delay bound d (`maxDelay`) —
 * the network assumption that an honest message reaches every receiver at
 * most d slots after its publication.
 */
export interface AttackPremise {
  readonly preset: PresetName;
  readonly overrides?: Partial<ProtocolParams>;
  readonly maxDelay: number;
}

/**
 * Attack parameters (攻撃パラメータ): per-attack numbers the strategy and the
 * default configuration read. `maxDelay` (d) is common to every attack — the
 * premise's delay bound, which the capability range enforces on the
 * attackers' delays of honest messages (必須 18).
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

// ── The two bases of an attacker's action (行動の 2 基底, 必須 18) ─────────

/** Messages named as a set: everything `senders` publish in a slot span —
 * the shape a partition or a silence refers to. */
export interface MessageSpan {
  readonly senders: readonly ValidatorIndex[];
  readonly fromSlot: SlotIndex;
  /** Inclusive; absent = open-ended. */
  readonly toSlot?: SlotIndex;
}

/**
 * 公開 (i): a message of the attacker's own, named ahead of its publication
 * (by sender, slot and kind — or as a span), and what the action decides
 * about it: its content (from the attacker's observation only — a block's
 * parent and body, a vote's head / source / target: forgery is impossible),
 * its timing (withheld until a later slot), its receiver set (selective
 * delivery), or silence (not published at all).
 */
export interface PublishBase {
  readonly base: "publish";
  readonly message: MessageRef | MessageSpan;
  readonly decides: "content" | "timing" | "receivers" | "silence";
}

/**
 * 配送 (ii): an honest validator's message, named ahead of its publication
 * (or as a span), whose arrival at `observers` (absent = everyone but the
 * sender) is held back `hold` slots past its publication — at most d — or
 * dropped.
 */
export interface DeliverBase {
  readonly base: "deliver";
  readonly message: MessageRef | MessageSpan;
  readonly hold: number | "drop";
  readonly observers?: readonly ValidatorIndex[];
}

export type ActionBase = PublishBase | DeliverBase;

const isSpan = (m: MessageRef | MessageSpan): m is MessageSpan => "senders" in m;

const sendersOf = (m: MessageRef | MessageSpan): readonly ValidatorIndex[] =>
  isSpan(m) ? m.senders : [m.sender];

/** How long a closed span holds a message published inside it, at most. */
const spanHold = (fromSlot: SlotIndex, toSlot: SlotIndex | undefined): number | "drop" =>
  toSlot === undefined ? "drop" : toSlot - fromSlot + 1;

/**
 * The action vocabulary as sugar over the two bases: what an action does to
 * the attackers' own messages (publish) and to honest messages (deliver).
 * A delay or drop is a publish of the attackers' own message (its timing or
 * receivers) and a deliver of an honest one; a partition is the symmetric
 * set — a deliver of every honest message and a publish (receivers) of
 * every attacker's, over the span, held until it heals or dropped when it
 * never does. `attackers` decides which side a sender falls on.
 */
export function basesOf(
  action: Action,
  attackers: readonly ValidatorIndex[],
  schedule: Schedule,
): readonly ActionBase[] {
  const own = (v: ValidatorIndex): boolean => attackers.includes(v);
  const publish = (message: MessageRef | MessageSpan, decides: PublishBase["decides"]): PublishBase =>
    ({ base: "publish", message, decides });
  switch (action.kind) {
    case "double-propose":
      return [publish({ kind: "proposal", sender: action.validator, slot: action.slot }, "content")];
    case "double-vote": {
      const message: MessageRef = { kind: "vote", sender: action.validator, slot: action.slot };
      return action.split === undefined
        ? [publish(message, "content")]
        : [publish(message, "content"), publish(message, "receivers")];
    }
    case "vote-target":
      return [publish({ kind: "vote", sender: action.validator, slot: action.slot }, "content")];
    case "propose-parent":
    case "omit-inclusion":
      return [
        publish(
          { kind: "proposal", sender: schedule.proposerOf(action.slot), slot: action.slot },
          "content",
        ),
      ];
    case "stop":
      return [
        publish(
          {
            senders: action.validators,
            fromSlot: action.fromSlot,
            ...(action.toSlot === undefined ? {} : { toSlot: action.toSlot }),
          },
          "silence",
        ),
      ];
    case "delay":
    case "drop": {
      const hold = action.kind === "delay" ? action.untilSlot - action.message.slot : "drop";
      if (own(action.message.sender)) {
        return [publish(action.message, action.kind === "delay" ? "timing" : "receivers")];
      }
      return [
        {
          base: "deliver",
          message: action.message,
          hold,
          ...(action.observers === undefined ? {} : { observers: action.observers }),
        },
      ];
    }
    case "partition": {
      const hold = spanHold(action.fromSlot, action.toSlot);
      const span = (senders: readonly ValidatorIndex[]): MessageSpan => ({
        senders,
        fromSlot: action.fromSlot,
        ...(action.toSlot === undefined ? {} : { toSlot: action.toSlot }),
      });
      const involved = action.groups.flat();
      const honest = involved.filter((v) => !own(v));
      const mine = involved.filter(own);
      return [
        ...(honest.length === 0 ? [] : [{ base: "deliver", message: span(honest), hold } as const]),
        ...(mine.length === 0 ? [] : [publish(span(mine), "receivers")]),
      ];
    }
  }
}

/**
 * The attacker capabilities (攻撃者に必要な能力, 必須 18) — the names under
 * which the attack list shows what an attack needs — one per way an action
 * may fall inside the range: equivocation, parent designation, vote
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

/** Whether every base of an action lies inside the capability range:
 * a publish must be of the attackers' own messages; a deliver must name an
 * honest message ahead of its publication (never by its individual — its
 * content is not the attacker's to know in advance) and hold it at most
 * `maxDelay` slots, or drop it. */
export function withinRange(
  bases: readonly ActionBase[],
  attackers: readonly ValidatorIndex[],
  maxDelay: number,
): boolean {
  return bases.every((b) =>
    b.base === "publish"
      ? sendersOf(b.message).every((v) => attackers.includes(v))
      : (isSpan(b.message) || !isExactRef(b.message)) &&
        (b.hold === "drop" || b.hold <= maxDelay),
  );
}

/**
 * The capability `action` exercises for these attackers, or undefined when
 * the action lies outside the range (`withinRange` over its bases): acting
 * as a validator that is not an attacker, proposing (parent / omission) in a
 * slot an honest validator proposes, naming an honest message by its
 * individual, or holding honest messages back more than `maxDelay` slots —
 * by a delay, or by a partition that heals later than that. The attackers'
 * own messages they may withhold for any length of time and name either way.
 */
export function capabilityOf(
  action: Action,
  attackers: readonly ValidatorIndex[],
  schedule: Schedule,
  maxDelay: number,
): Capability | undefined {
  if (!withinRange(basesOf(action, attackers, schedule), attackers, maxDelay)) return undefined;
  switch (action.kind) {
    case "double-propose":
    case "double-vote":
      return "equivocation";
    case "vote-target":
      return "vote-target";
    case "stop":
      return "silence";
    case "propose-parent":
      return "propose-parent";
    case "omit-inclusion":
      return "omit-inclusion";
    case "partition":
      return "partition";
    case "delay":
      return attackers.includes(action.message.sender) ? "withhold" : "delay-honest";
    case "drop":
      return attackers.includes(action.message.sender) ? "withhold" : "drop-honest";
  }
}
