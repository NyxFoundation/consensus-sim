import { describe, expect, it } from 'vitest'
import { computeDivergence, isAncestorOrSelf } from '../src/ui/divergence'
import type { Block } from '../src/protocol/gasper/types'
import type { Hash } from '../src/core/hash'

const ROOT = '0000000000000000'

function chain(spec: readonly [Hash, number, Hash][]): Map<Hash, Block> {
  return new Map(
    spec.map(([root, slot, parent]) => [root, { root, slot, parent, proposer: slot }]),
  )
}

/**
 *        g -- a1 -- a2 -- a3      (the observed node's chain)
 *               \
 *                b2 -- b3        (a conflicting branch)
 */
const BLOCKS = chain([
  ['g', 0, ROOT],
  ['a1', 1, 'g'],
  ['a2', 2, 'a1'],
  ['a3', 3, 'a2'],
  ['b2', 2, 'a1'],
  ['b3', 3, 'b2'],
])

describe('isAncestorOrSelf', () => {
  it('should hold for a block and itself', () => {
    expect(isAncestorOrSelf(BLOCKS, 'a2', 'a2')).toBe(true)
  })

  it('should hold along the chain', () => {
    expect(isAncestorOrSelf(BLOCKS, 'g', 'a3')).toBe(true)
    expect(isAncestorOrSelf(BLOCKS, 'a1', 'a3')).toBe(true)
  })

  it('should not hold in the descendant direction', () => {
    expect(isAncestorOrSelf(BLOCKS, 'a3', 'a1')).toBe(false)
  })

  it('should not hold across a fork', () => {
    expect(isAncestorOrSelf(BLOCKS, 'b2', 'a3')).toBe(false)
    expect(isAncestorOrSelf(BLOCKS, 'a2', 'b3')).toBe(false)
  })
})

describe('computeDivergence', () => {
  it('should report no fork when every node holds the same head', () => {
    const result = computeDivergence(BLOCKS, ['a3', 'a3', 'a3'], 'a3')

    expect(result.camps).toEqual([])
    expect(result.onChain).toBe(3)
  })

  /**
   * The case the previous head-hash counting got wrong, and the reason the old
   * display flashed a colour every slot: a node that has not yet received the
   * newest block is one block behind on the same chain, not in another camp.
   */
  it('should treat a node that is merely behind as being on the same chain', () => {
    const result = computeDivergence(BLOCKS, ['a3', 'a2', 'a1', 'g'], 'a3')

    expect(result.camps).toEqual([])
    expect(result.onChain).toBe(4)
  })

  it('should treat a node that is ahead as being on the same chain', () => {
    const result = computeDivergence(BLOCKS, ['a2', 'a3'], 'a2')

    expect(result.camps).toEqual([])
    expect(result.onChain).toBe(2)
  })

  it('should report a camp for a branch that conflicts', () => {
    const result = computeDivergence(BLOCKS, ['a3', 'a3', 'b3'], 'a3')

    expect(result.onChain).toBe(2)
    expect(result.camps).toEqual([{ head: 'b3', count: 1 }])
  })

  it('should merge a lagging node into the camp led by its branch tip', () => {
    const result = computeDivergence(BLOCKS, ['a3', 'b3', 'b2'], 'a3')

    expect(result.camps).toEqual([{ head: 'b3', count: 2 }])
  })

  it('should order camps by size', () => {
    const forked = chain([
      ['g', 0, ROOT],
      ['a1', 1, 'g'],
      ['b1', 1, 'g'],
      ['c1', 1, 'g'],
    ])
    const result = computeDivergence(forked, ['a1', 'b1', 'c1', 'c1', 'c1', 'b1'], 'a1')

    expect(result.camps.map((camp) => camp.count)).toEqual([3, 2])
  })

  it('should count an unknown head as a camp of its own', () => {
    const result = computeDivergence(BLOCKS, ['a3', 'ffffffffffffffff'], 'a3')

    expect(result.camps).toHaveLength(1)
  })
})
