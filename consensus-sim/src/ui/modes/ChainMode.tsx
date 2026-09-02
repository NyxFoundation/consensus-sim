/**
 * Chain display (チェーン表示): the block tree with every validator's
 * information overlaid — per-validator heads, latest votes and J/F
 * checkpoint badges — and, below it, the state table (状態表) whose slot
 * columns line up with the tree's.
 *
 * Per-validator local observation lives in the state table: clicking a cell
 * expands that validator's view at that slot (computed with `observe`, a
 * pure filter over the message log — exactly what that validator knows,
 * nothing more).
 */

import { useMemo, useState } from 'react'
import {
  checkpointStatus,
  equalStakes,
  getBlock,
  instantDelivery,
  observe,
  validatorName,
} from '../../domain'
import type { Delivery, SimulationState } from '../../domain'
import { BlockTreeView } from '../BlockTreeView'
import { BlockBodyView, ChainStateTable } from '../ChainStateDetail'
import { blockName } from '../format'
import { StateTable, STATE_CELL_ITEMS } from '../StateTable'
import type { ExpandedCell, StateCellItem } from '../StateTable'
import { LABEL_W } from '../treeGeometry'
import { validatorColor } from '../validatorColor'
import { VoteTable } from '../VoteTable'

export interface ChainModeProps {
  readonly state: SimulationState
  readonly validatorCount: number
  /** The scenario's delivery rule — local views are filtered through it. */
  readonly delivery?: Delivery | undefined
}

export function ChainMode({
  state,
  validatorCount,
  delivery = instantDelivery,
}: ChainModeProps) {
  const [item, setItem] = useState<StateCellItem>('head')
  const [expanded, setExpanded] = useState<ExpandedCell | undefined>()

  // observations[slot][validator]: each validator's local observation at the
  // end of each slot up to the cursor. The log is append-only along a run and
  // viewOf filters by publishedAt, so the current log serves every past slot.
  const observations = useMemo(
    () =>
      Array.from({ length: state.slot + 1 }, (_, s) =>
        Array.from({ length: validatorCount }, (_, v) =>
          observe(state.log, v, s, validatorCount, delivery),
        ),
      ),
    [state.log, state.slot, validatorCount, delivery],
  )
  const stakes = useMemo(() => equalStakes(validatorCount), [validatorCount])
  const checkpoints = useMemo(
    () => checkpointStatus(state.tree, stakes),
    [state.tree, stakes],
  )

  const toggleCell = (cell: ExpandedCell) => {
    setExpanded((prev) =>
      prev?.validator === cell.validator && prev.slot === cell.slot
        ? undefined
        : cell,
    )
  }

  // A rewind or validator-count change can orphan the expanded cell.
  const detail = (() => {
    if (
      expanded === undefined ||
      expanded.slot > state.slot ||
      expanded.validator >= validatorCount
    ) {
      return undefined
    }
    const peers = observations[expanded.slot]!
    const obs = peers[expanded.validator]!
    // Validators whose head lies on another branch at this slot — the ones
    // whose chain state can legitimately disagree with this one.
    const otherBranch = peers
      .map((o, v) => ({ v, head: o.head }))
      .filter(({ v, head }) => v !== expanded.validator && head !== obs.head)
    return {
      ...expanded,
      obs,
      peerStates: peers.map((o) => o.chainState),
      headBlock: getBlock(obs.view.blockTree, obs.head)!,
      otherBranch,
    }
  })()

  return (
    <section className="chain-mode">
      <div className="tree-scroll chain-scroll">
        <div style={{ marginLeft: LABEL_W }}>
          <BlockTreeView
            tree={state.tree}
            votes={state.votes}
            heads={state.heads}
            checkpoints={checkpoints}
            throughSlot={state.slot}
          />
        </div>
        <div className="state-table-toolbar">
          <span className="state-table-caption">状態表の表示項目</span>
          <div className="segmented" role="group" aria-label="状態表の表示項目">
            {STATE_CELL_ITEMS.map(({ key, label }) => (
              <button
                type="button"
                key={key}
                className={item === key ? 'active' : ''}
                onClick={() => setItem(key)}
              >
                {label}
              </button>
            ))}
          </div>
        </div>
        <StateTable
          observations={observations}
          validatorCount={validatorCount}
          item={item}
          expanded={detail}
          onToggleCell={toggleCell}
        />
      </div>

      {detail && (
        <div className="panel state-detail">
          <h3>
            <span
              className="validator-dot"
              style={{ background: validatorColor(detail.validator) }}
            />
            {validatorName(detail.validator)} の視点 — スロット {detail.slot}
            <button
              type="button"
              className="detail-close"
              onClick={() => setExpanded(undefined)}
            >
              閉じる
            </button>
          </h3>
          <dl className="status-list">
            <dt>head</dt>
            <dd>
              {blockName(detail.obs.head)}
              {detail.otherBranch.length > 0 && (
                <span className="head-others">
                  {' '}
                  — 別の枝を head とするバリデータ:{' '}
                  {detail.otherBranch
                    .map(({ v, head }) => `${validatorName(v)} ${blockName(head)}`)
                    .join(' / ')}
                </span>
              )}
            </dd>
            <dt>justified</dt>
            <dd>{blockName(detail.obs.chainState.justified)}</dd>
            <dt>finalized</dt>
            <dd>{blockName(detail.obs.chainState.finalized)}</dd>
          </dl>
          <h4 className="pane-title">
            head {blockName(detail.obs.head)} のチェーン状態
            <span className="pane-note">
              他バリデータの head のチェーン状態と食い違う値を強調
            </span>
          </h4>
          <ChainStateTable
            validator={detail.validator}
            peers={detail.peerStates}
            validatorCount={validatorCount}
          />
          <h4 className="pane-title">
            head {blockName(detail.obs.head)} の body（取り込み）
          </h4>
          <BlockBodyView
            body={detail.headBlock.body}
            validatorCount={validatorCount}
          />
          <div className="tree-scroll">
            <BlockTreeView
              tree={detail.obs.view.blockTree}
              votes={detail.obs.view.votes}
              heads={new Map([[detail.validator, detail.obs.head]])}
              checkpoints={checkpointStatus(detail.obs.view.blockTree, stakes)}
              throughSlot={detail.slot}
            />
          </div>
          <h4 className="pane-title">
            このビューの投票（全 {detail.obs.view.votes.length} 件）
          </h4>
          <VoteTable votes={detail.obs.view.votes} all />
        </div>
      )}

      <div className="panel-row">
        <div className="panel">
          <h3>全バリデータの状態</h3>
          <dl className="status-list">
            <dt>各バリデータの head</dt>
            <dd>
              {[...state.heads.entries()]
                .sort((a, b) => a[0] - b[0])
                .map(([v, h]) => `${validatorName(v)}:${blockName(h)}`)
                .join(' / ')}
            </dd>
            <dt>justified</dt>
            <dd>
              {[...checkpoints.justified]
                .sort((a, b) => a - b)
                .map(blockName)
                .join(', ')}
            </dd>
            <dt>finalized</dt>
            <dd>
              {[...checkpoints.finalized]
                .sort((a, b) => a - b)
                .map(blockName)
                .join(', ')}
            </dd>
          </dl>
        </div>

        <div className="panel">
          <h3>最新投票（LMD）</h3>
          <VoteTable votes={state.votes} />
        </div>
      </div>
    </section>
  )
}
