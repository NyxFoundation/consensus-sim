/**
 * The chain-state side of a cell expansion: what the validator's head
 * *carries* (取り込み層), as opposed to what the validator *sees* (View).
 *
 * `ChainStateTable` lists ChainState(head) — every validator's stake plus the
 * branch's justified / finalized checkpoint — and marks each entry that
 * disagrees with the chain states of the other validators' heads at the
 * same slot, so a diverging branch stands out even when the views look
 * alike. `BlockBodyView` lists the head block's body: the votes and the
 * equivocation evidence its proposer included.
 */

import { validatorName } from '../domain'
import type {
  BlockBody,
  ChainState,
  Equivocation,
  ValidatorIndex,
} from '../domain'
import { blockName, stakeLabel } from './format'
import { diffFlags } from './StateTable'
import { validatorColor } from './validatorColor'

export interface ChainStateTableProps {
  /** The expanded validator — whose head's chain state is shown. */
  readonly validator: ValidatorIndex
  /** ChainState(head) of every validator at the same slot, by index. */
  readonly peers: readonly ChainState[]
  readonly validatorCount: number
}

function DiffValue({
  value,
  diff,
}: {
  readonly value: string
  readonly diff: boolean
}) {
  return (
    <span className={diff ? 'value-diff' : undefined} data-diff={diff}>
      {value}
    </span>
  )
}

export function ChainStateTable({
  validator,
  peers,
  validatorCount,
}: ChainStateTableProps) {
  // Each entry is compared across the chain states of every validator's
  // head at this slot, with the state table's own difference rule.
  const column = (pick: (s: ChainState) => string) => {
    const values = peers.map(pick)
    return { value: values[validator] ?? '', diff: diffFlags(values)[validator] ?? false }
  }
  const justified = column((s) => blockName(s.justified))
  const finalized = column((s) => blockName(s.finalized))
  const stakes = Array.from({ length: validatorCount }, (_, v) =>
    column((s) => stakeLabel(s.stakes.get(v) ?? 0)),
  )

  return (
    <table className="chain-state-table" aria-label="head のチェーン状態">
      <thead>
        <tr>
          <th scope="col">justified</th>
          <th scope="col">finalized</th>
          {Array.from({ length: validatorCount }, (_, v) => (
            <th scope="col" key={v}>
              <span
                className="validator-dot"
                style={{ background: validatorColor(v) }}
              />
              {validatorName(v)}
            </th>
          ))}
        </tr>
      </thead>
      <tbody>
        <tr>
          <td>
            <DiffValue {...justified} />
          </td>
          <td>
            <DiffValue {...finalized} />
          </td>
          {stakes.map((stake, v) => (
            <td key={v}>
              <DiffValue {...stake} />
            </td>
          ))}
        </tr>
      </tbody>
    </table>
  )
}

/** One line of evidence: who, when, and the two conflicting messages. */
export function evidenceLabel(e: Equivocation): string {
  const who = `${validatorName(e.validator)} @${e.slot}`
  if (e.kind === 'double-proposal') {
    return `二重提案 ${who}: ${blockName(e.blocks[0])} / ${blockName(e.blocks[1])}`
  }
  const [a, b] = e.votes
  const vote = (v: typeof a) =>
    `${blockName(v.head)} (${blockName(v.source)} → ${blockName(v.target)})`
  return `二重投票 ${who}: ${vote(a)} / ${vote(b)}`
}

export function BlockBodyView({
  body,
  validatorCount,
}: {
  readonly body: BlockBody
  readonly validatorCount: number
}) {
  // Votes are summarized per validator as "head@slot" — the body is an
  // inclusion record, so the count and the supported blocks matter more
  // than the full FFG detail (already listed in the view's vote table).
  const byValidator = Array.from({ length: validatorCount }, (_, v) =>
    body.votes
      .filter((vote) => vote.validator === v)
      .map((vote) => `${blockName(vote.head)}@s${vote.slot}`),
  )
  return (
    <div className="block-body">
      <dl className="status-list">
        <dt>投票</dt>
        <dd>
          {body.votes.length === 0
            ? 'なし'
            : `${body.votes.length} 件 — ` +
              byValidator
                .map((heads, v) =>
                  heads.length === 0
                    ? undefined
                    : `${validatorName(v)} ${heads.join(' ')}`,
                )
                .filter(Boolean)
                .join(' / ')}
        </dd>
        <dt>証拠</dt>
        <dd>
          {body.evidence.length === 0 ? (
            'なし'
          ) : (
            <ul className="evidence-list">
              {body.evidence.map((e, i) => (
                <li key={i}>{evidenceLabel(e)}</li>
              ))}
            </ul>
          )}
        </dd>
      </dl>
    </div>
  )
}
