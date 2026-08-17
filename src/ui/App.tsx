/**
 * The shell: parameters on the left, and on the right a column that reads top
 * to bottom as numbers, then who agrees, then what is happening right now, then
 * the chain that resulted.
 *
 * They are not tabs on purpose. The value of the tool is watching one slider
 * move all of them together — split them across tabs and the causal link is
 * exactly what gets lost.
 */

import { useMemo, useState } from 'react'
import { ControlPanel } from './controls/ControlPanel'
import { Legend } from './Legend'
import type { LegendItem } from './Legend'
import { StatsBar } from './StatsBar'
import { ForkTreeView } from './views/ForkTreeView'
import { SlotTimelineView } from './views/SlotTimelineView'
import { useSimulation } from './useSimulation'
import { usePrefersReducedMotion, useThemeMode } from './useTheme'
import { computeDivergence } from './divergence'
import { useCampColors } from './campColors'
import { DEFAULT_SETTINGS, toParams } from './settings'
import { shortHash } from '../core/hash'
import { epochOf } from '../protocol/gasper/types'

/**
 * Capped at real time. Above it the slot goes by faster than the propagation
 * inside it can be followed, which is the speed at which the simulation stops
 * being something you can read.
 */
const SPEEDS: readonly number[] = [0.25, 0.5, 1]

export function App() {
  const [settings, setSettings] = useState(DEFAULT_SETTINGS)
  const [observer, setObserver] = useState(0)
  const [visibleSlots, setVisibleSlots] = useState(24)

  const params = useMemo(() => toParams(settings), [settings])
  const { sim, schedule, running, speed, slotPosition, setRunning, setSpeed, stepSlot, reset } =
    useSimulation(params)
  const { mode, palette, toggle } = useThemeMode()
  const reducedMotion = usePrefersReducedMotion()

  const observerId = Math.min(observer, sim.nodes.length - 1)
  const snapshot = sim.snapshotOf(observerId)
  const heads = sim.nodes.map((node) => sim.viewOf(node.validator.nodeId)?.head ?? '')

  const divergence = computeDivergence(sim.blocks, heads, snapshot?.head ?? '')
  const contested = useCampColors(sim, divergence.camps)

  const committeeSize = useMemo(() => schedule.committeeAt(sim.slot).length, [schedule, sim.slot])
  const proposer = schedule.proposerAt(sim.slot)
  const proposerActive = sim.nodes[proposer]?.validator.role !== 'offline'

  const treeLegend: readonly LegendItem[] = [
    { label: 'canonical', outline: true, color: palette.inkPrimary },
    { label: 'justified', outline: true, color: palette.statusWarning },
    { label: 'finalized', outline: true, color: palette.statusGood },
    { label: 'orphan', outline: true, color: palette.inkMuted },
    ...divergence.camps.map((camp) => ({
      label: `別の枝 ${shortHash(camp.head)}`,
      outline: true,
      color: palette.series[(contested.get(camp.head) ?? 4) - 1] ?? palette.otherSeries,
      count: camp.count,
    })),
  ]

  return (
    <div className="app">
      <aside className="sidebar">
        <header className="brand">
          <h1>consensus-sim</h1>
          <p>Gasper — LMD-GHOST + Casper FFG</p>
        </header>
        <ControlPanel settings={settings} onChange={setSettings} />
      </aside>

      <main className="main">
        <div className="toolbar">
          <button type="button" onClick={() => setRunning(!running)}>
            {running ? '一時停止' : '再生'}
          </button>
          <button type="button" onClick={stepSlot}>
            1スロット進める
          </button>
          <button type="button" onClick={reset}>
            リセット
          </button>

          <label className="toolbar-field toolbar-speed">
            速度 <span className="toolbar-value">×{speed}</span>
            <input
              type="range"
              min={0}
              max={SPEEDS.length - 1}
              step={1}
              value={Math.max(0, SPEEDS.indexOf(speed))}
              onChange={(event) => setSpeed(SPEEDS[Number(event.target.value)] ?? 1)}
            />
          </label>

          <label className="toolbar-field">
            観測ノード
            <input
              type="number"
              min={0}
              max={sim.nodes.length - 1}
              value={observerId}
              onChange={(event) => setObserver(Number(event.target.value))}
            />
          </label>

          <label className="toolbar-field">
            表示スロット数
            <input
              type="number"
              min={8}
              max={128}
              step={4}
              value={visibleSlots}
              onChange={(event) => setVisibleSlots(Number(event.target.value))}
            />
          </label>

          <button type="button" className="theme-toggle" onClick={toggle}>
            {mode === 'dark' ? '☀ ライト' : '☾ ダーク'}
          </button>
        </div>

        {snapshot === null ? (
          <div className="empty">シミュレーションを初期化中…</div>
        ) : (
          <>
            <StatsBar
              snapshot={snapshot}
              timeMs={sim.time}
              slot={sim.slot}
              epoch={epochOf(sim.slot, settings.slotsPerEpoch)}
              blockCount={sim.blocks.size}
              pendingMessages={sim.pendingMessages}
              divergence={divergence}
              observer={observerId}
            />

            <section className="panel panel-timeline">
              <h2>
                スロット内の伝播 <small>提案と投票がノードに届くまで</small>
              </h2>
              <SlotTimelineView
                slot={sim.slot}
                slotStartMs={sim.slot * settings.slotDurationMs}
                slotDurationMs={settings.slotDurationMs}
                attestationOffsetMs={Math.round(settings.slotDurationMs / 3)}
                nowMs={sim.time}
                proposer={proposer}
                proposerActive={proposerActive}
                committeeSize={committeeSize}
                publications={sim.publicationsInSlot(sim.slot)}
                nodeCount={sim.nodes.length}
                palette={palette}
              />
            </section>

            <section className="panel">
              <h2>
                フォーク木 <small>観測ノード #{observerId} のビュー</small>
              </h2>
              <ForkTreeView
                blocks={sim.blocks}
                snapshot={snapshot}
                currentSlot={reducedMotion ? Math.floor(slotPosition) : slotPosition}
                slotsPerEpoch={settings.slotsPerEpoch}
                visibleSlots={visibleSlots}
                palette={palette}
                contested={contested}
              />
              <Legend items={treeLegend} />
            </section>
          </>
        )}
      </main>
    </div>
  )
}
