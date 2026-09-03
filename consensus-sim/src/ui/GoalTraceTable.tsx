/**
 * Goal trace (攻撃目標の判定推移): one row per stage of the attack goal,
 * one column per slot — aligned with the block tree and the state table
 * above and below it (shared treeGeometry) — showing each stage's verdict
 * at every slot: the predicate's indicator (stalled slots, reorg count,
 * stake ratio, conflicting checkpoints), whether it holds, and the slot the
 * stage was achieved at. The full grounds of a verdict are the cell's
 * on-demand title.
 */

import type { AttackGoal, GoalTrace, StageVerdict } from '../domain'
import { evidenceDetail, evidenceReadout, stageLabel } from './attackFormat'
import { COL_W, LABEL_W, TABLE_OFFSET } from './treeGeometry'

export interface GoalTraceTableProps {
  readonly stages: readonly AttackGoal[]
  /** trace[slot][stage], through the displayed slot. */
  readonly trace: GoalTrace
}

function stageStatus(verdict: StageVerdict | undefined): string {
  if (verdict === undefined) return ''
  switch (verdict.status) {
    case 'pending':
      return '待機'
    case 'active':
      return '判定中'
    case 'achieved':
      return `達成 @s${verdict.achievedAt}`
  }
}

export function GoalTraceTable({ stages, trace }: GoalTraceTableProps) {
  const slotCount = trace.length
  const last = trace[slotCount - 1]
  return (
    <table
      className="goal-table"
      style={{ marginLeft: TABLE_OFFSET, width: LABEL_W + slotCount * COL_W }}
      aria-label="攻撃目標の判定推移"
    >
      <colgroup>
        <col style={{ width: LABEL_W }} />
        {Array.from({ length: slotCount }, (_, s) => (
          <col key={s} style={{ width: COL_W }} />
        ))}
      </colgroup>
      <tbody>
        {stages.map((stage, i) => (
          <tr key={i} className="goal-row">
            <th scope="row">
              第 {i + 1} 段 {stageLabel(stage)}
              <span className="goal-stage-status">{stageStatus(last?.[i])}</span>
            </th>
            {trace.map((verdicts, s) => {
              const verdict = verdicts[i]
              if (verdict === undefined) return <td key={s} />
              const achievedHere = verdict.achievedAt === s
              const classes = [
                'goal-cell',
                `goal-${verdict.status}`,
                verdict.evidence.holds ? 'goal-holds' : '',
                achievedHere ? 'goal-achieved-at' : '',
              ]
                .filter(Boolean)
                .join(' ')
              return (
                <td key={s} className={classes} title={evidenceDetail(verdict.evidence)}>
                  {achievedHere ? `達成 ${evidenceReadout(verdict.evidence)}` : evidenceReadout(verdict.evidence)}
                </td>
              )
            })}
          </tr>
        ))}
      </tbody>
    </table>
  )
}
