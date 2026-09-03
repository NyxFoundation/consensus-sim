// Actions (行動) — the disturbances a slot boundary can carry: partitions
// (分断), silence (沈黙 = オンライン停止), equivocations (二重提案・二重投票),
// per-message delay / drop for a chosen receiver set (遅延・欠落, 受信者集合),
// fork creation (提案 parent の指定), vote designation (投票先指定) and
// omitted inclusion (取り込みの省略).
//
// These shapes are the attacker's action vocabulary (攻撃者の行動語彙,
// 必須 18): a strategy may use every kind, within the capability range that
// attack.ts checks (its own validators for equivocation / parent / vote /
// silence / omission, its own messages for withholding and selective
// delivery, honest messages for delay / drop / partition). The same shapes,
// with the offline state added, are what a manual intervention designates
// (sim/intervention.ts). Pure data, persistable as part of a scenario.

import type { EvidenceRef } from "./inclusion";
import type { MessageRef } from "./messageRef";
import type { BlockIndex, SlotIndex, ValidatorIndex } from "./types";

/** Messages do not cross group boundaries while the partition is active.
 * Validators listed in no group form one implicit remaining group. */
export interface PartitionAction {
  readonly kind: "partition";
  readonly fromSlot: SlotIndex;
  /** Last slot the partition is active (inclusive); absent = until healed. */
  readonly toSlot?: SlotIndex;
  readonly groups: readonly (readonly ValidatorIndex[])[];
}

/** オンライン停止 / 沈黙: the validators neither propose nor vote while
 * stopped; they still observe (silenced, not blinded). */
export interface StopAction {
  readonly kind: "stop";
  readonly fromSlot: SlotIndex;
  /** Last stopped slot (inclusive); absent = until resumed. */
  readonly toSlot?: SlotIndex;
  readonly validators: readonly ValidatorIndex[];
}

/** At `slot`, its proposer publishes two blocks on the same parent. Ignored
 * unless `validator` actually proposes that slot. */
export interface DoubleProposeAction {
  readonly kind: "double-propose";
  readonly slot: SlotIndex;
  readonly validator: ValidatorIndex;
}

/** At `slot`, the validator casts a second conflicting vote alongside its
 * first one: for `head` when designated (a block of its view other than the
 * first vote's head — an attacker's selective delivery names it), otherwise
 * for the first head's parent. */
export interface DoubleVoteAction {
  readonly kind: "double-vote";
  readonly slot: SlotIndex;
  readonly validator: ValidatorIndex;
  readonly head?: BlockIndex;
}

/** The named message reaches the targeted observers only from `untilSlot`
 * on. The sender always sees its own message. Named ahead of publication
 * (proposal / attestation reference), this is the sender's own withholding
 * and selective delivery (保留と選択配送). */
export interface DelayAction {
  readonly kind: "delay";
  readonly message: MessageRef;
  readonly untilSlot: SlotIndex;
  /** Absent = every observer except the sender. */
  readonly observers?: readonly ValidatorIndex[];
}

/** The named message never reaches the targeted observers. The sender
 * always sees its own message. */
export interface DropAction {
  readonly kind: "drop";
  readonly message: MessageRef;
  /** Absent = every observer except the sender. */
  readonly observers?: readonly ValidatorIndex[];
}

/** フォーク作成: the proposer of `slot` builds on `parent` instead of the
 * block its fork choice picks. Ignored — falling back to fork choice — when
 * `parent` is not in the proposer's view at proposal time. */
export interface ProposeParentAction {
  readonly kind: "propose-parent";
  readonly slot: SlotIndex;
  readonly parent: BlockIndex;
}

/** 投票先指定: at `slot`, the validator's vote uses the designated head /
 * source / target (each optional, each a block of its view at voting time;
 * a block it does not hold is ignored). Unspecified components follow fork
 * choice and the FFG rule — from the designated head when there is one. */
export interface VoteTargetAction {
  readonly kind: "vote-target";
  readonly slot: SlotIndex;
  readonly validator: ValidatorIndex;
  readonly head?: BlockIndex;
  readonly source?: BlockIndex;
  readonly target?: BlockIndex;
}

/** 取り込みの省略: the proposer of `slot` leaves the named votes (by
 * message reference) and evidence (by equivocator / slot / kind) out of its
 * block body. Everything else is included by the inclusion rule. */
export interface OmitInclusionAction {
  readonly kind: "omit-inclusion";
  readonly slot: SlotIndex;
  readonly votes?: readonly MessageRef[];
  readonly evidence?: readonly EvidenceRef[];
}

export type Action =
  | PartitionAction
  | StopAction
  | DoubleProposeAction
  | DoubleVoteAction
  | DelayAction
  | DropAction
  | ProposeParentAction
  | VoteTargetAction
  | OmitInclusionAction;
