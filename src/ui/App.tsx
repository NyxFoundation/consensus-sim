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
import { StatsBar } from './StatsBar'
import { ForkTreeView } from './views/ForkTreeView'
import { ValidatorGridView } from './views/ValidatorGridView'
import { useSimulation } from './useSimulation'
import { DEFAULT_SETTINGS, toParams } from './settings'
import { epochOf } from './../protocol/gasper/types'

const SPEEDS: readonly number[] = [1, 5, 20, 50, 100, 200]

export function App() {
  const [settings, setSettings] = useState(DEFAULT_SETTINGS)
  const [observer, setObserver] = useState(0)
  const [visibleSlots, setVisibleSlots] = useState(24)

  const params = useMemo(() => toParams(settings), [settings])
  const { sim, running, speed, setRunning, setSpeed, stepSlot, reset } = useSimulation(params)

  const observerId = Math.min(observer, sim.nodes.length - 1)
  const snapshot = sim.snapshotOf(observerId)
  const heads = sim.nodes.map((node) => sim.viewOf(node.validator.nodeId)?.head ?? '')
  const roles = sim.nodes.map((node) => node.validator.role)
  const distinctHeads = new Set(heads).size

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

          <label className="toolbar-field">
            速度
            <select value={speed} onChange={(event) => setSpeed(Number(event.target.value))}>
              {SPEEDS.map((value) => (
                <option key={value} value={value}>
                  ×{value}
                </option>
              ))}
            </select>
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
              distinctHeads={distinctHeads}
              observer={observerId}
            />

            <section className="panel">
              <h2>
                フォーク木 <small>観測ノード #{observerId} のビュー</small>
              </h2>
              <ForkTreeView
                blocks={sim.blocks}
                snapshot={snapshot}
                currentSlot={sim.slot}
                slotsPerEpoch={settings.slotsPerEpoch}
                visibleSlots={visibleSlots}
              />
            </section>

            <section className="panel">
              <h2>
                バリデータ・ビューグリッド <small>各ノードが head と信じるブロックの色</small>
              </h2>
              <ValidatorGridView
                heads={heads}
                roles={roles}
                observer={observerId}
                onSelect={setObserver}
              />
            </section>
          </>
        )}
      </main>
    </div>
  )
}
