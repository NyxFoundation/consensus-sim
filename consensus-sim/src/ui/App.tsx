/**
 * Application shell: mode tabs (チェーン / ネットワーク / 全体), the slot
 * cursor with its advance control, and the scenario's validator count.
 * All model computation stays behind useSimulation / src/domain.
 */

import { useState } from 'react'
import {
  MAX_VALIDATOR_COUNT,
  MIN_VALIDATOR_COUNT,
  proposerForSlot,
} from '../domain'
import type { ValidatorIndex } from '../domain'
import { ChainMode } from './modes/ChainMode'
import type { Perspective } from './modes/ChainMode'
import { GlobalMode } from './modes/GlobalMode'
import { NetworkMode } from './modes/NetworkMode'
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
  const [perspective, setPerspective] = useState<Perspective>('local')
  const [selectedValidator, setSelectedValidator] = useState<ValidatorIndex>(0)

  const { current, config } = session
  const nextProposer = proposerForSlot(current.slot + 1, config.validatorCount)

  const changeValidatorCount = (count: number) => {
    session.setValidatorCount(count)
    setSelectedValidator(0)
  }

  return (
    <div className="app">
      <header className="app-header">
        <div className="app-title">
          <h1>consensus-sim</h1>
          <span className="app-subtitle">最抽象モデル・シミュレータ</span>
        </div>

        <nav className="mode-tabs" aria-label="表示モード">
          {(Object.keys(MODE_LABELS) as Mode[]).map((m) => (
            <button
              type="button"
              key={m}
              className={mode === m ? 'active' : ''}
              onClick={() => setMode(m)}
            >
              {MODE_LABELS[m]}モード
            </button>
          ))}
        </nav>

        <div className="header-controls">
          <label className="field-inline">
            バリデータ数
            <select
              value={config.validatorCount}
              onChange={(e) => changeValidatorCount(Number(e.target.value))}
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
        <span className="slot-current">
          スロット <strong>{current.slot}</strong>
        </span>
        <span className="slot-next">
          次スロットの提案者: V{nextProposer}
        </span>
        <button type="button" className="advance" onClick={() => session.advance()}>
          ＋1 スロット進める
        </button>
      </div>

      <main className="mode-body">
        {mode === 'chain' && (
          <ChainMode
            state={current}
            validatorCount={config.validatorCount}
            perspective={perspective}
            selectedValidator={selectedValidator}
            onPerspectiveChange={setPerspective}
            onSelectValidator={setSelectedValidator}
          />
        )}
        {mode === 'network' && <NetworkMode />}
        {mode === 'global' && <GlobalMode />}
      </main>
    </div>
  )
}
