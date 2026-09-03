/**
 * Shared horizontal geometry of the chain display: the block tree (SVG) and
 * the state table below it must place slot s at the same x position, so both
 * read these constants instead of hard-coding their own.
 */

/** Width of one slot column — with LABEL_W, about ten slots fill the stage
 * of a standard PC width (the dock takes the rest, tokens.css --dock-w). */
export const COL_W = 96
/** Height of one fork row in the tree. */
export const ROW_H = 92
export const BLOCK_W = 64
export const BLOCK_H = 40
/** Left/right padding inside the tree SVG. */
export const PAD_X = 24
export const PAD_TOP = 40
export const PAD_BOTTOM = 32

/** Width of the state table's validator-label column. */
export const LABEL_W = 96

/**
 * Left margin of the state table so a cell's centre sits under the block
 * centre of the same slot (the tree itself is offset by LABEL_W).
 */
export const TABLE_OFFSET = PAD_X + BLOCK_W / 2 - COL_W / 2
