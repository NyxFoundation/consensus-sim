/**
 * Numeric read-out for the observed node plus a few engine-level counters.
 *
 * Justified and finalized epochs come from the observed node, not from a global
 * view — during a partition two nodes legitimately disagree about what is
 * final, and showing a single "true" number would hide exactly that.
 */

import { shortHash } from '../core/hash'
import type { GasperSnapshot } from '../protocol/gasper/types'
import type { Divergence } from './divergence'

interface Props {
  readonly snapshot: GasperSnapshot
  readonly timeMs: number
  readonly slot: number
  readonly epoch: number
  readonly blockCount: number
  readonly pendingMessages: number
  readonly divergence: Divergence
  readonly observer: number
}

interface Cell {
  readonly label: string
  readonly value: string
  /** Rendered as an icon + word, never as a colour on its own. */
  readonly note?: string
}

export function StatsBar(props: Props) {
  const { camps, onChain } = props.divergence
  const forked = camps.length > 0
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
    // Distinct head hashes would count a node that is merely one block behind
    // as a disagreement; only branches that contain neither the other count.
    {
      label: '分岐',
      value: forked ? `${camps.length + 1}派` : 'なし',
      ...(forked
        ? { note: `⚠ ${[onChain, ...camps.map((camp) => camp.count)].join(' / ')}` }
        : {}),
    },
  ]

  return (
    <div className="stats-bar">
      {cells.map((cell) => (
        <div className={cell.note === undefined ? 'stat' : 'stat stat-warn'} key={cell.label}>
          <span className="stat-label">{cell.label}</span>
          <span className="stat-value">{cell.value}</span>
          {cell.note !== undefined && <span className="stat-note">{cell.note}</span>}
        </div>
      ))}
    </div>
  )
}
