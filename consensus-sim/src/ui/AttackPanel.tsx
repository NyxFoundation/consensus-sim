/**
 * Attack panel (攻撃): bind a library attack into the scenario. Choosing an
 * attack proposes its default run (既定実行構成) as the scenario's initial
 * conditions — validator count, initial stakes, seed, the premise's
 * protocol parameters, the attacker set, the attack parameters and the end
 * slot of the run — every one of which may then be changed: the attacker
 * set from the validators (the declared condition is shown, and an unmet
 * one is marked 条件未満 while the attack stays runnable), the parameters
 * (d and the strategy's own), the end slot, and the protocol parameters in
 * the parameter panel (a departure from the premise is read out, with a
 * way back). The strategy's actions appear in the intervention list, the
 * goal's verdicts in the trace above the state table.
 */

import {
  ATTACK_LIBRARY,
  attackerStakeRatio,
  findLibraryAttack,
  premiseParams,
  presetOf,
  sameParams,
  satisfiesCondition,
  validatorName,
} from '../domain'
import type { ValidatorIndex } from '../domain'
import { conditionLabel, percentLabel, premiseLabel, stageLabel } from './attackFormat'
import { CommitNumberField } from './CommitNumberField'
import { Button } from './components/Button'
import { Checkbox } from './components/Checkbox'
import { Disclosure } from './components/Disclosure'
import { Hint } from './components/Hint'
import { Select } from './components/Select'
import type { SimulationSession } from './useSimulation'
import { validatorColor } from './validatorColor'

export interface AttackPanelProps {
  readonly session: SimulationSession
}

export function AttackPanel({ session }: AttackPanelProps) {
  const { attack, config, generated, goal, cursor, throughSlot } = session
  const entry = attack === undefined ? undefined : findLibraryAttack(attack.id)
  const validators = Array.from({ length: config.validatorCount }, (_, v) => v)

  const satisfied =
    attack !== undefined && satisfiesCondition(attack.attack.attackers, attack.attackers, config)
  const discards = generated.filter((g) => g.discarded !== undefined).length
  const premiseMatches =
    entry !== undefined && sameParams(config.params, premiseParams(entry.premise))
  const verdicts = goal?.[cursor]

  const toggleAttacker = (v: ValidatorIndex) => {
    if (attack === undefined) return
    const attackers = attack.attackers.includes(v)
      ? attack.attackers.filter((x) => x !== v)
      : [...attack.attackers, v].sort((a, b) => a - b)
    if (attackers.length === 0) return
    session.setAttack({ ...attack, attackers })
  }

  return (
    <section className="attack-panel dock-section" aria-label="攻撃">
      <Disclosure
        summary={
          <h2 className="panel-title">
            攻撃
            {attack !== undefined && <span className="panel-count">{attack.id}</span>}
            {attack !== undefined && !satisfied && (
              <span className="panel-count panel-count-warning">条件未満</span>
            )}
            <Hint text="攻撃ライブラリの攻撃をシナリオに組み込む（高々 1 つ、手動介入と併用可）。選ぶと既定実行構成（バリデータ数・初期ステーク・シード・前提のプロトコルパラメータ・攻撃者集合・攻撃パラメータ・終了スロット）を初期条件として提案し、スロット 0 から始める。戦略が各スロット境界で生成した行動は攻撃者の印付きで介入一覧に、攻撃目標の判定は状態表の上の推移に現れる" />
          </h2>
        }
      >
        <div className="form-line">
          <Select
            aria-label="攻撃を選択"
            value={attack?.id ?? ''}
            onChange={(e) => {
              const chosen = findLibraryAttack(e.target.value)
              if (chosen) session.proposeAttack(chosen)
            }}
          >
            <option value="">攻撃を選択…</option>
            {ATTACK_LIBRARY.map((a) => (
              <option key={a.id} value={a.id}>
                {a.id} {a.name}
              </option>
            ))}
          </Select>
        </div>

        {attack !== undefined && entry !== undefined && (
          <div className="intervention-forms">
            <div className="form-line">
              <span className="readout attack-source">出典 {entry.source}</span>
            </div>

            <fieldset className="intervention-group">
              <legend>
                攻撃者集合
                <Hint text="攻撃者として振る舞うバリデータ。攻撃者集合の条件（人数の下限、または初期ステーク比率の下限）を満たさなくても実行でき、その間は条件未満の印が付く" />
              </legend>
              <div className="validator-checks">
                {validators.map((v) => {
                  const checked = attack.attackers.includes(v)
                  return (
                    <label key={v} className="check-inline">
                      <Checkbox
                        aria-label={`攻撃者 ${validatorName(v)}`}
                        checked={checked}
                        disabled={checked && attack.attackers.length === 1}
                        onChange={() => toggleAttacker(v)}
                      />
                      <span className="validator-dot" style={{ background: validatorColor(v) }} />
                      {validatorName(v)}
                    </label>
                  )
                })}
              </div>
              <span className="readout">
                条件 {conditionLabel(attack.attack.attackers)} ／ 現在 {attack.attackers.length} 名・比率{' '}
                {percentLabel(attackerStakeRatio(attack.attackers, config))}
              </span>
              {!satisfied && (
                <span className="form-status" role="status">
                  条件未満（宣言条件を満たさないまま実行）
                </span>
              )}
            </fieldset>

            <fieldset className="intervention-group">
              <legend>
                前提とパラメータ
                <Hint text="前提 = 攻撃が成立するプロトコルパラメータ（プリセット名+上書き）と遅延上限 d。プロトコルパラメータは操作盤のパラメータ区画で自由に変えられ、前提から外れると読み出しに表示（例: 上書きを外した merge で緩和策が効くかを観測）。d は正直メッセージを遅らせられる最大スロット数、終了スロットは自動再生を止める既定の位置" />
              </legend>
              <div className="form-line">
                <span className="readout">前提 {premiseLabel(entry.premise)}</span>
              </div>
              <div className="form-line">
                {premiseMatches ? (
                  <span className="readout">プロトコルパラメータは前提どおり</span>
                ) : (
                  <>
                    <span className="form-status" role="status">
                      前提と異なる（現在 {presetOf(config.params) ?? 'カスタム'}）
                    </span>
                    <Button
                      size="sm"
                      onClick={() =>
                        session.setConfig({ ...config, params: premiseParams(entry.premise) })
                      }
                    >
                      前提に戻す
                    </Button>
                  </>
                )}
              </div>
              <div className="form-line">
                {Object.entries(attack.params).map(([name, value]) => (
                  <label key={name} className="check-inline">
                    {name === 'maxDelay' ? 'd' : name} =
                    <CommitNumberField
                      label={`攻撃パラメータ ${name}`}
                      value={value}
                      min={0}
                      integer
                      onCommit={(n) =>
                        session.setAttack({ ...attack, params: { ...attack.params, [name]: n } })
                      }
                    />
                  </label>
                ))}
                <label className="check-inline">
                  終了スロット
                  <CommitNumberField
                    label="終了スロット"
                    value={throughSlot ?? entry.defaultRun.throughSlot}
                    min={1}
                    integer
                    onCommit={(n) => session.setThroughSlot(n)}
                  />
                </label>
              </div>
            </fieldset>

            <fieldset className="intervention-group">
              <legend>
                攻撃目標
                <Hint text="述語の列を先頭から順に判定し、末尾まで達成した時点で攻撃目標の達成。各段の判定と根拠は状態表の上の推移にスロットごとに表示" />
              </legend>
              <ol className="goal-stages">
                {attack.attack.goal.map((stage, i) => {
                  const verdict = verdicts?.[i]
                  const status =
                    verdict === undefined
                      ? ''
                      : verdict.status === 'achieved'
                        ? `達成 @s${verdict.achievedAt}`
                        : verdict.status === 'active'
                          ? '判定中'
                          : '待機'
                  return (
                    <li key={i}>
                      {stageLabel(stage)}
                      <span className="readout goal-stage-status">{status}</span>
                    </li>
                  )
                })}
              </ol>
              <span className="readout">
                生成行動 {generated.length} 件
                {discards > 0 && `（破棄 ${discards}）`}
              </span>
            </fieldset>

            <div className="form-line">
              <Button onClick={() => session.setAttack(undefined)}>攻撃を外す</Button>
            </div>
          </div>
        )}
      </Disclosure>
    </section>
  )
}
