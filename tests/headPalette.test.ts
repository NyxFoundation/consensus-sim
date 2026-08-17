import { describe, expect, it } from 'vitest'
import { AGREE, OTHER, assignKinds, createRegistry } from '../src/ui/headPalette'

const A = 'aaaaaaaaaaaaaaaa'
const B = 'bbbbbbbbbbbbbbbb'
const C = 'cccccccccccccccc'
const D = 'dddddddddddddddd'
const E = 'eeeeeeeeeeeeeeee'

describe('assignKinds', () => {
  it('should mark every node neutral when the network agrees', () => {
    const result = assignKinds(createRegistry(), [A, A, A, A], A)

    expect(result.kinds).toEqual([AGREE, AGREE, AGREE, AGREE])
    expect(result.agreeCount).toBe(4)
    expect(result.dissent).toEqual([])
  })

  it('should give each contested head its own categorical slot', () => {
    const result = assignKinds(createRegistry(), [A, B, C, A], A)

    expect(result.kinds).toEqual([AGREE, 1, 2, AGREE])
    expect(result.dissent.map((entry) => entry.count)).toEqual([1, 1])
  })

  /**
   * The invariant the whole redesign rests on: a majority and a minority
   * swapping places must not repaint the survivors. Assigning colour by rank
   * would flip every cell at the moment the counts cross.
   */
  it('should keep a head colour when it goes from minority to majority', () => {
    const registry = createRegistry()
    assignKinds(registry, [A, A, A, B], A)
    const after = assignKinds(registry, [B, B, B, A], A)

    expect(registry.slots.get(B)).toBe(1)
    expect(after.kinds).toEqual([1, 1, 1, AGREE])
  })

  it('should keep slots stable across repeated evaluations', () => {
    const registry = createRegistry()
    const first = assignKinds(registry, [A, B, C], A)
    const second = assignKinds(registry, [A, C, B], A)

    expect(first.kinds).toEqual([AGREE, 1, 2])
    expect(second.kinds).toEqual([AGREE, 2, 1])
  })

  it('should fold a fourth contested head into the other bucket', () => {
    const result = assignKinds(createRegistry(), [A, B, C, D, E], A)

    expect(result.kinds).toEqual([AGREE, 1, 2, 3, OTHER])
    expect(result.otherCount).toBe(1)
  })

  it('should re-colour relative to a newly observed node', () => {
    const registry = createRegistry()
    assignKinds(registry, [A, A, B], A)
    const fromB = assignKinds(registry, [A, A, B], B)

    // A becomes the dissenting head and takes the next free slot; B, now the
    // reference, is neutral. The slot B already held is not reused for A.
    expect(fromB.kinds).toEqual([2, 2, AGREE])
  })

  it('should start colour assignment over on a fresh registry', () => {
    const first = assignKinds(createRegistry(), [A, B], A)
    const second = assignKinds(createRegistry(), [A, C], A)

    expect(first.kinds).toEqual([AGREE, 1])
    expect(second.kinds).toEqual([AGREE, 1])
  })
})
