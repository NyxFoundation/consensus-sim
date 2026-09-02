// Domain layer — most-abstract consensus model (最抽象モデル).
// This module is pure: no UI, no infrastructure, no React.
// Naming follows the ubiquitous language of ESSENCE.md's 用語 section.

export type ValidatorIndex = number;
export type SlotIndex = number;
export type BlockIndex = number;

/** A validator's weight (ステーク). Lives in chain state, never in a view. */
export type Stake = number;

/** Sentinel parent of the anchor block: the tree's root has no parent. */
export const NO_PARENT: BlockIndex = -1;

/** Sentinel proposer for the anchor block: nobody in this run proposed it. */
export const NO_PROPOSER: ValidatorIndex = -1;

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
 * A vote (投票): `head` is the GHOST-style head support, and
 * `source`/`target` are the FFG-style pair of epoch-boundary checkpoints,
 * both expressed as block indices.
 */
export interface Vote {
  readonly validator: ValidatorIndex;
  readonly slot: SlotIndex;
  readonly head: BlockIndex;
  readonly source: BlockIndex;
  readonly target: BlockIndex;
}

/**
 * Evidence (証拠) of an equivocation (エクイボケーション): two conflicting
 * messages of one validator in one slot — two blocks, or two votes with
 * different content. Not a message type of its own: it comes into existence
 * in a view holding both messages and is included into a block body.
 * The pair is kept in canonical order so identical evidence is identical.
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
      readonly validator: ValidatorIndex;
      readonly slot: SlotIndex;
      /** The two conflicting votes, ascending by (head, source, target). */
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

/** Reference type from ESSENCE.md: Block = {index, parent, slot, proposer, body}. */
export interface Block {
  readonly index: BlockIndex;
  readonly parent: BlockIndex;
  readonly slot: SlotIndex;
  readonly proposer: ValidatorIndex;
  readonly body: BlockBody;
}

export const EMPTY_BODY: BlockBody = { votes: [], evidence: [] };

/** The anchor block every simulation starts from. */
export function anchorBlock(): Block {
  return {
    index: ANCHOR_BLOCK_INDEX,
    parent: NO_PARENT,
    slot: START_SLOT,
    proposer: NO_PROPOSER,
    body: EMPTY_BODY,
  };
}
