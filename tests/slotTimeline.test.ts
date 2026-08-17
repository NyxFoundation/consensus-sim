import { describe, expect, it } from 'vitest'
import { blockMeter, voteMeter } from '../src/ui/views/SlotTimelineView'
import type { SlotTimelineProps } from '../src/ui/views/SlotTimelineView'
import type { Publication } from '../src/core/simulation'
import { paletteFor } from '../src/ui/theme'

const SLOT = 3
const SLOT_START = 36_000
const SLOT_DURATION = 12_000
const ATTESTATION_OFFSET = 4_000
const NODES = 64

function publication(overrides: Partial<Publication> & Pick<Publication, 'kind'>): Publication {
  return {
    id: 0,
    time: SLOT_START,
    slot: SLOT,
    from: 7,
    layer: 'gasper',
    delivered: 0,
    ...overrides,
  }
}

function props(overrides: Partial<SlotTimelineProps> = {}): SlotTimelineProps {
  return {
    slot: SLOT,
    slotStartMs: SLOT_START,
    slotDurationMs: SLOT_DURATION,
    attestationOffsetMs: ATTESTATION_OFFSET,
    nowMs: SLOT_START + 1_000,
    proposer: 7,
    proposerActive: true,
    committeeSize: 8,
    publications: [],
    nodeCount: NODES,
    palette: paletteFor('light'),
    ...overrides,
  }
}

describe('blockMeter', () => {
  it('should read as waiting before the voting deadline when nothing has been proposed', () => {
    const meter = blockMeter(props())

    expect(meter.startedAt).toBeNull()
    expect(meter.detail).toContain('待機')
  })

  it('should read as a missed proposal once the deadline has passed', () => {
    const meter = blockMeter(props({ nowMs: SLOT_START + ATTESTATION_OFFSET + 1 }))

    expect(meter.detail).toContain('提案なし')
  })

  it('should report the fraction of nodes holding the block', () => {
    const meter = blockMeter(
      props({ publications: [publication({ kind: 'block', delivered: 32, time: SLOT_START + 20 })] }),
    )

    expect(meter.fraction).toBeCloseTo(0.5, 6)
    expect(meter.startedAt).toBe(SLOT_START + 20)
    expect(meter.detail).toContain('32/64')
  })

  /** A partition is exactly this: the meter stops short instead of completing. */
  it('should stay part filled while a partition withholds the rest', () => {
    const meter = blockMeter(
      props({ publications: [publication({ kind: 'block', delivered: 8 })] }),
    )

    expect(meter.fraction).toBeCloseTo(8 / 64, 6)
  })

  it('should reach one when every node holds the block', () => {
    const meter = blockMeter(
      props({ publications: [publication({ kind: 'block', delivered: NODES })] }),
    )

    expect(meter.fraction).toBe(1)
  })
})

describe('voteMeter', () => {
  it('should name the committee size before any vote is cast', () => {
    const meter = voteMeter(props())

    expect(meter.startedAt).toBeNull()
    expect(meter.detail).toContain('委員会 8人')
  })

  it('should count votes cast against the committee size', () => {
    const votes = [3, 3, 3].map((_, index) =>
      publication({ kind: 'attestation', id: index, delivered: NODES }),
    )
    const meter = voteMeter(props({ publications: votes }))

    expect(meter.detail).toContain('3/8人')
    expect(meter.fraction).toBe(1)
  })

  it('should average propagation across the votes cast', () => {
    const votes = [
      publication({ kind: 'attestation', id: 0, delivered: NODES }),
      publication({ kind: 'attestation', id: 1, delivered: 0 }),
    ]
    const meter = voteMeter(props({ publications: votes }))

    expect(meter.fraction).toBeCloseTo(0.5, 6)
  })

  it('should start at the first vote, not at the slot boundary', () => {
    const meter = voteMeter(
      props({
        publications: [
          publication({ kind: 'attestation', time: SLOT_START + ATTESTATION_OFFSET, delivered: 1 }),
        ],
      }),
    )

    expect(meter.startedAt).toBe(SLOT_START + ATTESTATION_OFFSET)
  })

  it('should ignore blocks when measuring votes', () => {
    const meter = voteMeter(
      props({ publications: [publication({ kind: 'block', delivered: NODES })] }),
    )

    expect(meter.startedAt).toBeNull()
  })
})
