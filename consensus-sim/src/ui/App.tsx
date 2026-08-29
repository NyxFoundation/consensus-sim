/**
 * Application shell: display tabs (チェーン / ネットワーク / 全体表示), the
 * slot cursor with rewind and advance controls, the intervention panel, and
 * the scenario's validator count.
 * All model computation stays behind useSimulation / src/domain.
 */

import { useState } from 'react'
import {
  MAX_VALIDATOR_COUNT,
  MIN_VALIDATOR_COUNT,
  proposerForSlot,
  validatorName,
} from '../domain'
import { ChainMode } from './modes/ChainMode'
import { GlobalMode } from './modes/GlobalMode'
import { NetworkMode } from './modes/NetworkMode'
import { InterventionPanel } from './InterventionPanel'
import { ScenarioPanel } from './ScenarioPanel'
import { useSimulation } from './useSimulation'
import { useThemeMode } from './useTheme'

type Mode = 'chain' | 'network' | 'global'

const MODE_LABELS: Readonly<Record<Mode, string>> = {
  chain: 'チェーン',
  network: 'ネットワーク',
  global: '全体',
}

const VALIDATOR_COUNTS = Array.from(
  { length: MAX_VALIDATOR_COUNT - MIN_VALIDATOR_COUNT + 1 },
  (_, i) => MIN_VALIDATOR_COUNT + i,
)

export function App() {
  const session = useSimulation()
  const { mode: themeMode, toggle: toggleTheme } = useThemeMode()
  const [mode, setMode] = useState<Mode>('chain')

  const { current, config, delivery, cursor, runSlot } = session
  const inPast = cursor < runSlot
  const nextProposer = proposerForSlot(cursor + 1, config.validatorCount)

  return (
    <div className="app">
      <header className="app-header">
        <div className="app-title">
          <h1>consensus-sim</h1>
          <span className="app-subtitle">最抽象モデル・シミュレータ</span>
        </div>

        <nav className="mode-tabs" aria-label="表示切替">
          {(Object.keys(MODE_LABELS) as Mode[]).map((m) => (
            <button
              type="button"
              key={m}
              className={mode === m ? 'active' : ''}
              onClick={() => setMode(m)}
            >
              {MODE_LABELS[m]}表示
            </button>
          ))}
        </nav>

        <div className="header-controls">
          <label className="field-inline">
            バリデータ数
            <select
              value={config.validatorCount}
              onChange={(e) => session.setValidatorCount(Number(e.target.value))}
            >
              {VALIDATOR_COUNTS.map((n) => (
                <option key={n} value={n}>
                  {n} 体
                </option>
              ))}
            </select>
          </label>
          <button
            type="button"
            className="theme-toggle"
            onClick={toggleTheme}
            aria-label="テーマ切替"
          >
            {themeMode === 'dark' ? 'ライト表示' : 'ダーク表示'}
          </button>
        </div>
      </header>

      <div className="slot-bar">
        <div className="slot-cursor" role="group" aria-label="スロット巻き戻し">
          <button
            type="button"
            className="cursor-step"
            aria-label="1 スロット戻る"
            disabled={cursor === 0}
            onClick={() => session.setCursor(cursor - 1)}
          >
            ◀
          </button>
          <span className="slot-current">
            スロット <strong>{cursor}</strong>
            {inPast && <span className="slot-run"> / 最新 {runSlot}</span>}
          </span>
          <button
            type="button"
            className="cursor-step"
            aria-label="1 スロット先へ"
            disabled={!inPast}
            onClick={() => session.setCursor(cursor + 1)}
          >
            ▶
          </button>
          {inPast && (
            <button
              type="button"
              className="cursor-latest"
              onClick={() => session.setCursor(runSlot)}
            >
              最新へ
            </button>
          )}
        </div>
        <span className="slot-next">
          次スロットの提案者: {validatorName(nextProposer)}
        </span>
        <button type="button" className="advance" onClick={() => session.advance()}>
          {inPast ? 'ここから進める（以降の履歴を破棄）' : '＋1 スロット進める'}
        </button>
      </div>

      <InterventionPanel key={config.validatorCount} session={session} />
      <ScenarioPanel session={session} />

      <main className="mode-body">
        {mode === 'chain' && (
          <ChainMode
            state={current}
            validatorCount={config.validatorCount}
            delivery={delivery}
          />
        )}
        {mode === 'network' && (
          <NetworkMode
            state={current}
            validatorCount={config.validatorCount}
            delivery={delivery}
          />
        )}
        {mode === 'global' && (
          <GlobalMode
            state={current}
            validatorCount={config.validatorCount}
            delivery={delivery}
          />
        )}
      </main>
    </div>
  )
}
