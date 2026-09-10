/**
 * Application shell — the instrument's frame. One header bar (page tabs,
 * validator count, theme) above the page. The chain display page is a stage
 * on the left and the operation dock (操作盤) on the right: the stage
 * carries the slot bar (cursor, rewind, advance) and the chain display, the
 * dock gathers every other control — the attack, protocol parameters,
 * interventions, scenarios — in a fixed narrow column, so the protagonists (the chain
 * display and the state table) own most of the viewport from the first
 * paint (tokens.css --bar-h / --dock-w). The attack list page (必須 22) and
 * the type catalog page (必須 8) have their own layout: only the header bar
 * frames them — no slot bar, no dock, no validator count. Choosing an
 * attack on the list proposes its default run and returns to the chain
 * display, whose slot bar carries the auto-play control (必須 31). On the
 * chain display the slot bar's operations — cursor, play / pause, advance —
 * also answer keyboard shortcuts (任意; the scenario panel binds its own
 * save key), listed in the slot bar's ⓘ. All model computation stays
 * behind useSimulation / src/domain.
 */

import { useState } from 'react'
import {
  MAX_VALIDATOR_COUNT,
  MIN_VALIDATOR_COUNT,
  proposerForSlot,
  validatorName,
} from '../domain'
import { Button } from './components/Button'
import { Hint } from './components/Hint'
import { Segmented } from './components/Segmented'
import { Select } from './components/Select'
import { AttacksPage } from './modes/AttacksPage'
import { ChainMode } from './modes/ChainMode'
import { TypesPage } from './modes/TypesPage'
import { AttackPanel } from './AttackPanel'
import { InterventionPanel } from './InterventionPanel'
import { ParamsPanel } from './ParamsPanel'
import { PlayControl } from './PlayControl'
import { ScenarioPanel } from './ScenarioPanel'
import { SHORTCUT_HINT, useShortcuts } from './shortcuts'
import { useSimulation } from './useSimulation'
import { useThemeMode } from './useTheme'
import type { ThemeMode } from './useTheme'

type Page = 'chain' | 'attacks' | 'types'

const PAGE_LABELS: Readonly<Record<Page, string>> = {
  chain: 'チェーン表示',
  attacks: '攻撃一覧',
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
  const [page, setPage] = useState<Page>('chain')

  const { current, config, delivery, cursor, runSlot } = session
  const inPast = cursor < runSlot
  const nextProposer = proposerForSlot(cursor + 1, config)

  // The slot bar's operations from the keyboard, on the chain display only.
  useShortcuts(
    {
      ArrowLeft: () => {
        if (cursor > 0) session.setCursor(cursor - 1)
      },
      ArrowRight: () => {
        if (inPast) session.setCursor(cursor + 1)
      },
      Home: () => session.setCursor(0),
      End: () => session.setCursor(runSlot),
      ' ': () => (session.playing ? session.pause() : session.play()),
      n: () => session.advance(),
    },
    page === 'chain',
  )

  return (
    <div className="app">
      <header className="app-header">
        <div className="app-title">
          <h1>consensus-sim</h1>
          <span className="app-subtitle">最抽象モデル・シミュレータ</span>
        </div>

        <nav className="mode-tabs">
          <Segmented
            label="ページ切替"
            className="mode-tabs-segmented"
            value={page}
            options={(Object.keys(PAGE_LABELS) as Page[]).map((key) => ({
              key,
              label: PAGE_LABELS[key],
            }))}
            onChange={(p) => setPage(p)}
          />
        </nav>

        <div className="header-controls">
          {page === 'chain' && (
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
          )}
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

      {page === 'types' ? (
        <TypesPage />
      ) : page === 'attacks' ? (
        <AttacksPage
          onSelect={(entry) => {
            session.proposeAttack(entry)
            setPage('chain')
          }}
        />
      ) : (
        <div className="app-body">
          <div className="stage">
            <div className="slot-bar">
              <div className="slot-cursor" role="group" aria-label="スロット巻き戻し">
                <Button
                  className="cursor-step"
                  aria-label="1 スロット戻る"
                  aria-keyshortcuts="ArrowLeft"
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
                  aria-keyshortcuts="ArrowRight"
                  disabled={!inPast}
                  onClick={() => session.setCursor(cursor + 1)}
                >
                  ▶
                </Button>
                {inPast && (
                  <Button
                    className="cursor-latest"
                    aria-keyshortcuts="End"
                    onClick={() => session.setCursor(runSlot)}
                  >
                    最新へ
                  </Button>
                )}
                <Hint className="shortcut-hint" text={SHORTCUT_HINT} />
              </div>
              <span className="slot-next">
                次スロットの提案者: {validatorName(nextProposer)}
              </span>
              <PlayControl session={session} />
              <Button
                variant="primary"
                className="advance"
                aria-keyshortcuts="N"
                onClick={() => session.advance()}
              >
                {inPast ? 'ここから進める（以降の履歴を破棄）' : '＋1 スロット進める'}
              </Button>
            </div>

            <main className="mode-body">
              <ChainMode
                state={current}
                config={config}
                delivery={delivery}
                attackers={session.attack?.attackers}
                goalStages={session.attack?.attack.goal}
                goal={session.goal}
              />
            </main>
          </div>

          <aside className="dock" aria-label="操作盤">
            <AttackPanel session={session} />
            <ParamsPanel session={session} />
            <InterventionPanel key={config.validatorCount} session={session} />
            <ScenarioPanel session={session} />
          </aside>
        </div>
      )}
    </div>
  )
}
