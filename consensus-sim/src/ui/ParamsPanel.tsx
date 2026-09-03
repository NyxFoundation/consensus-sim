/**
 * Protocol parameter panel (プロトコルパラメータ): the scenario's initial
 * conditions set from the UI — a preset (phase0 / merge / current) that
 * switches every value at once, each protocol parameter individually, the
 * seed, and every validator's initial stake. A change rewrites the
 * scenario's config; the displayed history recomputes deterministically
 * from the anchor with the interventions kept, so the effect of a knob is
 * read directly off the same run.
 */

import {
  DEFAULT_INACTIVITY_LEAK,
  DEFAULT_STAKE,
  PRESETS,
  PRESET_NAMES,
  equalStakes,
  presetOf,
  validatorName,
} from '../domain'
import type {
  ForkChoiceRule,
  LeakSchedule,
  PresetName,
  ProtocolParams,
  InitialConditions,
} from '../domain'
import { CommitNumberField as NumberField } from './CommitNumberField'
import { Button } from './components/Button'
import { Disclosure } from './components/Disclosure'
import { Hint } from './components/Hint'
import { Segmented } from './components/Segmented'
import type { SimulationSession } from './useSimulation'
import { validatorColor } from './validatorColor'

const PRESET_NOTES: Readonly<Record<PresetName, string>> = {
  phase0: 'Beacon chain genesis（2020-12）',
  merge: 'The Merge（2022-09）',
  current: '2023 年の fork choice 修正以降',
}

const PRESET_HINT = `Ethereum の実在時点に対応する値の束。${PRESET_NAMES.map(
  (name) => `${name} = ${PRESET_NOTES[name]}`,
).join('／')}。選ぶと全値を一括設定し、どの束とも一致しない組合せはカスタムと表示`

const FORK_CHOICE_RULES: readonly ForkChoiceRule[] = ['GHOST', 'LMD-GHOST']

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
  const setSwitch = (patch: Partial<ProtocolParams['checkpointSwitch']>) =>
    setParams({ checkpointSwitch: { ...params.checkpointSwitch, ...patch } })
  const leak: LeakSchedule | undefined =
    params.inactivityLeak === 'off' ? undefined : params.inactivityLeak
  const setLeak = (patch: Partial<LeakSchedule>) =>
    setParams({ inactivityLeak: { ...(leak ?? DEFAULT_INACTIVITY_LEAK), ...patch } })
  const setStake = (v: number, stake: number) =>
    setConfig({
      initialStakes: config.initialStakes.map((s, i) => (i === v ? stake : s)),
    })

  const committeeSize =
    params.committee.kind === 'sized'
      ? params.committee.size
      : Math.min(2, config.validatorCount)

  return (
    <section className="params-panel dock-section" aria-label="プロトコルパラメータ">
      <Disclosure
        summary={
          <h2 className="panel-title">
            プロトコルパラメータ
            <span className="panel-count">
              {preset ?? 'カスタム'} / シード {config.seed}
            </span>
            <Hint text="シナリオの初期条件。変更すると表示中の実行を錨から再計算（介入は維持）するので、1 つのつまみの効果を同じ実行で読み取れる" />
          </h2>
        }
      >
        <div className="intervention-forms">
          <fieldset className="intervention-group">
            <legend>
              プリセット
              <Hint text={PRESET_HINT} />
            </legend>
            <div className="form-line">
              <Segmented
                label="プロトコルプリセット"
                value={preset ?? ''}
                options={PRESET_NAMES.map((name) => ({ key: name, label: name }))}
                onChange={(name) => setParams(PRESETS[name as PresetName])}
              />
            </div>
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
              <Hint text="スロット s の提案を (s, 投票) までに受信したバリデータの、スロット s の fork choice でのみ、その提案に committee 総重み × boost の追加重みが付く（遅れて届いた提案には付かない）" />
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
              <label className="check-inline">
                切替窓
                <OnOff
                  label="justified 切替窓"
                  value={params.checkpointSwitch.window}
                  onChange={(window) => setSwitch({ window })}
                />
              </label>
              <label className="check-inline">
                unrealized
                <OnOff
                  label="unrealized justification"
                  value={params.checkpointSwitch.unrealized}
                  onChange={(unrealized) => setSwitch({ unrealized })}
                />
              </label>
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
                value={leak !== undefined}
                onChange={(on) =>
                  setParams({ inactivityLeak: on ? DEFAULT_INACTIVITY_LEAK : 'off' })
                }
              />
              {leak !== undefined && (
                <>
                  <label className="check-inline">
                    N =
                    <NumberField
                      label="inactivity leak N"
                      value={leak.delayEpochs}
                      min={1}
                      integer
                      onCommit={(delayEpochs) => setLeak({ delayEpochs })}
                    />
                    エポック
                  </label>
                  <label className="check-inline">
                    r =
                    <NumberField
                      label="inactivity leak r"
                      value={leak.rate}
                      min={0}
                      max={1}
                      step={0.05}
                      onCommit={(rate) => setLeak({ rate })}
                    />
                  </label>
                </>
              )}
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
              <Hint text="committee の抽出（サイズ c）と割当（エポック分割）をこのシードから決定的に導く。全員では効かない" />
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
                size="sm"
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
