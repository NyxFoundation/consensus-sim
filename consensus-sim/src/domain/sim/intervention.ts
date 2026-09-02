// Interventions (介入) — scenario-level disturbances specified at slot
// boundaries: partitions (分断), operating states (稼働状態: 停止/オフライン),
// equivocations (二重提案・二重投票), per-message delay/drop (遅延・欠落, for
// a chosen receiver set), fork creation (フォーク作成: 提案 parent の指定),
// vote designation (投票先指定) and omitted inclusion (取り込みの省略).
//
// Interventions are pure data (persistable as part of a scenario) and are
// compiled into the two axes the engine already accepts: a Delivery rule
// (who sees what by when) and per-slot protocol directives (who acts, and
// whether they equivocate). The engine itself is untouched.

import type { SimulationConfig } from "../model/config";
import type { EvidenceRef, Omission } from "../model/inclusion";
import type { Delivery } from "./localView";
import { sameRef, type MessageRef } from "../model/messageRef";
import type { VoteOverride } from "../model/protocol";
import { proposerForSlot } from "../model/schedule";
import type { SlotDirectives } from "./simulation";
import type { BlockIndex, SlotIndex, ValidatorIndex } from "../model/types";

/** Messages do not cross group boundaries while the partition is active.
 * Validators listed in no group form one implicit remaining group. */
export interface PartitionIntervention {
  readonly kind: "partition";
  readonly fromSlot: SlotIndex;
  /** Last slot the partition is active (inclusive); absent = until healed. */
  readonly toSlot?: SlotIndex;
  readonly groups: readonly (readonly ValidatorIndex[])[];
}

/** オンライン停止: the validators neither propose nor vote while stopped;
 * they still observe (silenced, not blinded). */
export interface StopIntervention {
  readonly kind: "stop";
  readonly fromSlot: SlotIndex;
  /** Last stopped slot (inclusive); absent = until resumed. */
  readonly toSlot?: SlotIndex;
  readonly validators: readonly ValidatorIndex[];
}

/** オフライン: the validators neither send (no proposals, no votes) nor
 * receive — their views freeze at the state on entering offline. After
 * returning they catch up through normal propagation only: pent-up messages
 * arrive from the return slot on, never retroactively into the frozen span. */
export interface OfflineIntervention {
  readonly kind: "offline";
  readonly fromSlot: SlotIndex;
  /** Last offline slot (inclusive); absent = until returned. */
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

/** フォーク作成: the proposer of `slot` builds on `parent` instead of the
 * block its fork choice picks. Ignored — falling back to fork choice — when
 * `parent` is not in the proposer's view at proposal time. */
export interface ProposeParentIntervention {
  readonly kind: "propose-parent";
  readonly slot: SlotIndex;
  readonly parent: BlockIndex;
}

/** The fork count a fork designation may not push past (フォーク上限,
 * 必須 10): current god-view forks + those the pending designations add +
 * this one's own must stay ≤ MAX_FORKS. Forks arising from other
 * interventions are not constrained. */
export const MAX_FORKS = 4;

/** Parents of the fork designations still to execute after `slot`
 * (未実行のフォーク作成指定), in slot order. */
export function pendingForkParents(
  interventions: readonly Intervention[],
  slot: SlotIndex,
): BlockIndex[] {
  return interventions
    .filter(
      (i): i is ProposeParentIntervention =>
        i.kind === "propose-parent" && i.slot > slot,
    )
    .sort((a, b) => a.slot - b.slot)
    .map((i) => i.parent);
}

/** 投票先指定: at `slot`, the validator's vote uses the designated head /
 * source / target (each optional, each a block of its view at voting time;
 * a block it does not hold is ignored). Unspecified components follow fork
 * choice and the FFG rule — from the designated head when there is one. */
export interface VoteTargetIntervention {
  readonly kind: "vote-target";
  readonly slot: SlotIndex;
  readonly validator: ValidatorIndex;
  readonly head?: BlockIndex;
  readonly source?: BlockIndex;
  readonly target?: BlockIndex;
}

/** 取り込みの省略: the proposer of `slot` leaves the named votes (by
 * message identity) and evidence (by equivocator / slot / kind) out of its
 * block body. Everything else is included by the inclusion rule. */
export interface OmitInclusionIntervention {
  readonly kind: "omit-inclusion";
  readonly slot: SlotIndex;
  readonly votes?: readonly MessageRef[];
  readonly evidence?: readonly EvidenceRef[];
}

export type Intervention =
  | PartitionIntervention
  | StopIntervention
  | OfflineIntervention
  | DoubleProposeIntervention
  | DoubleVoteIntervention
  | DelayIntervention
  | DropIntervention
  | ProposeParentIntervention
  | VoteTargetIntervention
  | OmitInclusionIntervention;

/** The interventions that live as a slot span (fromSlot..toSlot). */
export type SpanIntervention =
  | PartitionIntervention
  | StopIntervention
  | OfflineIntervention;

/**
 * End a span at `cursor` (inclusive) so it no longer covers cursor + 1.
 * A span that has not taken effect yet (fromSlot > cursor) cannot be closed
 * — closing it would produce a toSlot-before-fromSlot event — so the caller
 * must remove the entry instead, signalled by `undefined`.
 */
export function closeSpanAt<I extends SpanIntervention>(
  span: I,
  cursor: SlotIndex,
): I | undefined {
  return span.fromSlot > cursor ? undefined : { ...span, toSlot: cursor };
}

const activeAt = (
  fromSlot: SlotIndex,
  toSlot: SlotIndex | undefined,
  slot: SlotIndex,
): boolean => slot >= fromSlot && (toSlot === undefined || slot <= toSlot);

/** 稼働状態: online-and-acting, silenced, or fully cut off. */
export type OperatingState = "active" | "stopped" | "offline";

/** A validator's operating state at `slot` under the scheduled spans.
 * Offline wins over stopped when both spans cover the slot. */
export function operatingStateAt(
  interventions: readonly Intervention[],
  validator: ValidatorIndex,
  slot: SlotIndex,
): OperatingState {
  const covers = (kind: "stop" | "offline"): boolean =>
    interventions.some(
      (i) =>
        i.kind === kind &&
        i.validators.includes(validator) &&
        activeAt(i.fromSlot, i.toSlot, slot),
    );
  return covers("offline") ? "offline" : covers("stop") ? "stopped" : "active";
}

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
 * Monotone pointwise delivery: a message published at p reaches an observer
 * at slot s iff some slot u in [p, s] let it through — every matching delay
 * had expired, sender and observer were unpartitioned, and the observer was
 * online — and it stays arrived (once seen, always seen). So messages
 * published before a partition or an offline span are already through, an
 * offline validator's view freezes (nothing arrives while it is offline),
 * and healing a partition or returning from offline releases everything
 * held back through normal propagation at that slot, never retroactively.
 */
export function compileDelivery(
  interventions: readonly Intervention[],
): Delivery {
  const partitions = interventions.filter(
    (i): i is PartitionIntervention => i.kind === "partition",
  );
  const offlines = interventions.filter(
    (i): i is OfflineIntervention => i.kind === "offline",
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

    if (
      partitions.length === 0 &&
      offlines.length === 0 &&
      delays.length === 0
    ) {
      return true;
    }
    const deliverableAt = (u: SlotIndex): boolean =>
      delays.every(
        (d) =>
          !(sameRef(d.message, message) && targets(d.observers, observer)) ||
          u >= d.untilSlot,
      ) &&
      !partitions.some(
        (p) =>
          activeAt(p.fromSlot, p.toSlot, u) &&
          groupOf(p.groups, sender) !== groupOf(p.groups, observer),
      ) &&
      !offlines.some(
        (o) =>
          activeAt(o.fromSlot, o.toSlot, u) && o.validators.includes(observer),
      );
    for (let u = publishedAt; u <= atSlot; u++) {
      if (deliverableAt(u)) return true;
    }
    return false;
  };
}

/** The protocol directives one slot inherits from the interventions. Stopped
 * and offline validators are equally silent this slot (the difference —
 * whether they still receive — lives on the Delivery axis), so both silence
 * a validator's equivocations too. */
export function directivesForSlot(
  interventions: readonly Intervention[],
  slot: SlotIndex,
  config: SimulationConfig,
): SlotDirectives {
  const stopped = new Set<ValidatorIndex>();
  for (const i of interventions) {
    if (
      (i.kind === "stop" || i.kind === "offline") &&
      activeAt(i.fromSlot, i.toSlot, slot)
    ) {
      for (const v of i.validators) stopped.add(v);
    }
  }
  const proposer = proposerForSlot(slot, config);
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
  let proposeParent: BlockIndex | undefined;
  for (const i of interventions) {
    if (i.kind === "propose-parent" && i.slot === slot && !stopped.has(proposer)) {
      proposeParent = i.parent;
    }
  }
  const omitted = interventions.filter(
    (i): i is OmitInclusionIntervention =>
      i.kind === "omit-inclusion" && i.slot === slot && !stopped.has(proposer),
  );
  const omit: Omission | undefined =
    omitted.length === 0
      ? undefined
      : {
          votes: omitted.flatMap((i) => i.votes ?? []),
          evidence: omitted.flatMap((i) => i.evidence ?? []),
        };
  const voteOverrides = new Map<ValidatorIndex, VoteOverride>();
  for (const i of interventions) {
    if (i.kind === "vote-target" && i.slot === slot && !stopped.has(i.validator)) {
      voteOverrides.set(i.validator, {
        ...voteOverrides.get(i.validator),
        ...(i.head !== undefined ? { head: i.head } : {}),
        ...(i.source !== undefined ? { source: i.source } : {}),
        ...(i.target !== undefined ? { target: i.target } : {}),
      });
    }
  }
  return {
    stopped,
    doublePropose,
    doubleVote,
    ...(proposeParent !== undefined ? { proposeParent } : {}),
    ...(omit !== undefined ? { omit } : {}),
    ...(voteOverrides.size > 0 ? { voteOverrides } : {}),
  };
}
