/**
 * Chain display (チェーン表示): the block tree with every validator's
 * information overlaid — per-validator heads, latest votes and J/F
 * checkpoint badges — in the upper part of the stage and, in its lower
 * part, the state table (状態表) whose slot columns line up with the
 * tree's. The two are the instrument's protagonists: together they fill the
 * stage from the first paint (styles.css .chain-mode / .chain-scroll); the
 * god-view readouts and the LMD vote table follow below them.
 *
 * Per-validator local observation lives in the state table: clicking a cell
 * expands that validator's view at that slot (computed with `observe`, a
 * pure filter over the message log — exactly what that validator knows,
 * nothing more).
 */

import { useMemo, useState } from 'react'
import {
  bodyOf,
  checkpointStatus,
  getBlock,
  instantDelivery,
  observe,
  validatorName,
} from '../../domain'
import type {
  AttackGoal,
  Delivery,
  GoalTrace,
  InitialConditions,
  SimulationState,
  ValidatorIndex,
} from '../../domain'
import { BlockTreeView } from '../BlockTreeView'
import { BlockBodyView, ChainStateTable } from '../ChainStateDetail'
import { Button } from '../components/Button'
import { Hint } from '../components/Hint'
import { Segmented } from '../components/Segmented'
import { blockName, checkpointName } from '../format'
import { GoalTraceTable } from '../GoalTraceTable'
import { StateTable, STATE_CELL_ITEMS } from '../StateTable'
import type { ExpandedCell, StateCellItem } from '../StateTable'
import { LABEL_W } from '../treeGeometry'
import { validatorColor } from '../validatorColor'
import { VoteTable } from '../VoteTable'

export interface ChainModeProps {
  readonly state: SimulationState
  /** The scenario's initial conditions — local views resolve under them. */
  readonly config: InitialConditions
  /** The scenario's delivery rule — local views are filtered through it. */
  readonly delivery?: Delivery | undefined
  /** The scenario's attackers, identified in the tree and the state table. */
  readonly attackers?: readonly ValidatorIndex[] | undefined
  /** The attack goal's stages and their verdicts through the displayed
   * slot (攻撃目標の判定推移), shown between the tree and the state table. */
  readonly goalStages?: readonly AttackGoal[] | undefined
  readonly goal?: GoalTrace | undefined
}

export function ChainMode({
  state,
  config,
  delivery = instantDelivery,
  attackers,
  goalStages,
  goal,
}: ChainModeProps) {
  const { validatorCount } = config
  const [item, setItem] = useState<StateCellItem>('head')
  const [expanded, setExpanded] = useState<ExpandedCell | undefined>()
  const attackerSet = useMemo(() => new Set(attackers ?? []), [attackers])
  // The trace through the displayed slot: the run may extend past the cursor.
  const trace = useMemo(
    () => (goal === undefined ? undefined : goal.slice(0, state.slot + 1)),
    [goal, state.slot],
  )

  // observations[slot][validator]: each validator's local observation at the
  // end of each slot up to the cursor. The log is append-only along a run and
  // viewOf filters by publishedAt, so the current log serves every past slot.
  const observations = useMemo(
    () =>
      Array.from({ length: state.slot + 1 }, (_, s) =>
        Array.from({ length: validatorCount }, (_, v) =>
          observe(state.log, v, s, config, delivery),
        ),
      ),
    [state.log, state.slot, validatorCount, config, delivery],
  )
  const checkpoints = useMemo(
    () => checkpointStatus(state.tree, config),
    [state.tree, config],
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
      {/* The protagonists: the tree region grows to fill the stage's upper
          part, the state table sits in the lower part, and both share one
          horizontal scroll so their slot columns stay aligned. */}
      <div className="chain-scroll">
        <div className="tree-region" style={{ paddingLeft: LABEL_W }}>
          <BlockTreeView
            tree={state.tree}
            votes={state.votes}
            heads={state.heads}
            checkpoints={checkpoints}
            throughSlot={state.slot}
            attackers={attackerSet}
          />
        </div>
        {goalStages !== undefined && trace !== undefined && (
          <GoalTraceTable stages={goalStages} trace={trace} />
        )}
        <div className="state-table-toolbar">
          <span className="state-table-caption">状態表の表示項目</span>
          <Segmented
            label="状態表の表示項目"
            size="sm"
            value={item}
            options={STATE_CELL_ITEMS}
            onChange={(i) => setItem(i)}
          />
          <Hint text="行 = バリデータ、列 = スロット（上のブロック木と横位置が揃う）。セルはそのスロット末のバリデータの観測で、他バリデータと食い違うセルを強調。セルを押すとそのバリデータの視点（ビュー・チェーン状態・body）を展開" />
        </div>
        <StateTable
          observations={observations}
          validatorCount={validatorCount}
          item={item}
          expanded={detail}
          attackers={attackerSet}
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
            <Button className="detail-close" onClick={() => setExpanded(undefined)}>
              閉じる
            </Button>
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
            <dd>{checkpointName(detail.obs.chainState.justified)}</dd>
            <dt>finalized</dt>
            <dd>{checkpointName(detail.obs.chainState.finalized)}</dd>
          </dl>
          <h4 className="pane-title">
            head {blockName(detail.obs.head)} のチェーン状態
            <Hint text="他バリデータの head のチェーン状態と食い違う値を強調" />
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
            body={bodyOf(detail.headBlock)}
            validatorCount={validatorCount}
          />
          <div className="tree-scroll">
            <BlockTreeView
              tree={detail.obs.view.blockTree}
              votes={detail.obs.view.votes}
              heads={new Map([[detail.validator, detail.obs.head]])}
              checkpoints={checkpointStatus(detail.obs.view.blockTree, config)}
              throughSlot={detail.slot}
              attackers={attackerSet}
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
