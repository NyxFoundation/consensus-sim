import { describe, expect, it } from 'vitest'
import {
  addBlock,
  createBlockTree,
  ANCHOR_BLOCK_INDEX,
} from '../../src/domain'
import type { BlockTree } from '../../src/domain'
import { layoutTree } from '../../src/ui/treeLayout'

function chain(...blocks: Array<[index: number, parent: number, slot: number]>): BlockTree {
  let tree = createBlockTree()
  for (const [index, parent, slot] of blocks) {
    tree = addBlock(tree, { index, parent, slot, proposer: index % 4 })
  }
  return tree
}

describe('layoutTree', () => {
  it('lays out the anchor alone on a single row', () => {
    const layout = layoutTree(createBlockTree())
    expect(layout.rows.get(ANCHOR_BLOCK_INDEX)).toBe(0)
    expect(layout.rowCount).toBe(1)
    expect(layout.maxSlot).toBe(0)
  })

  it('keeps a straight chain on one row', () => {
    const layout = layoutTree(chain([1, 0, 1], [2, 1, 2], [3, 2, 3]))
    for (const index of [0, 1, 2, 3]) {
      expect(layout.rows.get(index)).toBe(0)
    }
    expect(layout.rowCount).toBe(1)
    expect(layout.maxSlot).toBe(3)
  })

  it('gives each fork branch its own row, first child staying on the trunk', () => {
    // Fork at block 1: children 2 and 3, then 3 extends with 4.
    const layout = layoutTree(chain([1, 0, 1], [2, 1, 2], [3, 1, 2], [4, 3, 3]))
    expect(layout.rows.get(0)).toBe(0)
    expect(layout.rows.get(1)).toBe(0)
    expect(layout.rows.get(2)).toBe(0) // first (smallest-index) child keeps the trunk row
    expect(layout.rows.get(3)).toBe(1)
    expect(layout.rows.get(4)).toBe(1)
    expect(layout.rowCount).toBe(2)
  })

  it('is deterministic regardless of insertion order', () => {
    const a = layoutTree(chain([1, 0, 1], [2, 1, 2], [3, 1, 2], [4, 3, 3]))
    const b = layoutTree(chain([1, 0, 1], [3, 1, 2], [4, 3, 3], [2, 1, 2]))
    expect([...a.rows.entries()].sort()).toEqual([...b.rows.entries()].sort())
    expect(a.rowCount).toBe(b.rowCount)
  })
})
