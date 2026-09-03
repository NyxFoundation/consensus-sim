/**
 * Scenario panel (シナリオ): save the current run (config + interventions +
 * how far it advanced) to localStorage and reload a saved one — replay is
 * deterministic recomputation, so a reloaded scenario reproduces the
 * identical run. Storage I/O lives in scenarioStore; all structural
 * validation is the domain codec's.
 */

import { useState } from 'react'
import { presetOf } from '../domain'
import { Button } from './components/Button'
import { Disclosure } from './components/Disclosure'
import { Hint } from './components/Hint'
import {
  listScenarios,
  loadStored,
  removeScenario,
  saveScenario,
  type StoredScenario,
} from './scenarioStore'
import type { SimulationSession } from './useSimulation'

export interface ScenarioPanelProps {
  readonly session: SimulationSession
}

function entryLabel(e: StoredScenario): string {
  const at = new Date(e.savedAt)
  const stamp = Number.isNaN(at.getTime())
    ? e.savedAt
    : at.toLocaleString('ja-JP')
  let preset = ''
  try {
    preset = ` / ${presetOf(loadStored(e).scenario.config.params) ?? 'カスタム'}`
  } catch {
    // An entry the store could not parse is labelled without its preset.
  }
  return `${stamp} — ${e.data.config.validatorCount} 体${preset} / 介入 ${e.data.interventions.length} 件 / スロット ${e.data.runSlot}`
}

export function ScenarioPanel({ session }: ScenarioPanelProps) {
  const [entries, setEntries] = useState<StoredScenario[]>(() => listScenarios())
  const [status, setStatus] = useState('')

  const currentScenario = {
    config: session.config,
    interventions: session.interventions,
  }

  const save = () => {
    saveScenario(currentScenario, session.runSlot)
    setEntries(listScenarios())
    setStatus('現在のシナリオを保存しました')
  }

  const load = (entry: StoredScenario) => {
    try {
      const { scenario, runSlot } = loadStored(entry)
      session.loadScenario(scenario, runSlot)
      setStatus(`シナリオを再実行しました（スロット ${runSlot} まで再計算）`)
    } catch (e) {
      setStatus(`読込に失敗しました: ${e instanceof Error ? e.message : String(e)}`)
    }
  }

  const remove = (id: string) => {
    removeScenario(id)
    setEntries(listScenarios())
  }

  return (
    <section className="scenario-panel dock-section" aria-label="シナリオ">
      <Disclosure
        summary={
          <h2 className="panel-title">
            シナリオ
            {entries.length > 0 && (
              <span className="panel-count">保存 {entries.length} 件</span>
            )}
            <Hint text="保存 = 初期条件（プロトコルパラメータ・シード・初期ステーク）+ 介入列 + 進行スロットを、このブラウザの一覧に残す。再読込は決定的リプレイで同一の実行を再現" />
          </h2>
        }
      >
        <div className="form-line">
          <Button onClick={save}>現在のシナリオを保存</Button>
        </div>
        {status && (
          <span className="scenario-status" role="status">
            {status}
          </span>
        )}

        {entries.length > 0 ? (
          <ul className="intervention-list">
            {entries.map((e) => (
              <li key={e.id}>
                <span className="intervention-desc">{entryLabel(e)}</span>
                <span className="list-actions">
                  <Button size="sm" onClick={() => load(e)}>
                    読込・再実行
                  </Button>
                  <Button size="sm" onClick={() => remove(e.id)}>
                    削除
                  </Button>
                </span>
              </li>
            ))}
          </ul>
        ) : (
          <p className="empty-hint">保存されたシナリオはまだありません</p>
        )}
      </Disclosure>
    </section>
  )
}
