/**
 * Chain mode (チェーンモード): the block tree, switchable between one
 * validator's local view (局所視点) and the god view (神視点) that overlays
 * every validator's information on the full published tree.
 *
 * Local view is computed with `observe` — a pure filter over the message
 * log — so what this mode shows for validator v is exactly what v knows,
 * nothing more.
 */

import { observe, latestVotes, instantDelivery, validatorName } from '../../domain'
import type {
  Delivery,
  SimulationState,
  ValidatorIndex,
  Vote,
} from '../../domain'
import { BlockTreeView } from '../BlockTreeView'
import { validatorColor } from '../validatorColor'

export type Perspective = 'local' | 'god'

export interface ChainModeProps {
  readonly state: SimulationState
  readonly validatorCount: number
  /** The scenario's delivery rule — local views are filtered through it. */
  readonly delivery?: Delivery
  readonly perspective: Perspective
  readonly selectedValidator: ValidatorIndex
  onPerspectiveChange(perspective: Perspective): void
  onSelectValidator(validator: ValidatorIndex): void
}

function blockName(index: number): string {
  return `B${index}`
}

function VoteTable({ votes }: { readonly votes: readonly Vote[] }) {
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

export function ChainMode({
  state,
  validatorCount,
  delivery = instantDelivery,
  perspective,
  selectedValidator,
  onPerspectiveChange,
  onSelectValidator,
}: ChainModeProps) {
  const local =
    perspective === 'local'
      ? observe(state.log, selectedValidator, state.slot, validatorCount, delivery)
      : undefined

  const tree = local ? local.view.blockTree : state.tree
  const votes = local ? local.view.votes : state.votes
  const finality = local ? local.finality : state.finality
  const heads = local
    ? new Map([[selectedValidator, local.head]])
    : state.heads

  return (
    <section className="chain-mode">
      <div className="mode-toolbar">
        <div className="segmented" role="group" aria-label="視点">
          <button
            type="button"
            className={perspective === 'local' ? 'active' : ''}
            onClick={() => onPerspectiveChange('local')}
          >
            局所視点
          </button>
          <button
            type="button"
            className={perspective === 'god' ? 'active' : ''}
            onClick={() => onPerspectiveChange('god')}
          >
            神視点
          </button>
        </div>

        {perspective === 'local' && (
          <div className="segmented" role="group" aria-label="バリデータ選択">
            {Array.from({ length: validatorCount }, (_, v) => (
              <button
                type="button"
                key={v}
                className={selectedValidator === v ? 'active' : ''}
                onClick={() => onSelectValidator(v)}
              >
                <span
                  className="validator-dot"
                  style={{ background: validatorColor(v) }}
                />
                {validatorName(v)}
              </button>
            ))}
          </div>
        )}
      </div>

      <div className="tree-scroll">
        <BlockTreeView
          tree={tree}
          votes={votes}
          heads={heads}
          finality={finality}
          throughSlot={state.slot}
        />
      </div>

      <div className="panel-row">
        <div className="panel">
          <h3>
            {perspective === 'local'
              ? `${validatorName(selectedValidator)} の局所状態`
              : '神視点の状態'}
          </h3>
          <dl className="status-list">
            {perspective === 'local' && (
              <>
                <dt>head</dt>
                <dd>{blockName(local ? local.head : 0)}</dd>
              </>
            )}
            {perspective === 'god' && (
              <>
                <dt>各バリデータの head</dt>
                <dd>
                  {[...heads.entries()]
                    .sort((a, b) => a[0] - b[0])
                    .map(([v, h]) => `${validatorName(v)}:${blockName(h)}`)
                    .join(' / ')}
                </dd>
              </>
            )}
            <dt>justified</dt>
            <dd>
              {[...finality.justified].sort((a, b) => a - b).map(blockName).join(', ')}
              （先頭 {blockName(finality.justifiedHead)}）
            </dd>
            <dt>finalized</dt>
            <dd>{blockName(finality.finalized)}</dd>
          </dl>
        </div>

        <div className="panel">
          <h3>最新投票（LMD）</h3>
          <VoteTable votes={votes} />
        </div>
      </div>
    </section>
  )
}
