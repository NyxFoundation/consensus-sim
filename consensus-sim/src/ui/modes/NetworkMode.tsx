/**
 * Network mode (ネットワークモード): every validator's state at a glance —
 * one card per validator with head / justified / finalized / latest vote —
 * and, on mouse-over (or keyboard focus), that validator's full local view
 * rendered as its block tree below the grid.
 *
 * Each card is computed with `observe` — the same pure filter chain mode
 * uses — so a card shows exactly what that validator knows. A card whose
 * head disagrees with the most common head is flagged (colour never carries
 * the signal alone; the flag is a text label).
 */

import { useState } from 'react'
import { latestVotes, observe } from '../../domain'
import type {
  LocalObservation,
  SimulationState,
  ValidatorIndex,
} from '../../domain'
import { BlockTreeView } from '../BlockTreeView'
import { validatorColor } from '../validatorColor'

export interface NetworkModeProps {
  readonly state: SimulationState
  readonly validatorCount: number
}

function blockName(index: number): string {
  return `B${index}`
}

function majorityHead(
  observations: readonly LocalObservation[],
): number | undefined {
  const tally = new Map<number, number>()
  for (const o of observations) {
    tally.set(o.head, (tally.get(o.head) ?? 0) + 1)
  }
  let best: number | undefined
  let bestCount = 0
  for (const [head, count] of [...tally.entries()].sort((a, b) => a[0] - b[0])) {
    if (count > bestCount) {
      best = head
      bestCount = count
    }
  }
  return best
}

export function NetworkMode({ state, validatorCount }: NetworkModeProps) {
  const [inspected, setInspected] = useState<ValidatorIndex | undefined>()

  const observations = Array.from({ length: validatorCount }, (_, v) =>
    observe(state.log, v, state.slot, validatorCount),
  )
  const commonHead = majorityHead(observations)

  const detail = inspected === undefined ? undefined : observations[inspected]

  return (
    <section className="network-mode">
      <div className="validator-grid" role="list" aria-label="バリデータ状態一覧">
        {observations.map((o, v) => {
          const myVote = latestVotes(o.view.votes).get(v)
          const diverged = commonHead !== undefined && o.head !== commonHead
          return (
            <button
              type="button"
              role="listitem"
              key={v}
              className={[
                'validator-card',
                inspected === v ? 'inspected' : '',
                diverged ? 'diverged' : '',
              ]
                .filter(Boolean)
                .join(' ')}
              onMouseEnter={() => setInspected(v)}
              onFocus={() => setInspected(v)}
            >
              <span className="card-title">
                <span
                  className="validator-dot"
                  style={{ background: validatorColor(v) }}
                />
                V{v}
                {diverged && <span className="card-flag">分岐中</span>}
              </span>
              <dl className="status-list card-status">
                <dt>head</dt>
                <dd>{blockName(o.head)}</dd>
                <dt>justified</dt>
                <dd>{blockName(o.finality.justifiedHead)}</dd>
                <dt>finalized</dt>
                <dd>{blockName(o.finality.finalized)}</dd>
                <dt>最新投票</dt>
                <dd>
                  {myVote
                    ? `s${myVote.slot}: ${blockName(myVote.head)}（${blockName(
                        myVote.source,
                      )} → ${blockName(myVote.target)}）`
                    : 'なし'}
                </dd>
              </dl>
            </button>
          )
        })}
      </div>

      {detail === undefined || inspected === undefined ? (
        <p className="network-hint">
          バリデータにマウスを載せると、そのバリデータのビュー（ブロック木）を
          ここに表示します。
        </p>
      ) : (
        <div className="panel network-detail">
          <h3>
            <span
              className="validator-dot"
              style={{ background: validatorColor(inspected) }}
            />
            V{inspected} のビュー
          </h3>
          <div className="tree-scroll">
            <BlockTreeView
              tree={detail.view.blockTree}
              votes={detail.view.votes}
              heads={new Map([[inspected, detail.head]])}
              finality={detail.finality}
              throughSlot={state.slot}
            />
          </div>
        </div>
      )}
    </section>
  )
}
