// Interventions (介入) — scenario-level disturbances specified at slot
// boundaries: partitions (分断), stops (停止/復帰), equivocations
// (二重提案・二重投票), and per-message delay/drop (遅延・欠落).
//
// Interventions are pure data (persistable as part of a scenario) and are
// compiled into the two axes the engine already accepts: a Delivery rule
// (who sees what by when) and per-slot protocol directives (who acts, and
// whether they equivocate). The engine itself is untouched.

import type { Delivery } from "./localView";
import { sameRef, type MessageRef } from "./messages";
import { proposerForSlot } from "./protocol";
import type { SlotDirectives } from "./simulation";
import type { SlotIndex, ValidatorIndex } from "./types";

/** Messages do not cross group boundaries while the partition is active.
 * Validators listed in no group form one implicit remaining group. */
export interface PartitionIntervention {
  readonly kind: "partition";
  readonly fromSlot: SlotIndex;
  /** Last slot the partition is active (inclusive); absent = until healed. */
  readonly toSlot?: SlotIndex;
  readonly groups: readonly (readonly ValidatorIndex[])[];
}

/** The validators neither propose nor vote while stopped; they still observe. */
export interface StopIntervention {
  readonly kind: "stop";
  readonly fromSlot: SlotIndex;
  /** Last stopped slot (inclusive); absent = until resumed. */
  readonly toSlot?: SlotIndex;
  readonly validators: readonly ValidatorIndex[];
}

/** At `slot`, its proposer publishes two blocks on the same parent. Ignored
 * unless `validator` actually proposes that slot. */
export interface DoubleProposeIntervention {
  readonly kind: "double-propose";
  readonly slot: SlotIndex;
  readonly validator: ValidatorIndex;
}

/** At `slot`, the validator casts a second conflicting vote (its head's
 * parent) alongside its honest one. */
export interface DoubleVoteIntervention {
  readonly kind: "double-vote";
  readonly slot: SlotIndex;
  readonly validator: ValidatorIndex;
}

/** One specific message reaches the targeted observers only from `untilSlot`
 * on. The sender always sees its own message. */
export interface DelayIntervention {
  readonly kind: "delay";
  readonly message: MessageRef;
  readonly untilSlot: SlotIndex;
  /** Absent = every observer except the sender. */
  readonly observers?: readonly ValidatorIndex[];
}

/** One specific message never reaches the targeted observers. The sender
 * always sees its own message. */
export interface DropIntervention {
  readonly kind: "drop";
  readonly message: MessageRef;
  /** Absent = every observer except the sender. */
  readonly observers?: readonly ValidatorIndex[];
}

export type Intervention =
  | PartitionIntervention
  | StopIntervention
  | DoubleProposeIntervention
  | DoubleVoteIntervention
  | DelayIntervention
  | DropIntervention;

const activeAt = (
  fromSlot: SlotIndex,
  toSlot: SlotIndex | undefined,
  slot: SlotIndex,
): boolean => slot >= fromSlot && (toSlot === undefined || slot <= toSlot);

/** Group id of `v` under `groups`; unlisted validators share group -1. */
function groupOf(
  groups: readonly (readonly ValidatorIndex[])[],
  v: ValidatorIndex,
): number {
  for (let i = 0; i < groups.length; i++) {
    if (groups[i]?.includes(v)) return i;
  }
  return -1;
}

const targets = (
  observers: readonly ValidatorIndex[] | undefined,
  observer: ValidatorIndex,
): boolean => observers === undefined || observers.includes(observer);

/**
 * Compile the interventions into one Delivery rule.
 *
 * Partition semantics: a message published at p reaches a cross-group
 * observer at slot s iff some slot u in [p, s] was unpartitioned between
 * sender and observer — so messages published before the partition are
 * already through, and healing releases everything held back. Delivery is
 * monotone in s (once seen, always seen).
 */
export function compileDelivery(
  interventions: readonly Intervention[],
): Delivery {
  const partitions = interventions.filter(
    (i): i is PartitionIntervention => i.kind === "partition",
  );
  const delays = interventions.filter(
    (i): i is DelayIntervention => i.kind === "delay",
  );
  const drops = interventions.filter(
    (i): i is DropIntervention => i.kind === "drop",
  );

  return (sender, publishedAt, observer, atSlot, message) => {
    if (publishedAt > atSlot) return false;
    if (observer === sender) return true;

    for (const drop of drops) {
      if (sameRef(drop.message, message) && targets(drop.observers, observer)) {
        return false;
      }
    }
    for (const delay of delays) {
      if (
        sameRef(delay.message, message) &&
        targets(delay.observers, observer) &&
        atSlot < delay.untilSlot
      ) {
        return false;
      }
    }

    if (partitions.length === 0) return true;
    const separatedAt = (u: SlotIndex): boolean =>
      partitions.some(
        (p) =>
          activeAt(p.fromSlot, p.toSlot, u) &&
          groupOf(p.groups, sender) !== groupOf(p.groups, observer),
      );
    for (let u = publishedAt; u <= atSlot; u++) {
      if (!separatedAt(u)) return true;
    }
    return false;
  };
}

/** The protocol directives one slot inherits from the interventions. A
 * stopped validator's equivocations are moot: stopping silences it fully. */
export function directivesForSlot(
  interventions: readonly Intervention[],
  slot: SlotIndex,
  validatorCount: number,
): SlotDirectives {
  const stopped = new Set<ValidatorIndex>();
  for (const i of interventions) {
    if (i.kind === "stop" && activeAt(i.fromSlot, i.toSlot, slot)) {
      for (const v of i.validators) stopped.add(v);
    }
  }
  const proposer = proposerForSlot(slot, validatorCount);
  const doublePropose = interventions.some(
    (i) =>
      i.kind === "double-propose" &&
      i.slot === slot &&
      i.validator === proposer &&
      !stopped.has(proposer),
  );
  const doubleVote = new Set<ValidatorIndex>();
  for (const i of interventions) {
    if (i.kind === "double-vote" && i.slot === slot && !stopped.has(i.validator)) {
      doubleVote.add(i.validator);
    }
  }
  return { stopped, doublePropose, doubleVote };
}
