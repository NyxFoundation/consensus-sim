// Domain layer — most-abstract consensus model (最抽象モデル).
// This module is pure: no UI, no infrastructure, no React.
// Naming follows the ubiquitous language of ESSENCE.md's 用語 section.
//
// Identifiers are distinct sorts (識別子のソート): a raw number enters any
// sort, but a value of one sort never passes as another — a slot handed to
// a function expecting a block index is a type error (混用を型検査で防ぐ).
// BlockIndex carries identity only; the total order the skeleton uses to
// break ties lives in order.ts as an explicit rule.

export type ValidatorIndex = number & { readonly __sort?: "ValidatorIndex" };
export type SlotIndex = number & { readonly __sort?: "SlotIndex" };
export type EpochIndex = number & { readonly __sort?: "EpochIndex" };
export type BlockIndex = number & { readonly __sort?: "BlockIndex" };

/** A validator's weight (ステーク), a non-negative rational. Lives in chain
 * state, never in a view. */
export type Stake = number & { readonly __sort?: "Stake" };

/** The anchor block (錨ブロック) is always block 0, the root of every tree. */
export const ANCHOR_BLOCK_INDEX: BlockIndex = 0;

/**
 * The simulation starts at slot 0, the head slot of an epoch. The anchor
 * block sits at slot 0 and is already finalized by agreement of every
 * validator; the first slot advance moves to slot 1, where the first
 * proposal of this run happens.
 */
export const START_SLOT: SlotIndex = 0;

/**
 * An instant (観測時点): one of the three moments of a slot, in this order —
 * a block is published at the proposal instant, votes at the vote instant,
 * and each reaches later instants' views through delivery. An instant is a
 * coordinate of a view (where the knowledge is read), never its content.
 */
export type Phase = "proposal" | "vote" | "end";

export interface Instant {
  readonly slot: SlotIndex;
  readonly phase: Phase;
}

export const atProposal = (slot: SlotIndex): Instant => ({ slot, phase: "proposal" });
export const atVote = (slot: SlotIndex): Instant => ({ slot, phase: "vote" });
export const atEnd = (slot: SlotIndex): Instant => ({ slot, phase: "end" });

/**
 * A checkpoint (チェックポイント): the block that stands for `epoch` on some
 * branch — the latest block on the branch at or before the epoch's first
 * slot. When that boundary slot is empty the same block is the checkpoint
 * of consecutive epochs, so the epoch is part of the identity.
 */
export interface Checkpoint {
  readonly epoch: EpochIndex;
  readonly block: BlockIndex;
}

/** The anchor is the checkpoint of epoch 0 on every branch. */
export const ANCHOR_CHECKPOINT: Checkpoint = { epoch: 0, block: ANCHOR_BLOCK_INDEX };

/**
 * A vote (投票): `head` is the GHOST-style head support (LMD part) and
 * `source` → `target` the FFG pair of checkpoints. Well-formed when
 * `target.epoch` is the epoch of `slot`.
 */
export interface Vote {
  readonly validator: ValidatorIndex;
  readonly slot: SlotIndex;
  readonly head: BlockIndex;
  readonly source: Checkpoint;
  readonly target: Checkpoint;
}

/**
 * Evidence (証拠) of an equivocation (エクイボケーション): a pair of
 * conflicting messages of one validator, in one of three forms —
 * - double proposal (二重提案): two blocks of one slot;
 * - double vote (二重投票): two votes of one slot with different content, or
 *   two votes with the same target epoch and different targets;
 * - surround vote (包囲投票): two votes with
 *   source₁.epoch < source₂.epoch < target₂.epoch < target₁.epoch.
 * The last two are Casper FFG's slashing conditions. Not a message type of
 * its own: it comes into existence in a view holding both messages and is
 * included into a block body. The pair is kept in canonical order (blocks
 * ascending; votes by slot, then the content order of order.ts — so a
 * surrounding vote, whose target epoch is the later, comes second), so
 * identical evidence is identical.
 */
export type Equivocation =
  | {
      readonly kind: "double-proposal";
      readonly validator: ValidatorIndex;
      readonly slot: SlotIndex;
      /** The two conflicting block indices, ascending. */
      readonly blocks: readonly [BlockIndex, BlockIndex];
    }
  | {
      readonly kind: "double-vote";
      readonly votes: readonly [Vote, Vote];
    }
  | {
      readonly kind: "surround-vote";
      /** The surrounded vote, then the surrounding one. */
      readonly votes: readonly [Vote, Vote];
    };

/**
 * What a block carries (取り込み): the votes and evidence its proposer
 * included. Chain state is derived from bodies alone — a vote only counts
 * toward a branch's justification once a block on that branch includes it.
 */
export interface BlockBody {
  readonly votes: readonly Vote[];
  readonly evidence: readonly Equivocation[];
}

/** The anchor (錨): the root of every tree, agreed finalized at the start.
 * Nobody in this run proposed it and it has no parent — there is no
 * sentinel value to stand in for either. */
export interface AnchorBlock {
  readonly kind: "anchor";
  readonly index: BlockIndex;
  readonly slot: SlotIndex;
}

/** A proposed block (提案): what a proposer publishes in its slot. */
export interface ProposedBlock {
  readonly kind: "proposed";
  readonly index: BlockIndex;
  readonly parent: BlockIndex;
  readonly slot: SlotIndex;
  readonly proposer: ValidatorIndex;
  readonly body: BlockBody;
}

/** Reference type from ESSENCE.md: Block = 錨 {index, slot} | 提案 {…}. */
export type Block = AnchorBlock | ProposedBlock;

export const EMPTY_BODY: BlockBody = { votes: [], evidence: [] };

/** The anchor block every simulation starts from. */
export function anchorBlock(): AnchorBlock {
  return { kind: "anchor", index: ANCHOR_BLOCK_INDEX, slot: START_SLOT };
}

export function isProposed(block: Block): block is ProposedBlock {
  return block.kind === "proposed";
}

/** What a block included — nothing, for the anchor. */
export function bodyOf(block: Block): BlockBody {
  return block.kind === "proposed" ? block.body : EMPTY_BODY;
}
