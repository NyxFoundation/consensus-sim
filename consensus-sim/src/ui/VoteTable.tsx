/**
 * Latest-vote table (LMD): one resolved row per validator with the head it
 * supports and its source → target checkpoint pair. Used under the chain
 * display and inside the state table's cell expansion.
 */

import { latestVotes, validatorName } from '../domain'
import type { Vote } from '../domain'
import { validatorColor } from './validatorColor'

function blockName(index: number): string {
  return `B${index}`
}

export function VoteTable({ votes }: { readonly votes: readonly Vote[] }) {
  const latest = [...latestVotes(votes).entries()].sort((a, b) => a[0] - b[0])
  if (latest.length === 0) {
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
        {latest.map(([validator, vote]) => (
          <tr key={validator}>
            <td>
              <span
                className="validator-dot"
                style={{ background: validatorColor(validator) }}
              />
              {validatorName(validator)}
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
