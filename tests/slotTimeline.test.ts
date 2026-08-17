import { describe, expect, it } from 'vitest'
import {
  blockLabel,
  fractionAt,
  propagationCurve,
  voteLabel,
} from '../src/ui/views/SlotTimelineView'
import type { SlotTimelineProps } from '../src/ui/views/SlotTimelineView'
import type { Publication } from '../src/core/simulation'
import { paletteFor } from '../src/ui/theme'

const SLOT = 3
const SLOT_START = 36_000
const SLOT_DURATION = 12_000
const ATTESTATION_OFFSET = 4_000
const NODES = 64

/** Deciles at `start`, then one every `spacing` ms up to `steps` tenths. */
function milestones(start: number, spacing: number, steps: number): (number | null)[] {
  return Array.from({ length: 11 }, (_, index) =>
    index <= steps ? start + index * spacing : null,
  )
}

function publication(
  overrides: Partial<Publication> & Pick<Publication, 'kind'>,
): Publication {
  return {
    id: 0,
    time: SLOT_START,
    slot: SLOT,
    from: 7,
    layer: 'gasper',
    audience: NODES,
    delivered: 0,
    milestones: milestones(SLOT_START, 10, 10),
    nextMilestone: 11,
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

describe('fractionAt', () => {
  it('should report nothing delivered before the first milestone', () => {
    const p = publication({ kind: 'block', milestones: milestones(SLOT_START + 500, 10, 10) })
    expect(fractionAt(p, SLOT_START)).toBe(0)
  })

  it('should report the share reached at a given instant', () => {
    const p = publication({ kind: 'block', milestones: milestones(SLOT_START, 10, 10) })

    expect(fractionAt(p, SLOT_START + 50)).toBeCloseTo(0.5, 6)
    expect(fractionAt(p, SLOT_START + 100)).toBe(1)
  })

  /** A partition is exactly this: the deciles stop part way and never resume. */
  it('should plateau where the milestones stop', () => {
    const p = publication({ kind: 'block', milestones: milestones(SLOT_START, 10, 5) })

    expect(fractionAt(p, SLOT_START + 10_000)).toBeCloseTo(0.5, 6)
  })
})

describe('propagationCurve', () => {
  it('should produce nothing when the message has not been sent', () => {
    expect(propagationCurve([], SLOT_START, SLOT_DURATION, SLOT_START + 5_000)).toEqual([])
  })

  it('should climb from zero to fully delivered', () => {
    const curve = propagationCurve(
      [publication({ kind: 'block' })],
      SLOT_START,
      SLOT_DURATION,
      SLOT_START + 5_000,
    )

    expect(curve[0]?.fraction).toBe(0)
    expect(curve[curve.length - 1]?.fraction).toBe(1)
  })

  it('should never decrease along the slot', () => {
    const curve = propagationCurve(
      [publication({ kind: 'block' })],
      SLOT_START,
      SLOT_DURATION,
      SLOT_START + 5_000,
    )

    for (let i = 1; i < curve.length; i++) {
      expect(curve[i]?.fraction).toBeGreaterThanOrEqual(curve[i - 1]?.fraction ?? 0)
    }
  })

  it('should average across several broadcasts', () => {
    const curve = propagationCurve(
      [
        publication({ kind: 'attestation', id: 0, milestones: milestones(SLOT_START, 10, 10) }),
        publication({ kind: 'attestation', id: 1, milestones: milestones(SLOT_START, 10, 0) }),
      ],
      SLOT_START,
      SLOT_DURATION,
      SLOT_START + 5_000,
    )

    expect(curve[curve.length - 1]?.fraction).toBeCloseTo(0.5, 6)
  })

  it('should stop at the present rather than running to the slot end', () => {
    const curve = propagationCurve(
      [publication({ kind: 'block' })],
      SLOT_START,
      SLOT_DURATION,
      SLOT_START + 40,
    )

    expect(curve[curve.length - 1]?.offset).toBeCloseTo(40, 6)
  })
})

describe('labels', () => {
  it('should say a proposal is awaited before the voting deadline', () => {
    expect(blockLabel(props())).toContain('提案待ち')
  })

  it('should say a proposal is missing once the deadline has passed', () => {
    expect(blockLabel(props({ nowMs: SLOT_START + ATTESTATION_OFFSET + 1 }))).toContain('提案なし')
  })

  it('should report delivered against the node count', () => {
    const label = blockLabel(
      props({ publications: [publication({ kind: 'block', delivered: 32 })] }),
    )

    expect(label).toContain('32/64')
  })

  it('should name the committee size before any vote is cast', () => {
    expect(voteLabel(props())).toContain('委員会 8人')
  })

  it('should report votes cast against the committee size', () => {
    const votes = [0, 1, 2].map((id) =>
      publication({ kind: 'attestation', id, delivered: NODES }),
    )

    expect(voteLabel(props({ publications: votes }))).toContain('3/8人')
  })

  it('should ignore blocks when reporting votes', () => {
    const label = voteLabel(
      props({ publications: [publication({ kind: 'block', delivered: NODES })] }),
    )

    expect(label).toContain('投票待ち')
  })
})
