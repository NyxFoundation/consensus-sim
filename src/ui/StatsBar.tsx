/**
 * Numeric read-out for the observed node plus a few engine-level counters.
 *
 * Justified and finalized epochs come from the observed node, not from a global
 * view — during a partition two nodes legitimately disagree about what is
 * final, and showing a single "true" number would hide exactly that.
 */

import { shortHash } from '../core/hash'
import type { GasperSnapshot } from '../protocol/gasper/types'

interface Props {
  readonly snapshot: GasperSnapshot
  readonly timeMs: number
  readonly slot: number
  readonly epoch: number
  readonly blockCount: number
  readonly pendingMessages: number
  readonly distinctHeads: number
  readonly observer: number
}

interface Cell {
  readonly label: string
  readonly value: string
  readonly warn?: boolean
}

export function StatsBar(props: Props) {
  const cells: readonly Cell[] = [
    { label: '時刻', value: `${(props.timeMs / 1000).toFixed(1)}s` },
    { label: 'スロット', value: String(props.slot) },
    { label: 'エポック', value: String(props.epoch) },
    { label: '観測ノード', value: `#${props.observer}` },
    { label: 'head', value: shortHash(props.snapshot.head) },
    { label: 'justified', value: `epoch ${props.snapshot.justified.epoch}` },
    { label: 'finalized', value: `epoch ${props.snapshot.finalized.epoch}` },
    { label: 'ブロック', value: String(props.blockCount) },
    { label: '配送中', value: String(props.pendingMessages) },
    { label: '異なる head', value: String(props.distinctHeads), warn: props.distinctHeads > 1 },
  ]

  return (
    <div className="stats-bar">
      {cells.map((cell) => (
        <div className={cell.warn === true ? 'stat stat-warn' : 'stat'} key={cell.label}>
          <span className="stat-label">{cell.label}</span>
          <span className="stat-value">{cell.value}</span>
        </div>
      ))}
    </div>
  )
}
