/**
 * State table (状態表): rows are validators, columns are slots, horizontally
 * aligned with the block tree's slot columns above it (shared treeGeometry).
 * Each cell shows one dynamically selected item of that validator's local
 * observation at the end of that slot, cells that differ from the other
 * validators are highlighted, and clicking a cell expands it into the full
 * local observation (handled by the parent via onToggleCell).
 */

import { latestVotes, validatorName } from '../domain'
import type { LocalObservation, ValidatorIndex } from '../domain'
import { COL_W, LABEL_W, TABLE_OFFSET } from './treeGeometry'
import { validatorColor } from './validatorColor'

export type StateCellItem =
  | 'head'
  | 'justified'
  | 'finalized'
  | 'latestVote'
  | 'blockCount'
  | 'voteCount'

export const STATE_CELL_ITEMS: readonly {
  readonly key: StateCellItem
  readonly label: string
}[] = [
  { key: 'head', label: 'head' },
  { key: 'justified', label: 'justified' },
  { key: 'finalized', label: 'finalized' },
  { key: 'latestVote', label: '最新投票' },
  { key: 'blockCount', label: 'ブロック数' },
  { key: 'voteCount', label: '投票数' },
]

export interface ExpandedCell {
  readonly validator: ValidatorIndex
  readonly slot: number
}

export interface StateTableProps {
  /** observations[slot][validator] — local observation at the end of slot. */
  readonly observations: readonly (readonly LocalObservation[])[]
  readonly validatorCount: number
  readonly item: StateCellItem
  readonly expanded: ExpandedCell | undefined
  onToggleCell(cell: ExpandedCell): void
}

function blockName(index: number): string {
  return `B${index}`
}

export function cellValue(
  obs: LocalObservation,
  validator: ValidatorIndex,
  item: StateCellItem,
): string {
  switch (item) {
    case 'head':
      return blockName(obs.head)
    case 'justified':
      return blockName(obs.finality.justifiedHead)
    case 'finalized':
      return blockName(obs.finality.finalized)
    case 'latestVote': {
      const vote = latestVotes(obs.view.votes).get(validator)
      return vote ? blockName(vote.head) : '－'
    }
    case 'blockCount':
      return String(obs.view.blockTree.blocks.size)
    case 'voteCount':
      return String(obs.view.votes.length)
  }
}

/**
 * Which cells of one column to highlight: the ones differing from the
 * column's plurality value. When no single value wins the plurality (e.g. a
 * 2-2 partition), the disagreement is mutual and every cell is highlighted.
 */
export function diffFlags(values: readonly string[]): readonly boolean[] {
  const counts = new Map<string, number>()
  for (const v of values) counts.set(v, (counts.get(v) ?? 0) + 1)
  if (counts.size <= 1) return values.map(() => false)
  const max = Math.max(...counts.values())
  const winners = [...counts.entries()].filter(([, n]) => n === max)
  if (winners.length > 1) return values.map(() => true)
  const winner = winners[0]?.[0]
  return values.map((v) => v !== winner)
}

export function StateTable({
  observations,
  validatorCount,
  item,
  expanded,
  onToggleCell,
}: StateTableProps) {
  const slotCount = observations.length
  const columns = Array.from({ length: slotCount }, (_, s) => {
    const values = Array.from({ length: validatorCount }, (_, v) => {
      const obs = observations[s]?.[v]
      return obs ? cellValue(obs, v, item) : ''
    })
    return { values, diffs: diffFlags(values) }
  })

  return (
    <table
      className="state-table"
      style={{ marginLeft: TABLE_OFFSET, width: LABEL_W + slotCount * COL_W }}
      aria-label="状態表"
    >
      <colgroup>
        <col style={{ width: LABEL_W }} />
        {Array.from({ length: slotCount }, (_, s) => (
          <col key={s} style={{ width: COL_W }} />
        ))}
      </colgroup>
      <thead>
        <tr>
          <th scope="col">バリデータ</th>
          {Array.from({ length: slotCount }, (_, s) => (
            <th key={s} scope="col">
              {s}
            </th>
          ))}
        </tr>
      </thead>
      <tbody>
        {Array.from({ length: validatorCount }, (_, v) => (
          <tr key={v}>
            <th scope="row">
              <span
                className="validator-dot"
                style={{ background: validatorColor(v) }}
              />
              {validatorName(v)}
            </th>
            {columns.map((column, s) => {
              const isExpanded =
                expanded?.validator === v && expanded.slot === s
              return (
                <td key={s}>
                  <button
                    type="button"
                    className={[
                      'state-cell',
                      column.diffs[v] ? 'state-cell-diff' : '',
                      isExpanded ? 'expanded' : '',
                    ]
                      .filter(Boolean)
                      .join(' ')}
                    aria-label={`${validatorName(v)} スロット ${s} の詳細`}
                    aria-pressed={isExpanded}
                    onClick={() => onToggleCell({ validator: v, slot: s })}
                  >
                    {column.values[v]}
                  </button>
                </td>
              )
            })}
          </tr>
        ))}
      </tbody>
    </table>
  )
}
