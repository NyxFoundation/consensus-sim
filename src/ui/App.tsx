/**
 * The M1 shell: parameters on the left, fork tree and validator grid stacked on
 * the right, all four visible at once.
 *
 * They are not tabs on purpose. The value of the tool is watching one slider
 * move the tree, the grid and the numbers together — split them across tabs and
 * the causal link is exactly what gets lost.
 */

import { useMemo, useState } from 'react'
import { ControlPanel } from './controls/ControlPanel'
import { Legend } from './Legend'
import type { LegendItem } from './Legend'
import { StatsBar } from './StatsBar'
import { ForkTreeView } from './views/ForkTreeView'
import { ValidatorGridView } from './views/ValidatorGridView'
import { useSimulation } from './useSimulation'
import { usePrefersReducedMotion, useThemeMode } from './useTheme'
import { useHeadAssignment } from './headPalette'
import type { CellKind } from './headPalette'
import { DEFAULT_SETTINGS, toParams } from './settings'
import { shortHash } from '../core/hash'
import type { Hash } from '../core/hash'
import { epochOf } from '../protocol/gasper/types'

const SPEEDS: readonly number[] = [0.25, 0.5, 1, 2, 5, 10, 20, 50, 100, 200]

export function App() {
  const [settings, setSettings] = useState(DEFAULT_SETTINGS)
  const [observer, setObserver] = useState(0)
  const [visibleSlots, setVisibleSlots] = useState(24)

  const params = useMemo(() => toParams(settings), [settings])
  const { sim, running, speed, slotPosition, setRunning, setSpeed, stepSlot, reset } =
    useSimulation(params)
  const { mode, palette, toggle } = useThemeMode()
  const reducedMotion = usePrefersReducedMotion()

  const observerId = Math.min(observer, sim.nodes.length - 1)
  const snapshot = sim.snapshotOf(observerId)
  const heads = sim.nodes.map((node) => sim.viewOf(node.validator.nodeId)?.head ?? '')
  const offline = sim.nodes.map((node) => node.validator.role === 'offline')
  const offlineCount = offline.filter(Boolean).length

  const assignment = useHeadAssignment(sim, heads, snapshot?.head ?? '')
  const contested = useMemo(
    () => new Map<Hash, CellKind>(assignment.dissent.map((entry) => [entry.head, entry.kind])),
    [assignment.dissent],
  )

  const treeLegend: readonly LegendItem[] = [
    { label: 'canonical', outline: true, color: palette.inkPrimary },
    { label: 'justified', outline: true, color: palette.statusWarning },
    { label: 'finalized', outline: true, color: palette.statusGood },
    { label: 'orphan', outline: true, color: palette.inkMuted },
    ...assignment.dissent.map((entry) => ({
      label: `争点 ${shortHash(entry.head)}`,
      outline: true,
      color: palette.series[entry.kind - 1] ?? palette.otherSeries,
    })),
  ]

  const gridLegend: readonly LegendItem[] = [
    { label: '観測ノードと一致', color: palette.neutralCell, count: assignment.agreeCount },
    ...assignment.dissent.map((entry) => ({
      label: `head ${shortHash(entry.head)}`,
      color: palette.series[entry.kind - 1] ?? palette.otherSeries,
      count: entry.count,
    })),
    ...(assignment.otherCount > 0
      ? [{ label: 'その他', color: palette.otherSeries, count: assignment.otherCount }]
      : []),
    ...(offlineCount > 0 ? [{ label: '非参加', hatch: true, count: offlineCount }] : []),
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
              distinctHeads={new Set(heads).size}
              observer={observerId}
            />

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

            <section className="panel">
              <h2>
                バリデータ・ビューグリッド <small>観測ノードと head が一致するか</small>
              </h2>
              <ValidatorGridView
                kinds={assignment.kinds}
                offline={offline}
                observer={observerId}
                palette={palette}
                onSelect={setObserver}
              />
              <Legend items={gridLegend} />
            </section>
          </>
        )}
      </main>
    </div>
  )
}
