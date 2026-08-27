/**
 * Every parameter that shapes a run, in one column.
 *
 * Changing any of these rebuilds the simulation from slot 0. That is
 * intentional: comparing "N=64 for the first ten slots, then N=128" against
 * anything is meaningless, so a parameter edit starts a new experiment rather
 * than mutating a running one. Playback speed and the observed node sit outside
 * this panel precisely because they do not affect the run.
 */

import { SelectField, SliderField, ToggleField } from './Field'
import type { Settings } from '../settings'
import type { DelayDistribution } from '../../core/network'

const DISTRIBUTIONS: readonly { value: DelayDistribution; label: string }[] = [
  { value: 'uniform', label: '一様' },
  { value: 'normal', label: '正規' },
  { value: 'pareto', label: 'パレート（裾が重い）' },
]

interface Props {
  readonly settings: Settings
  readonly onChange: (settings: Settings) => void
}

export function ControlPanel({ settings, onChange }: Props) {
  const update = <K extends keyof Settings>(key: K, value: Settings[K]) =>
    onChange({ ...settings, [key]: value })

  return (
    <div className="control-panel">
      <section>
        <h2>バリデータ集合</h2>
        <SliderField
          label="バリデータ数 N"
          value={settings.validatorCount}
          min={8}
          max={512}
          step={8}
          onChange={(value) => update('validatorCount', value)}
          hint="個体シミュレーション。1ノード = 1バリデータ = 独立ビュー"
        />
        <SliderField
          label="非参加率"
          value={settings.offlineRatio}
          min={0}
          max={0.7}
          step={0.05}
          format={(value) => `${Math.round(value * 100)}%`}
          onChange={(value) => update('offlineRatio', value)}
          hint="提案も投票もしないバリデータ。ビザンチン戦略は M2"
        />
        <SliderField
          label="シード"
          value={settings.seed}
          min={1}
          max={64}
          step={1}
          onChange={(value) => update('seed', value)}
          hint="同じシードなら実行はビット単位で再現する"
        />
      </section>

      <section>
        <h2>Gasper</h2>
        <SliderField
          label="スロット長"
          value={settings.slotDurationMs}
          min={1_000}
          max={12_000}
          step={500}
          format={(value) => `${value / 1000}s`}
          onChange={(value) => update('slotDurationMs', value)}
        />
        <SliderField
          label="エポック長"
          value={settings.slotsPerEpoch}
          min={4}
          max={32}
          step={4}
          format={(value) => `${value} slots`}
          onChange={(value) => update('slotsPerEpoch', value)}
          hint="mainnet は 32。短くするとファイナリティが早く観察できる"
        />
        <SliderField
          label="proposer boost"
          value={settings.proposerBoostPercent}
          min={0}
          max={100}
          step={5}
          format={(value) => `${value}%`}
          onChange={(value) => update('proposerBoostPercent', value)}
          hint="0 にすると ex-ante reorg 耐性が消える。Goldfish の view-merge と対比する軸"
        />
      </section>

      <section>
        <h2>ネットワーク</h2>
        <SliderField
          label="基本遅延"
          value={settings.baseDelayMs}
          min={10}
          max={4_000}
          step={10}
          format={(value) => `${value}ms`}
          onChange={(value) => update('baseDelayMs', value)}
        />
        <SliderField
          label="ジッタ"
          value={settings.jitterMs}
          min={0}
          max={2_000}
          step={10}
          format={(value) => `${value}ms`}
          onChange={(value) => update('jitterMs', value)}
        />
        <SelectField
          label="遅延分布"
          value={settings.distribution}
          options={DISTRIBUTIONS}
          onChange={(value) => update('distribution', value)}
        />
      </section>

      <section>
        <h2>分断</h2>
        <ToggleField
          label="分断を有効にする"
          checked={settings.partitionEnabled}
          onChange={(value) => update('partitionEnabled', value)}
        />
        {settings.partitionEnabled && (
          <>
            <SliderField
              label="開始スロット"
              value={settings.partitionStartSlot}
              min={0}
              max={64}
              step={1}
              onChange={(value) => update('partitionStartSlot', value)}
            />
            <SliderField
              label="終了スロット"
              value={settings.partitionEndSlot}
              min={1}
              max={128}
              step={1}
              onChange={(value) => update('partitionEndSlot', value)}
            />
            <SliderField
              label="グループ数"
              value={settings.partitionGroups}
              min={2}
              max={4}
              step={1}
              onChange={(value) => update('partitionGroups', value)}
              hint="グループ間のメッセージは分断終了まで保留される（消失しない）"
            />
          </>
        )}
      </section>
    </div>
  )
}
