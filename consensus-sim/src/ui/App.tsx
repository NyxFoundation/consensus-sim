/**
 * Application shell: display tabs (チェーン / ネットワーク / 全体表示 /
 * 型一覧), the slot cursor with rewind and advance controls, the protocol
 * parameter, intervention and scenario panels, and the scenario's
 * validator count.
 * All model computation stays behind useSimulation / src/domain.
 */

import { useState } from 'react'
import {
  MAX_VALIDATOR_COUNT,
  MIN_VALIDATOR_COUNT,
  proposerForSlot,
  validatorName,
} from '../domain'
import { Button } from './components/Button'
import { Segmented } from './components/Segmented'
import { Select } from './components/Select'
import { ChainMode } from './modes/ChainMode'
import { GlobalMode } from './modes/GlobalMode'
import { NetworkMode } from './modes/NetworkMode'
import { TypesPage } from './modes/TypesPage'
import { InterventionPanel } from './InterventionPanel'
import { ParamsPanel } from './ParamsPanel'
import { ScenarioPanel } from './ScenarioPanel'
import { useSimulation } from './useSimulation'
import { useThemeMode } from './useTheme'
import type { ThemeMode } from './useTheme'

type Mode = 'chain' | 'network' | 'global' | 'types'

const MODE_LABELS: Readonly<Record<Mode, string>> = {
  chain: 'チェーン表示',
  network: 'ネットワーク表示',
  global: '全体表示',
  types: '型一覧',
}

const THEME_LABELS: Readonly<Record<ThemeMode, string>> = {
  system: '自動',
  light: 'ライト',
  dark: 'ダーク',
}

const THEME_OPTIONS = (Object.keys(THEME_LABELS) as ThemeMode[]).map((key) => ({
  key,
  label: THEME_LABELS[key],
}))

const VALIDATOR_COUNTS = Array.from(
  { length: MAX_VALIDATOR_COUNT - MIN_VALIDATOR_COUNT + 1 },
  (_, i) => MIN_VALIDATOR_COUNT + i,
)

export function App() {
  const session = useSimulation()
  const theme = useThemeMode()
  const [mode, setMode] = useState<Mode>('chain')

  const { current, config, delivery, cursor, runSlot } = session
  const inPast = cursor < runSlot
  const nextProposer = proposerForSlot(cursor + 1, config)

  return (
    <div className="app">
      <header className="app-header">
        <div className="app-title">
          <h1>consensus-sim</h1>
          <span className="app-subtitle">最抽象モデル・シミュレータ</span>
        </div>

        <nav className="mode-tabs">
          <Segmented
            label="表示切替"
            className="mode-tabs-segmented"
            value={mode}
            options={(Object.keys(MODE_LABELS) as Mode[]).map((key) => ({
              key,
              label: MODE_LABELS[key],
            }))}
            onChange={(m) => setMode(m)}
          />
        </nav>

        <div className="header-controls">
          <label className="field-inline">
            バリデータ数
            <Select
              value={config.validatorCount}
              onChange={(e) => session.setValidatorCount(Number(e.target.value))}
            >
              {VALIDATOR_COUNTS.map((n) => (
                <option key={n} value={n}>
                  {n} 体
                </option>
              ))}
            </Select>
          </label>
          <Segmented
            label="テーマ"
            className="theme-toggle"
            size="sm"
            value={theme.mode}
            options={THEME_OPTIONS}
            onChange={theme.setMode}
          />
        </div>
      </header>

      <div className="slot-bar">
        <div className="slot-cursor" role="group" aria-label="スロット巻き戻し">
          <Button
            className="cursor-step"
            aria-label="1 スロット戻る"
            disabled={cursor === 0}
            onClick={() => session.setCursor(cursor - 1)}
          >
            ◀
          </Button>
          <span className="slot-current">
            スロット <strong>{cursor}</strong>
            {inPast && <span className="slot-run"> / 最新 {runSlot}</span>}
          </span>
          <Button
            className="cursor-step"
            aria-label="1 スロット先へ"
            disabled={!inPast}
            onClick={() => session.setCursor(cursor + 1)}
          >
            ▶
          </Button>
          {inPast && (
            <Button className="cursor-latest" onClick={() => session.setCursor(runSlot)}>
              最新へ
            </Button>
          )}
        </div>
        <span className="slot-next">
          次スロットの提案者: {validatorName(nextProposer)}
        </span>
        <Button variant="primary" className="advance" onClick={() => session.advance()}>
          {inPast ? 'ここから進める（以降の履歴を破棄）' : '＋1 スロット進める'}
        </Button>
      </div>

      <ParamsPanel session={session} />
      <InterventionPanel key={config.validatorCount} session={session} />
      <ScenarioPanel session={session} />

      <main className="mode-body">
        {mode === 'chain' && (
          <ChainMode state={current} config={config} delivery={delivery} />
        )}
        {mode === 'network' && (
          <NetworkMode
            state={current}
            config={config}
            delivery={delivery}
            interventions={session.interventions}
          />
        )}
        {mode === 'global' && (
          <GlobalMode
            state={current}
            config={config}
            delivery={delivery}
            interventions={session.interventions}
          />
        )}
        {mode === 'types' && <TypesPage />}
      </main>
    </div>
  )
}
