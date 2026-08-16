import { describe, expect, it } from 'vitest'
import { makeRng } from '../src/core/rng'

describe('makeRng', () => {
  it('should produce an identical sequence when seeded identically', () => {
    const a = makeRng(42)
    const b = makeRng(42)
    const drawA = Array.from({ length: 20 }, () => a.next())
    const drawB = Array.from({ length: 20 }, () => b.next())

    expect(drawA).toEqual(drawB)
  })

  it('should produce a different sequence for a different seed', () => {
    const a = Array.from({ length: 20 }, makeRng(1).next)
    const b = Array.from({ length: 20 }, makeRng(2).next)

    expect(a).not.toEqual(b)
  })

  it('should isolate forked streams so drawing from one cannot shift the other', () => {
    const parentA = makeRng(7)
    const networkA = parentA.fork('network')
    // Draw from an unrelated fork before sampling, as adding a subsystem would.
        parentA.fork('duties').next()
    const sampleA = Array.from({ length: 10 }, () => networkA.next())

    const networkB = makeRng(7).fork('network')
    const sampleB = Array.from({ length: 10 }, () => networkB.next())

    expect(sampleA).toEqual(sampleB)
  })

  it('should shuffle without mutating the input and keep every element', () => {
    const input = Object.freeze([1, 2, 3, 4, 5, 6, 7, 8])
    const shuffled = makeRng(3).shuffle(input)

    expect(input).toEqual([1, 2, 3, 4, 5, 6, 7, 8])
    expect([...shuffled].sort((x, y) => x - y)).toEqual([1, 2, 3, 4, 5, 6, 7, 8])
  })

  it('should keep int() inside the requested range', () => {
    const rng = makeRng(11)
    for (let i = 0; i < 500; i++) {
      const value = rng.int(7)
      expect(value).toBeGreaterThanOrEqual(0)
      expect(value).toBeLessThan(7)
    }
  })
})
