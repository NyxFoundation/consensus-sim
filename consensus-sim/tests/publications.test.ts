import { describe, expect, it } from 'vitest'
import { createGasperSimulation, DEFAULT_PARAMS } from '../src/setup'
import type { GasperParams } from '../src/setup'
import type { Simulation } from '../src/core/simulation'

const FAST: GasperParams = {
  ...DEFAULT_PARAMS,
  validatorCount: 16,
  slotsPerEpoch: 4,
  slotDurationMs: 1200,
  network: { baseDelayMs: 20, jitterMs: 5, distribution: 'normal', partitions: [] },
}

/** 16 validators spread over 4 slots per epoch. */
const COMMITTEE_SIZE = 4

function runTo(params: GasperParams, endSlot: number): Simulation {
  const { sim } = createGasperSimulation(params)
  sim.advanceTo(endSlot * params.slotDurationMs + params.slotDurationMs * 0.75)
  return sim
}

describe('publication log', () => {
  it('should record no proposal in the genesis slot', () => {
    const sim = runTo(FAST, 0)
    expect(sim.publicationsInSlot(0).filter((p) => p.kind === 'block')).toHaveLength(0)
  })

  it('should record exactly one block per slot when the proposer participates', () => {
    const sim = runTo(FAST, 4)
    const blocks = sim.publicationsInSlot(2).filter((p) => p.kind === 'block')

    expect(blocks).toHaveLength(1)
  })

  it('should record one attestation per committee member', () => {
    const sim = runTo(FAST, 4)
    const votes = sim.publicationsInSlot(2).filter((p) => p.kind === 'attestation')

    expect(votes).toHaveLength(COMMITTEE_SIZE)
  })

  it('should reach every node once propagation completes', () => {
    const sim = runTo(FAST, 4)
    const delivered = sim.publicationsInSlot(2).map((p) => p.delivered)

    expect(delivered.every((count) => count === FAST.validatorCount)).toBe(true)
  })

  it('should count the sender immediately, before any delay has elapsed', () => {
    const { sim } = createGasperSimulation(FAST)
    // Land just past the slot-1 proposal but well inside the 20ms link delay.
    sim.advanceTo(FAST.slotDurationMs + 5)
    const block = sim.publicationsInSlot(1).find((p) => p.kind === 'block')

    expect(block?.delivered).toBe(1)
  })

  it('should stamp every decile of a fully propagated broadcast', () => {
    const sim = runTo(FAST, 4)
    const block = sim.publicationsInSlot(2).find((p) => p.kind === 'block')

    expect(block?.milestones.every((time) => time !== null)).toBe(true)
  })

  it('should stamp the deciles in non-decreasing order', () => {
    const sim = runTo(FAST, 4)
    const stamps = (sim.publicationsInSlot(2).find((p) => p.kind === 'block')?.milestones ??
      []) as (number | null)[]

    for (let i = 1; i < stamps.length; i++) {
      expect(stamps[i] ?? 0).toBeGreaterThanOrEqual(stamps[i - 1] ?? 0)
    }
  })

  /**
   * The reason the timeline shows propagation at all: under a partition the
   * curve visibly stalls part way up instead of completing, which is the
   * difference between a parameter and something you can watch.
   */
  it('should stall delivery at the partition boundary', () => {
    const partitioned: GasperParams = {
      ...FAST,
      network: {
        ...FAST.network,
        partitions: [{ startMs: 4 * FAST.slotDurationMs, endMs: 12 * FAST.slotDurationMs, groupCount: 2 }],
      },
    }
    const sim = runTo(partitioned, 6)
    const block = sim.publicationsInSlot(5).find((p) => p.kind === 'block')

    expect(block?.delivered).toBe(FAST.validatorCount / 2)
  })

  it('should leave the upper deciles unstamped while a partition holds', () => {
    const partitioned: GasperParams = {
      ...FAST,
      network: {
        ...FAST.network,
        partitions: [{ startMs: 4 * FAST.slotDurationMs, endMs: 12 * FAST.slotDurationMs, groupCount: 2 }],
      },
    }
    const sim = runTo(partitioned, 6)
    const stamps = sim.publicationsInSlot(5).find((p) => p.kind === 'block')?.milestones ?? []

    // Half the audience: deciles up to 50% land, the rest wait for healing.
    expect(stamps[5]).not.toBeNull()
    expect(stamps[6]).toBeNull()
  })

  it('should complete delivery of the withheld copies once the partition heals', () => {
    const partitioned: GasperParams = {
      ...FAST,
      network: {
        ...FAST.network,
        partitions: [{ startMs: 4 * FAST.slotDurationMs, endMs: 12 * FAST.slotDurationMs, groupCount: 2 }],
      },
    }
    const sim = runTo(partitioned, 13)
    const block = sim.publicationsInSlot(5).find((p) => p.kind === 'block')

    expect(block?.delivered).toBe(FAST.validatorCount)
  })
})
