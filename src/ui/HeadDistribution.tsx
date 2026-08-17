/**
 * How the network's heads are distributed, as one stacked bar.
 *
 * This replaces a grid of one cell per validator. That grid could not be read,
 * for a reason worth recording: its positions carried no information. Cell
 * (row 3, column 5) meant "validator 37" only because 37 is where the wrap
 * landed — neither axis encoded anything, so it was a bag of squares rather
 * than a chart, and a wall of identical squares in arbitrary order says nothing.
 *
 * The question it was there to answer — is the network split, into how many
 * camps, how big — is one dimension of proportion, and a stacked bar answers it
 * exactly, in a fraction of the space, legibly at a glance.
 *
 * Per-node display earns its place again only when position means something:
 * grouped by camp, or laid out by partition group, so that *correlation*
 * becomes visible. Arbitrary order cannot show correlation even in principle.
 */

import { Legend } from './Legend'
import type { LegendItem } from './Legend'
import { shortHash } from '../core/hash'
import type { HeadAssignment } from './headPalette'
import type { Palette } from './theme'

interface Props {
  readonly assignment: HeadAssignment
  readonly observerHead: string
  readonly palette: Palette
  readonly nodeCount: number
}

interface Segment {
  readonly key: string
  readonly label: string
  readonly color: string
  readonly count: number
}

function segmentsOf({ assignment, observerHead, palette }: Props): readonly Segment[] {
  return [
    {
      key: 'agree',
      label: `${shortHash(observerHead)}（観測ノードと同じ）`,
      color: palette.neutralCell,
      count: assignment.agreeCount,
    },
    ...assignment.dissent.map((entry) => ({
      key: entry.head,
      label: shortHash(entry.head),
      color: palette.series[entry.kind - 1] ?? palette.otherSeries,
      count: entry.count,
    })),
    ...(assignment.otherCount > 0
      ? [
          {
            key: 'other',
            label: 'その他',
            color: palette.otherSeries,
            count: assignment.otherCount,
          },
        ]
      : []),
  ]
}

export function HeadDistribution(props: Props) {
  const segments = segmentsOf(props).filter((segment) => segment.count > 0)
  const total = Math.max(1, props.nodeCount)

  const items: readonly LegendItem[] = segments.map((segment) => ({
    label: segment.label,
    color: segment.color,
    count: segment.count,
  }))

  return (
    <div className="distribution">
      <div
        className="distribution-bar"
        role="img"
        aria-label={segments.map((s) => `${s.label} ${s.count}`).join('、')}
      >
        {segments.map((segment) => (
          <span
            key={segment.key}
            style={{
              width: `${(segment.count / total) * 100}%`,
              backgroundColor: segment.color,
            }}
          />
        ))}
      </div>
      <Legend items={items} />
    </div>
  )
}
