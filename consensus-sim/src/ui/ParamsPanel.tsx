/**
 * Protocol parameter panel (プロトコルパラメータ): the scenario's initial
 * conditions set from the UI — a preset (phase0 / merge / current) that
 * switches every value at once, each protocol parameter individually, the
 * seed, and every validator's initial stake. A change rewrites the
 * scenario's config; the displayed history recomputes deterministically
 * from the anchor with the interventions kept, so the effect of a knob is
 * read directly off the same run.
 */

import { useEffect, useState } from 'react'
import {
  DEFAULT_STAKE,
  PRESETS,
  PRESET_NAMES,
  equalStakes,
  presetOf,
  validatorName,
} from '../domain'
import type {
  CheckpointSwitch,
  ForkChoiceRule,
  PresetName,
  ProtocolParams,
  InitialConditions,
} from '../domain'
import { Button } from './components/Button'
import { Disclosure } from './components/Disclosure'
import { NumberField as NumberFieldControl } from './components/NumberField'
import { Segmented } from './components/Segmented'
import type { SimulationSession } from './useSimulation'
import { validatorColor } from './validatorColor'

const PRESET_NOTES: Readonly<Record<PresetName, string>> = {
  phase0: 'Beacon chain genesis（2020-12）',
  merge: 'The Merge（2022-09）',
  current: '2023 年の fork choice 修正以降',
}

const FORK_CHOICE_RULES: readonly ForkChoiceRule[] = ['GHOST', 'LMD-GHOST']
const CHECKPOINT_SWITCHES: readonly CheckpointSwitch[] = ['window', 'unrealized', 'off']

const ON_OFF = [
  { key: 'on', label: 'on' },
  { key: 'off', label: 'off' },
] as const

function OnOff({
  label,
  value,
  onChange,
}: {
  readonly label: string
  readonly value: boolean
  onChange(value: boolean): void
}) {
  return (
    <Segmented
      label={label}
      value={value ? 'on' : 'off'}
      options={ON_OFF}
      onChange={(v) => onChange(v === 'on')}
    />
  )
}

interface NumberFieldProps {
  readonly label: string
  readonly value: number
  readonly min?: number
  readonly max?: number
  readonly step?: number
  readonly integer?: boolean
  readonly className?: string
  onCommit(value: number): void
}

/**
 * A number input that commits every valid value as it is typed and keeps
 * the raw text while it is invalid (empty, out of range), so a field can be
 * cleared and retyped without snapping back.
 */
function NumberField({
  label,
  value,
  min,
  max,
  step,
  integer = false,
  className = 'slot-input',
  onCommit,
}: NumberFieldProps) {
  const parse = (t: string): number | undefined => {
    if (t.trim() === '') return undefined
    const n = Number(t)
    if (!Number.isFinite(n)) return undefined
    if (integer && !Number.isInteger(n)) return undefined
    if (min !== undefined && n < min) return undefined
    if (max !== undefined && n > max) return undefined
    return n
  }
  const [text, setText] = useState(String(value))
  // Follow an external change of the value (preset switch, scenario reload)
  // unless the text already parses to it.
  useEffect(() => {
    setText((t) => (parse(t) === value ? t : String(value)))
  }, [value])
  return (
    <NumberFieldControl
      className={className}
      aria-label={label}
      min={min}
      max={max}
      step={step}
      value={text}
      onChange={(e) => {
        setText(e.target.value)
        const n = parse(e.target.value)
        if (n !== undefined && n !== value) onCommit(n)
      }}
    />
  )
}

export interface ParamsPanelProps {
  readonly session: SimulationSession
}

export function ParamsPanel({ session }: ParamsPanelProps) {
  const { config } = session
  const { params } = config
  const validators = Array.from({ length: config.validatorCount }, (_, v) => v)
  const preset = presetOf(params)

  const setConfig = (patch: Partial<InitialConditions>) =>
    session.setConfig({ ...config, ...patch })
  const setParams = (patch: Partial<ProtocolParams>) =>
    setConfig({ params: { ...params, ...patch } })
  const setLeak = (patch: Partial<ProtocolParams['inactivityLeak']>) =>
    setParams({ inactivityLeak: { ...params.inactivityLeak, ...patch } })
  const setStake = (v: number, stake: number) =>
    setConfig({
      initialStakes: config.initialStakes.map((s, i) => (i === v ? stake : s)),
    })

  const committeeSize =
    params.committee.kind === 'sized'
      ? params.committee.size
      : Math.min(2, config.validatorCount)

  return (
    <section className="params-panel" aria-label="プロトコルパラメータ">
      <Disclosure
        summary={
          <h2 className="intervention-title">
            プロトコルパラメータ
            {`（${preset ?? 'カスタム'} / シード ${config.seed}）`}{' '}
            <span className="intervention-note">
              シナリオの初期条件。変更すると表示中の実行を最初から再計算（介入は維持）
            </span>
          </h2>
        }
      >
        <div className="intervention-forms">
          <fieldset className="intervention-group">
            <legend>プリセット</legend>
            <div className="form-line">
              <Segmented
                label="プロトコルプリセット"
                value={preset ?? ''}
                options={PRESET_NAMES.map((name) => ({ key: name, label: name }))}
                onChange={(name) => setParams(PRESETS[name as PresetName])}
              />
            </div>
            <span className="intervention-note">
              {preset
                ? PRESET_NOTES[preset]
                : 'カスタム: どのプリセットとも一致しません（プリセットを選ぶと全値を一括設定）'}
            </span>
          </fieldset>

          <fieldset className="intervention-group">
            <legend>committee と proposer boost</legend>
            <div className="form-line">
              <Segmented
                label="committee 割当"
                value={params.committee.kind}
                options={[
                  { key: 'all', label: '全員' },
                  { key: 'sized', label: 'サイズ c' },
                  { key: 'epoch-split', label: 'エポック分割' },
                ]}
                onChange={(kind) =>
                  setParams({
                    committee:
                      kind === 'sized' ? { kind: 'sized', size: committeeSize } : { kind },
                  })
                }
              />
              {params.committee.kind === 'sized' && (
                <label className="check-inline">
                  c =
                  <NumberField
                    label="committee サイズ c"
                    value={params.committee.size}
                    min={1}
                    max={config.validatorCount}
                    integer
                    onCommit={(size) => setParams({ committee: { kind: 'sized', size } })}
                  />
                </label>
              )}
            </div>
            <div className="form-line">
              <label className="check-inline">
                boost =
                <NumberField
                  label="proposer boost"
                  value={params.boost}
                  min={0}
                  max={1}
                  step={0.1}
                  onCommit={(boost) => setParams({ boost })}
                />
              </label>
              <span className="intervention-note">
                同スロット受信の提案に committee 総重み × boost
              </span>
            </div>
          </fieldset>

          <fieldset className="intervention-group">
            <legend>緩和策</legend>
            <div className="form-line">
              <span className="param-name">fork choice 規則</span>
              <Segmented
                label="fork choice 規則"
                value={params.forkChoice}
                options={FORK_CHOICE_RULES.map((r) => ({ key: r, label: r }))}
                onChange={(forkChoice) => setParams({ forkChoice })}
              />
            </div>
            <div className="form-line">
              <span className="param-name">エクイボケーション割引</span>
              <OnOff
                label="エクイボケーション割引"
                value={params.equivocationDiscount}
                onChange={(equivocationDiscount) => setParams({ equivocationDiscount })}
              />
            </div>
            <div className="form-line">
              <span className="param-name">justified 切替</span>
              <Segmented
                label="justified チェックポイント切替"
                value={params.checkpointSwitch}
                options={CHECKPOINT_SWITCHES.map((s) => ({ key: s, label: s }))}
                onChange={(checkpointSwitch) => setParams({ checkpointSwitch })}
              />
            </div>
          </fieldset>

          <fieldset className="intervention-group">
            <legend>罰則</legend>
            <div className="form-line">
              <span className="param-name">スラッシング</span>
              <OnOff
                label="スラッシング"
                value={params.slashing}
                onChange={(slashing) => setParams({ slashing })}
              />
            </div>
            <div className="form-line">
              <span className="param-name">inactivity leak</span>
              <OnOff
                label="inactivity leak"
                value={params.inactivityLeak.enabled}
                onChange={(enabled) => setLeak({ enabled })}
              />
              <label className="check-inline">
                N =
                <NumberField
                  label="inactivity leak N"
                  value={params.inactivityLeak.delayEpochs}
                  min={0}
                  integer
                  onCommit={(delayEpochs) => setLeak({ delayEpochs })}
                />
                エポック
              </label>
              <label className="check-inline">
                r =
                <NumberField
                  label="inactivity leak r"
                  value={params.inactivityLeak.rate}
                  min={0}
                  max={1}
                  step={0.05}
                  onCommit={(rate) => setLeak({ rate })}
                />
              </label>
            </div>
          </fieldset>

          <fieldset className="intervention-group">
            <legend>シードと初期ステーク</legend>
            <div className="form-line">
              <label className="check-inline">
                シード
                <NumberField
                  label="シード"
                  value={config.seed}
                  min={0}
                  integer
                  onCommit={(seed) => setConfig({ seed })}
                />
              </label>
              <span className="intervention-note">
                committee の抽出（サイズ c）と割当（エポック分割）に使用
              </span>
            </div>
            <div className="validator-checks">
              {validators.map((v) => (
                <label key={v} className="check-inline">
                  <span
                    className="validator-dot"
                    style={{ background: validatorColor(v) }}
                  />
                  {validatorName(v)}
                  <NumberField
                    label={`${validatorName(v)} の初期ステーク`}
                    value={config.initialStakes[v] ?? DEFAULT_STAKE}
                    min={1}
                    integer
                    onCommit={(stake) => setStake(v, stake)}
                  />
                </label>
              ))}
              <Button
                disabled={config.initialStakes.every((s) => s === DEFAULT_STAKE)}
                onClick={() => setConfig({ initialStakes: equalStakes(config.validatorCount) })}
              >
                全員等しく（{DEFAULT_STAKE}）
              </Button>
            </div>
          </fieldset>
        </div>
      </Disclosure>
    </section>
  )
}
