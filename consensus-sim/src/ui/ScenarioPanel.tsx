/**
 * Scenario panel (シナリオ): save the current run (config + interventions +
 * attack + how far it advanced) to localStorage under an optional name and
 * note (命名・メモ — what the experiment was meant to confirm), reload a
 * saved one, and edit an entry's name and note afterwards. Replay is
 * deterministic recomputation, so a reloaded scenario reproduces the
 * identical run. Storage I/O lives in scenarioStore; all structural
 * validation is the domain codec's. The save also answers the S key.
 */

import { useState } from 'react'
import { presetOf } from '../domain'
import { Button } from './components/Button'
import { Disclosure } from './components/Disclosure'
import { Hint } from './components/Hint'
import { TextArea, TextField } from './components/TextField'
import {
  listScenarios,
  loadStored,
  removeScenario,
  saveScenario,
  updateScenarioMeta,
  type ScenarioMeta,
  type StoredScenario,
} from './scenarioStore'
import { useShortcuts } from './shortcuts'
import type { SimulationSession } from './useSimulation'

export interface ScenarioPanelProps {
  readonly session: SimulationSession
}

/** The name and note as typed; blanks become absent labels on save. */
interface MetaDraft {
  readonly name: string
  readonly note: string
}

const EMPTY_DRAFT: MetaDraft = { name: '', note: '' }

const draftOf = (e: ScenarioMeta): MetaDraft => ({ name: e.name ?? '', note: e.note ?? '' })

/** The run's identity in one line: when, how many validators, preset,
 * interventions, attack, how far. */
function entrySummary(e: StoredScenario): string {
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
  const attack = e.data.attack === undefined ? '' : ` / 攻撃 ${e.data.attack.id}`
  return `${stamp} — ${e.data.config.validatorCount} 体${preset} / 介入 ${e.data.interventions.length} 件${attack} / スロット ${e.data.runSlot}`
}

interface MetaFieldsProps {
  readonly draft: MetaDraft
  onChange(draft: MetaDraft): void
}

/** Name and note entry — the save form and an entry's edit form alike. */
function MetaFields({ draft, onChange }: MetaFieldsProps) {
  return (
    <>
      <div className="form-line">
        <TextField
          className="scenario-name-field"
          aria-label="シナリオ名"
          placeholder="シナリオ名"
          value={draft.name}
          onChange={(e) => onChange({ ...draft, name: e.target.value })}
        />
      </div>
      <div className="form-line">
        <TextArea
          className="scenario-note-field"
          aria-label="メモ"
          placeholder="メモ — この実験で何を確かめたか"
          rows={2}
          value={draft.note}
          onChange={(e) => onChange({ ...draft, note: e.target.value })}
        />
      </div>
    </>
  )
}

export function ScenarioPanel({ session }: ScenarioPanelProps) {
  const [entries, setEntries] = useState<StoredScenario[]>(() => listScenarios())
  const [status, setStatus] = useState('')
  const [draft, setDraft] = useState<MetaDraft>(EMPTY_DRAFT)
  const [editing, setEditing] = useState<{ id: string; draft: MetaDraft } | undefined>()

  const currentScenario = {
    config: session.config,
    interventions: session.interventions,
    ...(session.attack === undefined ? {} : { attack: session.attack }),
  }

  const save = () => {
    const saved = saveScenario(currentScenario, session.runSlot, draft)
    setEntries(listScenarios())
    setDraft(EMPTY_DRAFT)
    setStatus(
      saved.name === undefined ? '現在のシナリオを保存しました' : `「${saved.name}」を保存しました`,
    )
  }

  useShortcuts({ s: save })

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

  const commitEdit = () => {
    if (editing === undefined) return
    updateScenarioMeta(editing.id, editing.draft)
    setEntries(listScenarios())
    setEditing(undefined)
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
            <Hint text="保存 = 初期条件（プロトコルパラメータ・シード・初期ステーク）+ 手動介入の列 + 高々 1 つの攻撃（攻撃 ID・攻撃者集合・パラメータ。生成行動は保存せず再実行で再生成）+ 進行スロットを、このブラウザの一覧に残す。名前とメモは任意で、この実験が何を確かめたかを残すためのもの。保存後も編集できる。再読込は決定的リプレイで同一の実行・同一の生成行動・同一の判定推移を再現。S キーでも保存できる" />
          </h2>
        }
      >
        <div className="scenario-save-form">
          <MetaFields draft={draft} onChange={setDraft} />
          <div className="form-line">
            <Button aria-keyshortcuts="S" onClick={save}>
              現在のシナリオを保存
            </Button>
          </div>
        </div>
        {status && (
          <span className="scenario-status" role="status">
            {status}
          </span>
        )}

        {entries.length > 0 ? (
          <ul className="intervention-list scenario-list">
            {entries.map((e) => (
              <li key={e.id} className="scenario-entry">
                {editing?.id === e.id ? (
                  <div className="scenario-edit" aria-label="名前とメモの編集">
                    <MetaFields
                      draft={editing.draft}
                      onChange={(next) => setEditing({ id: e.id, draft: next })}
                    />
                    <span className="list-actions">
                      <Button size="sm" onClick={commitEdit}>
                        保存
                      </Button>
                      <Button size="sm" onClick={() => setEditing(undefined)}>
                        取消
                      </Button>
                    </span>
                  </div>
                ) : (
                  <>
                    <span className="intervention-desc">
                      {e.name !== undefined && <strong className="scenario-name">{e.name}</strong>}
                      <span className="scenario-summary">{entrySummary(e)}</span>
                      {e.note !== undefined && (
                        <span className="scenario-note" data-quoted="">
                          {e.note}
                        </span>
                      )}
                    </span>
                    <span className="list-actions">
                      <Button size="sm" onClick={() => load(e)}>
                        読込・再実行
                      </Button>
                      <Button
                        size="sm"
                        aria-label={`${e.name ?? entrySummary(e)} の名前とメモを編集`}
                        onClick={() => setEditing({ id: e.id, draft: draftOf(e) })}
                      >
                        編集
                      </Button>
                      <Button size="sm" onClick={() => remove(e.id)}>
                        削除
                      </Button>
                    </span>
                  </>
                )}
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
