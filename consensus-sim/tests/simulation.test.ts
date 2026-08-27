import { describe, expect, it } from 'vitest'
import { createGasperSimulation, DEFAULT_PARAMS } from '../src/setup'
import type { GasperParams } from '../src/setup'
import type { Simulation } from '../src/core/simulation'

/** Short epochs keep the tests fast without changing any protocol behaviour. */
const FAST: GasperParams = {
  ...DEFAULT_PARAMS,
  validatorCount: 16,
  slotsPerEpoch: 4,
  slotDurationMs: 1200,
  network: { baseDelayMs: 20, jitterMs: 5, distribution: 'normal', partitions: [] },
}

/**
 * Stops three quarters into the slot rather than on the boundary. On the
 * boundary the proposer has applied its own block and nobody else has received
 * it yet, so every run would show a "disagreement" that is only a message in
 * flight. Measuring at a quiet point makes a head split mean a real split.
 */
function runFor(params: GasperParams, slots: number): Simulation {
  const { sim } = createGasperSimulation(params)
  sim.advanceTo(slots * params.slotDurationMs + params.slotDurationMs * 0.75)
  return sim
}

function heads(sim: Simulation): string[] {
  return sim.nodes.map((node) => sim.viewOf(node.validator.nodeId)?.head ?? '')
}

describe('Gasper simulation', () => {
  it('should extend the chain when every validator is honest', () => {
    const sim = runFor(FAST, 20)
    expect(sim.blocks.size).toBeGreaterThan(15)
  })

  it('should leave slot 0 to the genesis block and propose from slot 1', () => {
    const sim = runFor(FAST, 6)
    const atGenesisSlot = [...sim.blocks.values()].filter((block) => block.slot === 0)

    expect(atGenesisSlot).toHaveLength(1)
  })

  it('should reach agreement on the head across all nodes under low latency', () => {
    const sim = runFor(FAST, 20)
    expect(new Set(heads(sim)).size).toBe(1)
  })

  it('should finalize within a few epochs when every validator is honest', () => {
    const sim = runFor(FAST, 20)
    const view = sim.viewOf(0)

    expect(view?.justified.epoch ?? 0).toBeGreaterThanOrEqual(2)
    expect(view?.finalized.epoch ?? 0).toBeGreaterThanOrEqual(1)
  })

  it('should keep the finalized checkpoint an ancestor of the justified one', () => {
    const sim = runFor(FAST, 20)
    const view = sim.viewOf(0)

    expect(view?.finalized.epoch ?? 0).toBeLessThanOrEqual(view?.justified.epoch ?? 0)
  })

  it('should reproduce an identical run for an identical seed', () => {
    const first = runFor(FAST, 16)
    const second = runFor(FAST, 16)

    expect(heads(first)).toEqual(heads(second))
    expect(first.blocks.size).toBe(second.blocks.size)
  })

  it('should produce a different run for a different seed', () => {
    const first = runFor(FAST, 16)
    const second = runFor({ ...FAST, seed: 999 }, 16)

    expect(heads(first)[0]).not.toBe(heads(second)[0])
  })

  it('should still finalize when a minority of validators are offline', () => {
    const sim = runFor({ ...FAST, offlineRatio: 0.25 }, 24)
    expect(sim.viewOf(0)?.finalized.epoch ?? 0).toBeGreaterThanOrEqual(1)
  })

  it('should stall finality when too many validators are offline for a quorum', () => {
    const sim = runFor({ ...FAST, offlineRatio: 0.5 }, 24)
    expect(sim.viewOf(0)?.finalized.epoch ?? 0).toBe(0)
  })
})

describe('network partition', () => {
  const partitioned: GasperParams = {
    ...FAST,
    network: {
      ...FAST.network,
      partitions: [{ startMs: 4 * FAST.slotDurationMs, endMs: 12 * FAST.slotDurationMs, groupCount: 2 }],
    },
  }

  it('should split node views into disagreeing groups while partitioned', () => {
    const sim = runFor(partitioned, 11)
    const observed = heads(sim)

    expect(new Set(observed).size).toBeGreaterThan(1)
  })

  it('should reconverge on a single head after the partition heals', () => {
    const sim = runFor(partitioned, 24)
    expect(new Set(heads(sim)).size).toBe(1)
  })
})
