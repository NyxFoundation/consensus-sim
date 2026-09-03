/**
 * Network display (ネットワーク表示): every validator's state at a glance —
 * one card per validator with its operating state (稼働状態), head /
 * justified / finalized and latest vote — and, on mouse-over (or keyboard
 * focus), that validator's full local view rendered as its block tree below
 * the grid.
 *
 * Each card is computed with `observe` — the same pure filter the chain
 * display uses — so a card shows exactly what that validator knows. A card
 * whose head disagrees with the most common head is flagged (colour never
 * carries the signal alone; the flags are text labels).
 */

import { useState } from 'react'
import {
  checkpointStatus,
  instantDelivery,
  latestVotes,
  observe,
  operatingStateAt,
  validatorName,
} from '../../domain'
import type {
  Delivery,
  Intervention,
  LocalObservation,
  SimulationConfig,
  SimulationState,
  ValidatorIndex,
} from '../../domain'
import { BlockTreeView } from '../BlockTreeView'
import { Button } from '../components/Button'
import { blockName } from '../format'
import { validatorColor } from '../validatorColor'

export interface NetworkModeProps {
  readonly state: SimulationState
  /** The scenario's initial conditions — local views resolve under them. */
  readonly config: SimulationConfig
  /** The scenario's delivery rule — local views are filtered through it. */
  readonly delivery?: Delivery | undefined
  /** The scenario's interventions — the cards read the operating states. */
  readonly interventions?: readonly Intervention[] | undefined
}

const OP_STATE_FLAGS = { stopped: '停止中', offline: 'オフライン' } as const

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

export function NetworkMode({
  state,
  config,
  delivery = instantDelivery,
  interventions = [],
}: NetworkModeProps) {
  const { validatorCount } = config
  const [inspected, setInspected] = useState<ValidatorIndex | undefined>()

  const observations = Array.from({ length: validatorCount }, (_, v) =>
    observe(state.log, v, state.slot, config, delivery),
  )
  const commonHead = majorityHead(observations)

  const detail = inspected === undefined ? undefined : observations[inspected]

  return (
    <section className="network-mode">
      <div className="validator-grid" role="list" aria-label="バリデータ状態一覧">
        {observations.map((o, v) => {
          const myVote = latestVotes(o.view.votes).get(v)
          const diverged = commonHead !== undefined && o.head !== commonHead
          const opState = operatingStateAt(interventions, v, state.slot)
          return (
            <Button
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
                {validatorName(v)}
                {opState !== 'active' && (
                  <span className="card-flag card-flag-op">
                    {OP_STATE_FLAGS[opState]}
                  </span>
                )}
                {diverged && <span className="card-flag">分岐中</span>}
              </span>
              <dl className="status-list card-status">
                <dt>head</dt>
                <dd>{blockName(o.head)}</dd>
                <dt>justified</dt>
                <dd>{blockName(o.chainState.justified)}</dd>
                <dt>finalized</dt>
                <dd>{blockName(o.chainState.finalized)}</dd>
                <dt>最新投票</dt>
                <dd>
                  {myVote
                    ? `s${myVote.slot}: ${blockName(myVote.head)}（${blockName(
                        myVote.source,
                      )} → ${blockName(myVote.target)}）`
                    : 'なし'}
                </dd>
              </dl>
            </Button>
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
            {validatorName(inspected)} のビュー
          </h3>
          <div className="tree-scroll">
            <BlockTreeView
              tree={detail.view.blockTree}
              votes={detail.view.votes}
              heads={new Map([[inspected, detail.head]])}
              checkpoints={checkpointStatus(detail.view.blockTree, config)}
              throughSlot={state.slot}
            />
          </div>
        </div>
      )}
    </section>
  )
}
