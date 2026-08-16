import { describe, expect, it } from 'vitest'
import { buildForkLayout } from '../src/ui/views/forkLayout'
import type { Block } from '../src/protocol/gasper/types'
import type { Hash } from '../src/core/hash'

const GENESIS: Block = { root: 'g000000000000000', slot: 0, parent: '0000000000000000', proposer: 0 }
const B1: Block = { root: 'b100000000000000', slot: 1, parent: GENESIS.root, proposer: 1 }
/** Orphaned: sole block in its column, but not on the canonical path. */
const ORPHAN: Block = { root: 'b200000000000000', slot: 2, parent: B1.root, proposer: 2 }
/** Canonical continuation, skipping the orphan and building on B1 instead. */
const B3: Block = { root: 'b300000000000000', slot: 3, parent: B1.root, proposer: 3 }

function layoutOf(head: Hash) {
  const blocks = new Map<Hash, Block>([
    [GENESIS.root, GENESIS],
    [B1.root, B1],
    [ORPHAN.root, ORPHAN],
    [B3.root, B3],
  ])

  return buildForkLayout({
    blocks,
    head,
    weights: new Map<Hash, number>(),
    currentSlot: 3,
    visibleSlots: 8,
    width: 800,
    height: 400,
  })
}

function yOf(layout: ReturnType<typeof layoutOf>, root: Hash): number {
  const found = layout.blocks.find((item) => item.block.root === root)
  if (found === undefined) throw new Error(`block ${root} was not laid out`)
  return found.y
}

describe('buildForkLayout', () => {
  it('should place the whole canonical chain on a single row', () => {
    const layout = layoutOf(B3.root)

    expect(yOf(layout, GENESIS.root)).toBe(yOf(layout, B1.root))
    expect(yOf(layout, B1.root)).toBe(yOf(layout, B3.root))
  })

  it('should move an orphan off the canonical row even when it is alone in its column', () => {
    const layout = layoutOf(B3.root)

    expect(yOf(layout, ORPHAN.root)).not.toBe(yOf(layout, B1.root))
  })

  it('should mark canonical membership from the observed head', () => {
    const layout = layoutOf(B3.root)
    const canonicalRoots = layout.blocks.filter((item) => item.canonical).map((i) => i.block.root)

    expect(new Set(canonicalRoots)).toEqual(new Set([GENESIS.root, B1.root, B3.root]))
  })

  it('should follow a different head and re-assign the canonical row', () => {
    const layout = layoutOf(ORPHAN.root)

    expect(yOf(layout, ORPHAN.root)).toBe(yOf(layout, B1.root))
    expect(yOf(layout, B3.root)).not.toBe(yOf(layout, B1.root))
  })

  it('should keep a multi-block branch on one row', () => {
    const deepOrphan: Block = { root: 'b400000000000000', slot: 4, parent: ORPHAN.root, proposer: 4 }
    const blocks = new Map<Hash, Block>([
      [GENESIS.root, GENESIS],
      [B1.root, B1],
      [ORPHAN.root, ORPHAN],
      [B3.root, B3],
      [deepOrphan.root, deepOrphan],
    ])
    const layout = buildForkLayout({
      blocks,
      head: B3.root,
      weights: new Map<Hash, number>(),
      currentSlot: 4,
      visibleSlots: 8,
      width: 800,
      height: 400,
    })

    expect(yOf(layout, deepOrphan.root)).toBe(yOf(layout, ORPHAN.root))
  })
})
