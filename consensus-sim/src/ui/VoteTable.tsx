/**
 * Vote table with two granularities. The default (LMD) shows one resolved
 * row per validator — the vote fork choice actually counts. `all` lists
 * every vote in the given set, so equivocating double votes and past slots'
 * votes stay individually observable in a cell expansion.
 */

import { latestVotes, validatorName } from '../domain'
import type { Vote } from '../domain'
import { blockName } from './format'
import { validatorColor } from './validatorColor'

export function VoteTable({
  votes,
  all = false,
}: {
  readonly votes: readonly Vote[]
  readonly all?: boolean
}) {
  const rows = all
    ? [...votes].sort(
        (a, b) => a.slot - b.slot || a.validator - b.validator || a.head - b.head,
      )
    : [...latestVotes(votes).entries()]
        .sort((a, b) => a[0] - b[0])
        .map(([, vote]) => vote)
  if (rows.length === 0) {
    return <p className="panel-empty">まだ投票はありません。</p>
  }
  return (
    <table className="vote-table">
      <thead>
        <tr>
          <th>バリデータ</th>
          <th>スロット</th>
          <th>head 支持</th>
          <th>source → target</th>
        </tr>
      </thead>
      <tbody>
        {rows.map((vote, i) => (
          <tr key={all ? i : vote.validator}>
            <td>
              <span
                className="validator-dot"
                style={{ background: validatorColor(vote.validator) }}
              />
              {validatorName(vote.validator)}
            </td>
            <td>{vote.slot}</td>
            <td>{blockName(vote.head)}</td>
            <td>
              {blockName(vote.source)} → {blockName(vote.target)}
            </td>
          </tr>
        ))}
      </tbody>
    </table>
  )
}
