/**
 * Deterministic layout for a block tree: x follows the slot, y follows a
 * depth-first walk that keeps each branch's trunk on a straight row.
 *
 * Rules (all order-independent of insertion order):
 *   - children are visited in ascending block index,
 *   - a leaf claims the next free row,
 *   - an internal block sits on its first child's row, so the chain the
 *     fork choice prefers first reads as one straight line.
 */

import { childrenOf, ANCHOR_BLOCK_INDEX } from '../domain'
import type { BlockIndex, BlockTree } from '../domain'

export interface TreeLayout {
  /** Row (y position index) per block. */
  readonly rows: ReadonlyMap<BlockIndex, number>
  readonly rowCount: number
  /** Highest slot among the laid-out blocks. */
  readonly maxSlot: number
}

export function layoutTree(tree: BlockTree): TreeLayout {
  const rows = new Map<BlockIndex, number>()
  let nextRow = 0

  const place = (index: BlockIndex): number => {
    const children = childrenOf(tree, index)
    if (children.length === 0) {
      const row = nextRow
      nextRow += 1
      rows.set(index, row)
      return row
    }
    const childRows = children.map(place)
    const row = childRows[0] ?? 0
    rows.set(index, row)
    return row
  }

  if (tree.blocks.has(ANCHOR_BLOCK_INDEX)) place(ANCHOR_BLOCK_INDEX)

  let maxSlot = 0
  for (const block of tree.blocks.values()) {
    if (block.slot > maxSlot) maxSlot = block.slot
  }

  return { rows, rowCount: Math.max(nextRow, 1), maxSlot }
}
