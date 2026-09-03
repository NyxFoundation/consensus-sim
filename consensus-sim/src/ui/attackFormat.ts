/**
 * Display forms of the attack formal system's values (攻撃の形式体系) —
 * shared by the attack panel, the goal trace and the attack list page so a
 * premise, a condition, a capability or a goal stage reads the same
 * everywhere. Pure string functions over domain values.
 */

import { validatorName } from '../domain'
import type {
  AttackGoal,
  AttackPremise,
  AttackerCondition,
  Capability,
  CommitteeAssignment,
  GoalEvidence,
  InactivityLeak,
  ProtocolParams,
} from '../domain'
import { blockName, checkpointName } from './format'

/** A ratio as the fraction the Essence writes (1/3, 1/2, 2/3) or a percentage. */
export function fractionLabel(x: number): string {
  const named: readonly [number, string][] = [
    [1 / 3, '1/3'],
    [1 / 2, '1/2'],
    [2 / 3, '2/3'],
  ]
  for (const [value, label] of named) {
    if (Math.abs(x - value) < 1e-9) return label
  }
  return `${Math.round(x * 100)}%`
}

export function percentLabel(x: number): string {
  return `${(x * 100).toFixed(x * 100 === Math.round(x * 100) ? 0 : 1)}%`
}

export function conditionLabel(condition: AttackerCondition): string {
  return condition.kind === 'count'
    ? `人数 ≥ ${condition.atLeast}`
    : `初期ステーク比率 ≥ ${fractionLabel(condition.atLeast)}`
}

const CAPABILITY_LABELS: Readonly<Record<Capability, string>> = {
  equivocation: 'エクイボケーション',
  'propose-parent': '提案 parent 指定',
  'vote-target': '投票先指定',
  silence: '沈黙',
  withhold: '自メッセージの保留・選択配送',
  'omit-inclusion': '取り込みの省略',
  'delay-honest': '正直メッセージの遅延',
  'drop-honest': '正直メッセージの欠落',
  partition: '分断',
}

export function capabilityLabel(capability: Capability): string {
  return CAPABILITY_LABELS[capability]
}

const onOff = (b: boolean) => (b ? 'on' : 'off')

function committeeLabel(committee: CommitteeAssignment): string {
  switch (committee.kind) {
    case 'all':
      return '全員'
    case 'sized':
      return `サイズ ${committee.size}`
    case 'epoch-split':
      return 'エポック分割'
  }
}

function leakLabel(leak: InactivityLeak): string {
  return leak === 'off' ? 'off' : `{N = ${leak.delayEpochs}, r = ${leak.rate}}`
}

/** One override of a premise as `name = value`. */
function overrideLabel(name: keyof ProtocolParams, params: Partial<ProtocolParams>): string {
  switch (name) {
    case 'committee':
      return `committee = ${committeeLabel(params.committee!)}`
    case 'boost':
      return `boost = ${params.boost}`
    case 'forkChoice':
      return `forkChoice = ${params.forkChoice}`
    case 'equivocationDiscount':
      return `割引 ${onOff(params.equivocationDiscount!)}`
    case 'checkpointSwitch':
      return `切替窓 ${onOff(params.checkpointSwitch!.window)}・unrealized ${onOff(
        params.checkpointSwitch!.unrealized,
      )}`
    case 'slashing':
      return `スラッシング ${onOff(params.slashing!)}`
    case 'inactivityLeak':
      return `leak ${leakLabel(params.inactivityLeak!)}`
  }
}

/** The premise as `preset + override, override / d = n`. */
export function premiseLabel(premise: AttackPremise): string {
  const overrides = Object.keys(premise.overrides ?? {}) as (keyof ProtocolParams)[]
  const params =
    overrides.length === 0
      ? premise.preset
      : `${premise.preset} + ${overrides
          .map((name) => overrideLabel(name, premise.overrides!))
          .join(', ')}`
  return `${params} / d = ${premise.maxDelay}`
}

/** A goal stage's predicate with its parameter (L, k, θ). */
export function stageLabel(goal: AttackGoal): string {
  switch (goal.kind) {
    case 'safety-violation':
      return '安全性違反'
    case 'liveness-stall':
      return `活性停止（L = ${goal.slots}）`
    case 'reorg':
      return `リオーグ（k = ${goal.count}）`
    case 'attacker-stake-ratio':
      return `攻撃者ステーク比率（θ = ${fractionLabel(goal.threshold)}）`
  }
}

/** The compact reading of a predicate's evidence in one slot cell. */
export function evidenceReadout(evidence: GoalEvidence): string {
  switch (evidence.kind) {
    case 'safety-violation':
      return evidence.conflicting === undefined
        ? '－'
        : `違反 ${blockName(evidence.conflicting[0])}/${blockName(evidence.conflicting[1])}`
    case 'liveness-stall':
      return `停止 ${evidence.stalledSlots}`
    case 'reorg':
      return `${evidence.count} 回`
    case 'attacker-stake-ratio':
      return percentLabel(evidence.ratio)
  }
}

/** The full grounds of a verdict (the cell's on-demand detail). */
export function evidenceDetail(evidence: GoalEvidence): string {
  switch (evidence.kind) {
    case 'safety-violation':
      return evidence.conflicting === undefined
        ? '相反する finalized チェックポイントなし'
        : `互いに祖先関係にない finalized チェックポイント ${blockName(
            evidence.conflicting[0],
          )} と ${blockName(evidence.conflicting[1])}`
    case 'liveness-stall':
      return `finality 停止 ${evidence.stalledSlots} スロット目（最新の finalized ${checkpointName(
        evidence.finalized,
      )}）`
    case 'reorg': {
      const latest = evidence.latest
      return `リオーグ累計 ${evidence.count} 回${
        latest === undefined
          ? ''
          : `（最新: ${validatorName(latest.validator)} s${latest.slot} ${blockName(
              latest.from,
            )} → ${blockName(latest.to)}）`
      }`
    }
    case 'attacker-stake-ratio':
      return `攻撃者ステーク比率 ${percentLabel(evidence.ratio)}${
        evidence.validator === undefined || evidence.head === undefined
          ? ''
          : `（${validatorName(evidence.validator)} の head ${blockName(
              evidence.head,
            )} のチェーン状態）`
      }`
  }
}
