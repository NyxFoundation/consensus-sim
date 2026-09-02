/**
 * Intervention panel (介入): specify partitions, operating states
 * (稼働/停止/オフライン), equivocations, per-message delay/drop and fork
 * creation (提案 parent の指定) from the UI, at slot boundaries — new
 * interventions take effect from the slot after the cursor. The scheduled
 * list stays visible and editable; removing or healing an entry
 * deterministically recomputes the displayed history.
 */

import { useState } from 'react'
import {
  closeSpanAt,
  operatingStateAt,
  proposerForSlot,
  validatorName,
  viewOf,
} from '../domain'
import type {
  SimulationConfig,
  Intervention,
  MessageRef,
  OperatingState,
  PartitionIntervention,
  SimulationState,
  ValidatorIndex,
} from '../domain'
import type { SimulationSession } from './useSimulation'
import { validatorColor } from './validatorColor'

const OP_STATE_LABELS: Readonly<Record<OperatingState, string>> = {
  active: '稼働',
  stopped: '停止',
  offline: 'オフライン',
}

/** UI-side cap on simultaneous fork-creation designations. */
const MAX_FORK_DESIGNATIONS = 4

const validatorLabel = (v: ValidatorIndex) => validatorName(v)
const setLabel = (vs: readonly ValidatorIndex[]) =>
  vs.map(validatorLabel).join(', ')

function messageLabel(ref: MessageRef): string {
  return ref.kind === 'block'
    ? `ブロック B${ref.block}`
    : `${validatorName(ref.validator)} の投票（s${ref.slot}, head B${ref.head}）`
}

function spanLabel(fromSlot: number, toSlot: number | undefined): string {
  return toSlot === undefined ? `s${fromSlot}〜` : `s${fromSlot}〜s${toSlot}`
}

function describe(i: Intervention, config: SimulationConfig): string {
  switch (i.kind) {
    case 'partition':
      return `分断 { ${i.groups.map(setLabel).join(' | ')} } ⇔ 残り全員 ${spanLabel(i.fromSlot, i.toSlot)}`
    case 'stop':
      return `停止 ${setLabel(i.validators)} ${spanLabel(i.fromSlot, i.toSlot)}`
    case 'offline':
      return `オフライン ${setLabel(i.validators)} ${spanLabel(i.fromSlot, i.toSlot)}`
    case 'propose-parent':
      return `フォーク作成 parent B${i.parent} @ s${i.slot}（提案者 ${validatorName(
        proposerForSlot(i.slot, config),
      )}）`
    case 'double-propose':
      return `二重提案 ${validatorLabel(i.validator)} @ s${i.slot}`
    case 'double-vote':
      return `二重投票 ${validatorLabel(i.validator)} @ s${i.slot}`
    case 'delay':
      return `遅延 ${messageLabel(i.message)} → s${i.untilSlot} まで${
        i.observers ? `（対象: ${setLabel(i.observers)}）` : ''
      }`
    case 'drop':
      return `欠落 ${messageLabel(i.message)}${
        i.observers ? `（対象: ${setLabel(i.observers)}）` : ''
      }`
  }
}

interface MessageOption {
  readonly key: string
  readonly ref: MessageRef
  readonly label: string
}

/**
 * Every deliverable message currently in the log, grouped by publish slot
 * (newest slot first) so the selector stays readable on long runs.
 */
function messageOptionGroups(
  state: SimulationState,
): { slot: number; options: MessageOption[] }[] {
  const blocks = state.log.blocks.map((m) => ({
    key: `block:${m.block.index}`,
    ref: { kind: 'block', block: m.block.index } as MessageRef,
    label: `ブロック B${m.block.index}（提案 ${validatorName(m.block.proposer)}, s${m.block.slot}）`,
    at: m.publishedAt,
  }))
  const votes = state.log.votes.map((m) => ({
    key: `vote:${m.vote.validator}:${m.vote.slot}:${m.vote.head}`,
    ref: {
      kind: 'vote',
      validator: m.vote.validator,
      slot: m.vote.slot,
      head: m.vote.head,
    } as MessageRef,
    label: `${validatorName(m.vote.validator)} の投票（s${m.vote.slot}, head B${m.vote.head}）`,
    at: m.publishedAt,
  }))
  const bySlot = new Map<number, MessageOption[]>()
  for (const { at, key, ref, label } of [...blocks, ...votes]) {
    const list = bySlot.get(at) ?? []
    list.push({ key, ref, label })
    bySlot.set(at, list)
  }
  return [...bySlot.entries()]
    .sort((a, b) => b[0] - a[0])
    .map(([slot, options]) => ({ slot, options }))
}

export interface InterventionPanelProps {
  readonly session: SimulationSession
}

export function InterventionPanel({ session }: InterventionPanelProps) {
  const { current, config, interventions, cursor, delivery } = session
  const validators = Array.from({ length: config.validatorCount }, (_, v) => v)
  const nextSlot = cursor + 1
  const nextProposer = proposerForSlot(nextSlot, config)

  const [groupA, setGroupA] = useState<readonly ValidatorIndex[]>([])
  const [dvValidator, setDvValidator] = useState<ValidatorIndex>(0)
  const [forkParent, setForkParent] = useState('')
  const [msgKey, setMsgKey] = useState('')
  const [msgAction, setMsgAction] = useState<'drop' | 'delay'>('drop')
  const [delayUntil, setDelayUntil] = useState('')
  const [msgTargets, setMsgTargets] = useState<readonly ValidatorIndex[]>([])

  const add = (i: Intervention) =>
    session.setInterventions([...interventions, i])
  const replaceAt = (index: number, i: Intervention) =>
    session.setInterventions(interventions.map((x, k) => (k === index ? i : x)))
  const removeAt = (index: number) =>
    session.setInterventions(interventions.filter((_, k) => k !== index))

  const toggleIn = (
    list: readonly ValidatorIndex[],
    v: ValidatorIndex,
  ): ValidatorIndex[] =>
    list.includes(v) ? list.filter((x) => x !== v) : [...list, v].sort((a, b) => a - b)

  const openPartition = (i: Intervention): i is PartitionIntervention =>
    i.kind === 'partition' && (i.toSlot === undefined || i.toSlot >= nextSlot)

  // Operating state (稼働状態) of the next slot — what the control displays.
  const opStateOf = (v: ValidatorIndex): OperatingState =>
    operatingStateAt(interventions, v, nextSlot)

  /** Move v to `target` from the next slot: close every stop/offline span
   * covering v at the next slot (closeSpanAt removes one starting exactly
   * there, so no toSlot-before-fromSlot entry can be produced), then open
   * the new one. Spans starting later than the next slot — scheduled ahead
   * after a rewind — are not what the control displays, so they are left
   * untouched. */
  const setOpState = (v: ValidatorIndex, target: OperatingState) => {
    if (opStateOf(v) === target) return
    const next: Intervention[] = []
    for (const i of interventions) {
      if (
        (i.kind === 'stop' || i.kind === 'offline') &&
        i.validators.includes(v) &&
        i.fromSlot <= nextSlot &&
        (i.toSlot === undefined || i.toSlot >= nextSlot)
      ) {
        const others = i.validators.filter((x) => x !== v)
        if (others.length > 0) next.push({ ...i, validators: others })
        const closed = closeSpanAt({ ...i, validators: [v] }, cursor)
        if (closed) next.push(closed)
      } else {
        next.push(i)
      }
    }
    if (target !== 'active') {
      next.push({
        kind: target === 'stopped' ? 'stop' : 'offline',
        fromSlot: nextSlot,
        validators: [v],
      })
    }
    session.setInterventions(next)
  }

  // Fork creation (フォーク作成): the next proposer's parent choice, offered
  // from the blocks of its own view (提案は slot < nextSlot のビューから).
  const forkDesignations = interventions.filter(
    (i) => i.kind === 'propose-parent',
  ).length
  const forkScheduled = interventions.some(
    (i) => i.kind === 'propose-parent' && i.slot === nextSlot,
  )
  const forkAtCap = forkDesignations >= MAX_FORK_DESIGNATIONS
  const proposerBlocks = [
    ...viewOf(current.log, nextProposer, cursor, delivery).blockTree.blocks.values(),
  ].sort((a, b) => a.index - b.index)

  const doubleProposeScheduled = interventions.some(
    (i) => i.kind === 'double-propose' && i.slot === nextSlot,
  )
  const doubleVoteScheduled = interventions.some(
    (i) => i.kind === 'double-vote' && i.slot === nextSlot && i.validator === dvValidator,
  )

  const optionGroups = messageOptionGroups(current)
  const selectedMessage = optionGroups
    .flatMap((g) => g.options)
    .find((o) => o.key === msgKey)
  const applyMessageIntervention = () => {
    if (!selectedMessage) return
    const scoped = msgTargets.length > 0 ? { observers: msgTargets } : {}
    if (msgAction === 'drop') {
      add({ kind: 'drop', message: selectedMessage.ref, ...scoped })
    } else {
      const until = Number(delayUntil)
      if (!Number.isInteger(until) || until <= cursor) return
      add({
        kind: 'delay',
        message: selectedMessage.ref,
        untilSlot: until,
        ...scoped,
      })
    }
    setMsgKey('')
  }

  return (
    <section className="intervention-panel" aria-label="介入">
      <details open>
        <summary className="panel-summary">
          <h2 className="intervention-title">
            介入
            {interventions.length > 0 && `（${interventions.length} 件指定中）`}{' '}
            <span className="intervention-note">
              新規指定は次のスロット s{nextSlot} の境界から適用
            </span>
          </h2>
        </summary>

      <div className="intervention-forms">
        <fieldset className="intervention-group">
          <legend>分断</legend>
          <div className="validator-checks">
            {validators.map((v) => (
              <label key={v} className="check-inline">
                <input
                  type="checkbox"
                  checked={groupA.includes(v)}
                  onChange={() => setGroupA(toggleIn(groupA, v))}
                />
                <span
                  className="validator-dot"
                  style={{ background: validatorColor(v) }}
                />
                {validatorLabel(v)}
              </label>
            ))}
          </div>
          <button
            type="button"
            disabled={groupA.length === 0 || groupA.length === validators.length}
            onClick={() => {
              add({ kind: 'partition', fromSlot: nextSlot, groups: [groupA] })
              setGroupA([])
            }}
          >
            選択集合を残りから分断
          </button>
        </fieldset>

        <fieldset className="intervention-group">
          <legend>
            稼働状態{' '}
            <span className="intervention-note">
              停止 = 提案・投票をやめる（受信は続く）／ オフライン =
              送受信とも遮断（ビュー凍結、復帰後は通常の伝搬で追いつく）
            </span>
          </legend>
          {validators.map((v) => {
            const opState = opStateOf(v)
            return (
              <div className="form-line op-state-line" key={v}>
                <span className="op-state-name">
                  <span
                    className="validator-dot"
                    style={{ background: validatorColor(v) }}
                  />
                  {validatorLabel(v)}
                </span>
                <div
                  className="segmented"
                  role="group"
                  aria-label={`${validatorLabel(v)} の稼働状態`}
                >
                  {(Object.keys(OP_STATE_LABELS) as OperatingState[]).map((s) => (
                    <button
                      type="button"
                      key={s}
                      className={opState === s ? 'active' : ''}
                      aria-pressed={opState === s}
                      onClick={() => setOpState(v, s)}
                    >
                      {OP_STATE_LABELS[s]}
                    </button>
                  ))}
                </div>
              </div>
            )
          })}
        </fieldset>

        <fieldset className="intervention-group">
          <legend>フォーク作成（提案 parent の指定）</legend>
          <div className="form-line">
            s{nextSlot} の提案者 {validatorLabel(nextProposer)} が
            <select
              aria-label="提案の parent ブロック"
              value={forkParent}
              onChange={(e) => setForkParent(e.target.value)}
            >
              <option value="">parent を選択…</option>
              {proposerBlocks.map((b) => (
                <option key={b.index} value={b.index}>
                  B{b.index}（s{b.slot}）
                </option>
              ))}
            </select>
            の上に提案
          </div>
          <button
            type="button"
            disabled={forkParent === '' || forkScheduled || forkAtCap}
            onClick={() => {
              add({
                kind: 'propose-parent',
                slot: nextSlot,
                parent: Number(forkParent),
              })
              setForkParent('')
            }}
          >
            {forkScheduled
              ? `フォーク作成を予約済み（s${nextSlot}）`
              : 'フォークを作成'}
          </button>
          <span className="intervention-note">
            {forkAtCap
              ? 'フォーク作成の指定は同時 4 本まで（既存の指定を削除すると追加できます）'
              : '未指定時は fork choice が parent を選びます'}
          </span>
        </fieldset>

        <fieldset className="intervention-group">
          <legend>equivocation（二重提案・二重投票）</legend>
          <button
            type="button"
            disabled={doubleProposeScheduled}
            onClick={() =>
              add({ kind: 'double-propose', slot: nextSlot, validator: nextProposer })
            }
          >
            {doubleProposeScheduled
              ? `二重提案を予約済み（s${nextSlot}）`
              : `次スロットで二重提案（提案者 ${validatorName(nextProposer)}）`}
          </button>
          <div className="form-line">
            <select
              aria-label="二重投票するバリデータ"
              value={dvValidator}
              onChange={(e) => setDvValidator(Number(e.target.value))}
            >
              {validators.map((v) => (
                <option key={v} value={v}>
                  {validatorLabel(v)}
                </option>
              ))}
            </select>
            <button
              type="button"
              disabled={doubleVoteScheduled}
              onClick={() =>
                add({ kind: 'double-vote', slot: nextSlot, validator: dvValidator })
              }
            >
              {doubleVoteScheduled ? '二重投票を予約済み' : '次スロットで二重投票'}
            </button>
          </div>
        </fieldset>

        <fieldset className="intervention-group">
          <legend>メッセージの遅延・欠落</legend>
          <div className="form-line">
            <select
              aria-label="対象メッセージ"
              value={msgKey}
              disabled={optionGroups.length === 0}
              onChange={(e) => setMsgKey(e.target.value)}
            >
              <option value="">メッセージを選択…</option>
              {optionGroups.map((g) => (
                <optgroup key={g.slot} label={`発行スロット s${g.slot}`}>
                  {g.options.map((o) => (
                    <option key={o.key} value={o.key}>
                      {o.label}
                    </option>
                  ))}
                </optgroup>
              ))}
            </select>
            {optionGroups.length === 0 && (
              <span className="intervention-note">
                メッセージはまだありません。スロットを進めると提案・投票を選べます。
              </span>
            )}
          </div>
          <div className="form-line">
            <label className="check-inline">
              <input
                type="radio"
                name="msg-action"
                checked={msgAction === 'drop'}
                onChange={() => setMsgAction('drop')}
              />
              欠落（届かない）
            </label>
            <label className="check-inline">
              <input
                type="radio"
                name="msg-action"
                checked={msgAction === 'delay'}
                onChange={() => setMsgAction('delay')}
              />
              遅延
            </label>
            {msgAction === 'delay' && (
              <label className="check-inline">
                s
                <input
                  type="number"
                  className="slot-input"
                  aria-label="遅延の到達スロット"
                  min={cursor + 1}
                  value={delayUntil}
                  onChange={(e) => setDelayUntil(e.target.value)}
                />
                で到達
              </label>
            )}
          </div>
          <div className="validator-checks">
            対象:
            {validators.map((v) => (
              <label key={v} className="check-inline">
                <input
                  type="checkbox"
                  checked={msgTargets.includes(v)}
                  onChange={() => setMsgTargets(toggleIn(msgTargets, v))}
                />
                {validatorLabel(v)}
              </label>
            ))}
            <span className="intervention-note">（未選択 = 送信者以外の全員）</span>
          </div>
          <button
            type="button"
            disabled={
              !selectedMessage ||
              (msgAction === 'delay' &&
                (!Number.isInteger(Number(delayUntil)) ||
                  Number(delayUntil) <= cursor))
            }
            onClick={applyMessageIntervention}
          >
            適用
          </button>
        </fieldset>
      </div>

      {interventions.length > 0 ? (
        <ul className="intervention-list">
          {interventions.map((i, index) => (
            <li key={index}>
              <span className="intervention-desc">
                {describe(i, config)}
              </span>
              {openPartition(i) && (
                <button
                  type="button"
                  onClick={() => {
                    const closed = closeSpanAt(i, cursor)
                    if (closed) replaceAt(index, closed)
                    else removeAt(index)
                  }}
                >
                  解消（次スロットから）
                </button>
              )}
              <button type="button" onClick={() => removeAt(index)}>
                削除
              </button>
            </li>
          ))}
        </ul>
      ) : (
        <p className="empty-hint">
          介入はまだありません。上のフォームで指定すると、ここに一覧が並び、
          解消・削除で表示中の履歴が決定的に再計算されます。
        </p>
      )}
      </details>
    </section>
  )
}
