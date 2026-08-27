// Domain layer — most-abstract consensus model (最抽象モデル).
// This module is pure: no UI, no infrastructure, no React.
// Naming follows the ubiquitous language of ESSENCE.md's 用語 section.

export type ValidatorIndex = number;
export type SlotIndex = number;
export type BlockIndex = number;

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
 * Reference type from ESSENCE.md. `payload: BlockBody` is declared unused
 * there, so the abstract model omits it entirely.
 */
export interface Block {
  readonly index: BlockIndex;
  readonly parent: BlockIndex;
  readonly slot: SlotIndex;
  readonly proposer: ValidatorIndex;
}

/**
 * A vote (投票): `head` is the LMD-GHOST-style head support, and
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

/** The anchor block every simulation starts from. */
export function anchorBlock(): Block {
  return {
    index: ANCHOR_BLOCK_INDEX,
    parent: NO_PARENT,
    slot: START_SLOT,
    proposer: NO_PROPOSER,
  };
}
