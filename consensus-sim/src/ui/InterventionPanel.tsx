/**
 * Intervention panel (介入): specify partitions, operating states
 * (稼働/停止/オフライン), equivocations, per-message delay/drop (with a
 * receiver set), fork creation (提案 parent の指定), vote designation
 * (投票先指定) and omitted inclusion (取り込みの省略) from the UI, at slot
 * boundaries — new interventions take effect from the slot after the
 * cursor. The scheduled list stays visible and editable; removing or
 * healing an entry deterministically recomputes the displayed history.
 */

import { useState } from 'react'
import {
  ANCHOR_BLOCK_INDEX,
  MAX_FORKS,
  atEnd,
  atProposal,
  blockRef,
  buildBody,
  checkpointFor,
  checkpointKey,
  closeSpanAt,
  epochOf,
  evidenceRef,
  forkCountAfter,
  leavesUnder,
  operatingStateAt,
  pendingForkParents,
  proposerForSlot,
  resolveView,
  scheduleOf,
  validatorName,
  viewOf,
  voteKey,
  voteRef,
} from '../domain'
import type {
  Checkpoint,
  EvidenceRef,
  InitialConditions,
  Intervention,
  MessageRef,
  OperatingState,
  PartitionAction,
  SimulationState,
  ValidatorIndex,
} from '../domain'
import { evidenceLabel } from './ChainStateDetail'
import { Button } from './components/Button'
import { Checkbox } from './components/Checkbox'
import { Disclosure } from './components/Disclosure'
import { NumberField } from './components/NumberField'
import { Segmented } from './components/Segmented'
import { Select } from './components/Select'
import { blockName, checkpointName } from './format'
import type { SimulationSession } from './useSimulation'
import { validatorColor } from './validatorColor'

const OP_STATE_LABELS: Readonly<Record<OperatingState, string>> = {
  active: '稼働',
  stopped: '停止',
  offline: 'オフライン',
}

const validatorLabel = (v: ValidatorIndex) => validatorName(v)
const setLabel = (vs: readonly ValidatorIndex[]) =>
  vs.map(validatorLabel).join(', ')

function messageLabel(ref: MessageRef): string {
  const who = validatorName(ref.sender)
  if (ref.kind === 'proposal') {
    return ref.block === undefined
      ? `${who} の提案（s${ref.slot}）`
      : `ブロック ${blockName(ref.block)}`
  }
  return ref.vote === undefined
    ? `${who} の投票（s${ref.slot}）`
    : `${who} の投票（s${ref.slot}, head ${blockName(ref.vote.head)}）`
}

function spanLabel(fromSlot: number, toSlot: number | undefined): string {
  return toSlot === undefined ? `s${fromSlot}〜` : `s${fromSlot}〜s${toSlot}`
}

function describe(i: Intervention, config: InitialConditions): string {
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
      return `二重投票 ${validatorLabel(i.validator)} @ s${i.slot}${
        i.head === undefined ? '' : `（2 票目 head ${blockName(i.head)}）`
      }${
        i.split === undefined
          ? ''
          : `（選択配送: 1 票目→${setLabel(i.split.first)}, 2 票目→${setLabel(
              i.split.second,
            )}, 他は s${i.split.untilSlot} から）`
      }`
    case 'delay':
      return `遅延 ${messageLabel(i.message)} → s${i.untilSlot} まで${
        i.observers ? `（対象: ${setLabel(i.observers)}）` : ''
      }`
    case 'drop':
      return `欠落 ${messageLabel(i.message)}${
        i.observers ? `（対象: ${setLabel(i.observers)}）` : ''
      }`
    case 'vote-target': {
      const parts = [
        ...(i.head !== undefined ? [`head ${blockName(i.head)}`] : []),
        ...(i.source !== undefined ? [`source ${checkpointName(i.source)}`] : []),
        ...(i.target !== undefined ? [`target ${blockName(i.target)}`] : []),
      ]
      return `投票先指定 ${validatorLabel(i.validator)} @ s${i.slot}（${parts.join(', ')}）`
    }
    case 'omit-inclusion':
      return `取り込み省略 @ s${i.slot}（提案者 ${validatorName(
        proposerForSlot(i.slot, config),
      )}）: 投票 ${i.votes?.length ?? 0} 件・証拠 ${i.evidence?.length ?? 0} 件`
  }
}

const messageKey = (r: MessageRef) =>
  r.kind === 'proposal'
    ? `proposal:${r.sender}:${r.slot}:${r.block ?? ''}`
    : `vote:${r.sender}:${r.slot}:${r.vote === undefined ? '' : voteKey(r.vote)}`
const evidenceRefKey = (r: EvidenceRef) => `${r.kind}:${r.validator}:${r.slot}`

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
  const blocks = state.log.blocks.map((m) => {
    const ref = blockRef(m.block)
    return {
      key: messageKey(ref),
      ref,
      label: `ブロック ${blockName(m.block.index)}（提案 ${validatorName(m.block.proposer)}, s${m.block.slot}）`,
      at: m.publishedAt,
    }
  })
  const votes = state.log.votes.map((m) => {
    const ref = voteRef(m.vote)
    return { key: messageKey(ref), ref, label: messageLabel(ref), at: m.publishedAt }
  })
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
  const [vtValidator, setVtValidator] = useState<ValidatorIndex>(0)
  const [vtBlocks, setVtBlocks] = useState({ head: '', source: '', target: '' })
  const [omitVotes, setOmitVotes] = useState<readonly string[]>([])
  const [omitEvidence, setOmitEvidence] = useState<readonly string[]>([])

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

  const openPartition = (i: Intervention): i is PartitionAction =>
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
  // Accepted only while the fork count (神視点の最新 finalized 以下の葉数)
  // after the pending designations and this one stays ≤ MAX_FORKS.
  const forkScheduled = interventions.some(
    (i) => i.kind === 'propose-parent' && i.slot === nextSlot,
  )
  const pendingForks = pendingForkParents(interventions, cursor)
  const forkCountNow = forkCountAfter(current.tree, current.chainStates, [])
  const forkCountPending = forkCountAfter(current.tree, current.chainStates, pendingForks)
  const forkCountDesignated =
    forkParent === ''
      ? forkCountPending
      : forkCountAfter(current.tree, current.chainStates, [
          ...pendingForks,
          Number(forkParent),
        ])
  const forkRefused = forkCountDesignated > MAX_FORKS
  const proposerBlocks = [
    ...viewOf(current.log, nextProposer, atEnd(cursor), delivery).blockTree.blocks.values(),
  ].sort((a, b) => a.index - b.index)

  const doubleProposeScheduled = interventions.some(
    (i) => i.kind === 'double-propose' && i.slot === nextSlot,
  )
  const doubleVoteScheduled = interventions.some(
    (i) => i.kind === 'double-vote' && i.slot === nextSlot && i.validator === dvValidator,
  )

  // Vote designation (投票先指定): head and target offered from the blocks of
  // the voter's own view at the cursor, the source from the checkpoints of
  // that view's branches (every epoch up to the next slot's, on every leaf);
  // the vote itself is cast from its view at the next slot.
  const voterTree = viewOf(current.log, vtValidator, atEnd(cursor), delivery).blockTree
  const voterBlocks = [...voterTree.blocks.values()].sort((a, b) => a.index - b.index)
  const voterCheckpoints = (() => {
    const found = new Map<string, Checkpoint>()
    for (const leaf of leavesUnder(voterTree, ANCHOR_BLOCK_INDEX)) {
      for (let epoch = 0; epoch <= epochOf(nextSlot); epoch++) {
        const c = checkpointFor(voterTree, leaf, epoch)
        found.set(checkpointKey(c), c)
      }
    }
    return [...found.values()].sort((a, b) => a.epoch - b.epoch || a.block - b.block)
  })()
  const voteTargetScheduled = interventions.some(
    (i) => i.kind === 'vote-target' && i.slot === nextSlot && i.validator === vtValidator,
  )
  const voteTargetEmpty = !vtBlocks.head && !vtBlocks.source && !vtBlocks.target
  const designateVote = () => {
    const source = voterCheckpoints.find((c) => checkpointKey(c) === vtBlocks.source)
    add({
      kind: 'vote-target',
      slot: nextSlot,
      validator: vtValidator,
      ...(vtBlocks.head !== '' ? { head: Number(vtBlocks.head) } : {}),
      ...(source !== undefined ? { source } : {}),
      ...(vtBlocks.target !== '' ? { target: Number(vtBlocks.target) } : {}),
    })
    setVtBlocks({ head: '', source: '', target: '' })
  }

  // Omitted inclusion (取り込みの省略): what the next proposer would include
  // — everything in its view not yet on the branch it builds on.
  const proposerView = viewOf(current.log, nextProposer, atProposal(nextSlot), delivery)
  const scheduledParent = interventions.find(
    (i) => i.kind === 'propose-parent' && i.slot === nextSlot,
  )
  const inclusionParent =
    scheduledParent?.kind === 'propose-parent' &&
    proposerView.blockTree.blocks.has(scheduledParent.parent)
      ? scheduledParent.parent
      : resolveView(proposerView, config, scheduleOf(config), nextSlot).head
  const candidates = buildBody(proposerView.blockTree, proposerView.votes, inclusionParent)
  const toggleKey = (list: readonly string[], key: string): string[] =>
    list.includes(key) ? list.filter((k) => k !== key) : [...list, key]
  const omitSelected = omitVotes.length + omitEvidence.length > 0
  const scheduleOmission = () => {
    const votes = candidates.votes.map(voteRef).filter((r) => omitVotes.includes(messageKey(r)))
    const evidence = candidates.evidence
      .map(evidenceRef)
      .filter((r) => omitEvidence.includes(evidenceRefKey(r)))
    add({
      kind: 'omit-inclusion',
      slot: nextSlot,
      ...(votes.length > 0 ? { votes } : {}),
      ...(evidence.length > 0 ? { evidence } : {}),
    })
    setOmitVotes([])
    setOmitEvidence([])
  }

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
      <Disclosure
        summary={
          <h2 className="intervention-title">
            介入
            {interventions.length > 0 && `（${interventions.length} 件指定中）`}{' '}
            <span className="intervention-note">
              新規指定は次のスロット s{nextSlot} の境界から適用
            </span>
          </h2>
        }
      >
      <div className="intervention-forms">
        <fieldset className="intervention-group">
          <legend>分断</legend>
          <div className="validator-checks">
            {validators.map((v) => (
              <label key={v} className="check-inline">
                <Checkbox
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
          <Button
            disabled={groupA.length === 0 || groupA.length === validators.length}
            onClick={() => {
              add({ kind: 'partition', fromSlot: nextSlot, groups: [groupA] })
              setGroupA([])
            }}
          >
            選択集合を残りから分断
          </Button>
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
                <Segmented
                  label={`${validatorLabel(v)} の稼働状態`}
                  value={opState}
                  options={(Object.keys(OP_STATE_LABELS) as OperatingState[]).map((s) => ({
                    key: s,
                    label: OP_STATE_LABELS[s],
                  }))}
                  onChange={(s) => setOpState(v, s)}
                />
              </div>
            )
          })}
        </fieldset>

        <fieldset className="intervention-group">
          <legend>フォーク作成（提案 parent の指定）</legend>
          <div className="form-line">
            s{nextSlot} の提案者 {validatorLabel(nextProposer)} が
            <Select
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
            </Select>
            の上に提案
          </div>
          <Button
            disabled={forkParent === '' || forkScheduled || forkRefused}
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
          </Button>
          <span className="intervention-note">
            フォーク数 {forkCountNow}
            {forkCountPending !== forkCountNow &&
              `（未実行の指定を含めて ${forkCountPending}）`}
            ／上限 {MAX_FORKS}
          </span>
          <span className="intervention-note">
            {forkRefused
              ? `この指定でフォーク数が ${forkCountDesignated} となり上限を超えるため受け付けません（finality が進んでフォーク数が減ると再び指定できます）`
              : '未指定時は fork choice が parent を選びます。フォーク数は最新 finalized ブロックを根とする部分木の葉数'}
          </span>
        </fieldset>

        <fieldset className="intervention-group">
          <legend>equivocation（二重提案・二重投票）</legend>
          <Button
            disabled={doubleProposeScheduled}
            onClick={() =>
              add({ kind: 'double-propose', slot: nextSlot, validator: nextProposer })
            }
          >
            {doubleProposeScheduled
              ? `二重提案を予約済み（s${nextSlot}）`
              : `次スロットで二重提案（提案者 ${validatorName(nextProposer)}）`}
          </Button>
          <div className="form-line">
            <Select
              aria-label="二重投票するバリデータ"
              value={dvValidator}
              onChange={(e) => setDvValidator(Number(e.target.value))}
            >
              {validators.map((v) => (
                <option key={v} value={v}>
                  {validatorLabel(v)}
                </option>
              ))}
            </Select>
            <Button
              disabled={doubleVoteScheduled}
              onClick={() =>
                add({ kind: 'double-vote', slot: nextSlot, validator: dvValidator })
              }
            >
              {doubleVoteScheduled ? '二重投票を予約済み' : '次スロットで二重投票'}
            </Button>
          </div>
        </fieldset>

        <fieldset className="intervention-group">
          <legend>メッセージの遅延・欠落</legend>
          <div className="form-line">
            <Select
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
            </Select>
            {optionGroups.length === 0 && (
              <span className="intervention-note">
                メッセージはまだありません。スロットを進めると提案・投票を選べます。
              </span>
            )}
          </div>
          <div className="form-line">
            <Segmented
              label="欠落・遅延の別"
              value={msgAction}
              options={
                [
                  { key: 'drop', label: '欠落（届かない）' },
                  { key: 'delay', label: '遅延' },
                ] as const
              }
              onChange={(a) => setMsgAction(a)}
            />
            {msgAction === 'delay' && (
              <label className="check-inline">
                s
                <NumberField
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
                <Checkbox
                  checked={msgTargets.includes(v)}
                  onChange={() => setMsgTargets(toggleIn(msgTargets, v))}
                />
                {validatorLabel(v)}
              </label>
            ))}
            <span className="intervention-note">（未選択 = 送信者以外の全員）</span>
          </div>
          <Button
            disabled={
              !selectedMessage ||
              (msgAction === 'delay' &&
                (!Number.isInteger(Number(delayUntil)) ||
                  Number(delayUntil) <= cursor))
            }
            onClick={applyMessageIntervention}
          >
            適用
          </Button>
        </fieldset>

        <fieldset className="intervention-group">
          <legend>投票先指定（head / source / target）</legend>
          <div className="form-line">
            <Select
              aria-label="投票先を指定するバリデータ"
              value={vtValidator}
              onChange={(e) => {
                setVtValidator(Number(e.target.value))
                setVtBlocks({ head: '', source: '', target: '' })
              }}
            >
              {validators.map((v) => (
                <option key={v} value={v}>
                  {validatorLabel(v)}
                </option>
              ))}
            </Select>
            の s{nextSlot} の投票
          </div>
          <div className="form-line">
            {(['head', 'target'] as const).map((k) => (
              <label key={k} className="check-inline">
                {k}
                <Select
                  aria-label={`投票の ${k}`}
                  value={vtBlocks[k]}
                  onChange={(e) => setVtBlocks({ ...vtBlocks, [k]: e.target.value })}
                >
                  <option value="">規則どおり</option>
                  {voterBlocks.map((b) => (
                    <option key={b.index} value={b.index}>
                      {blockName(b.index)}（s{b.slot}）
                    </option>
                  ))}
                </Select>
              </label>
            ))}
            <label className="check-inline">
              source
              <Select
                aria-label="投票の source"
                value={vtBlocks.source}
                onChange={(e) => setVtBlocks({ ...vtBlocks, source: e.target.value })}
              >
                <option value="">規則どおり</option>
                {voterCheckpoints.map((c) => (
                  <option key={checkpointKey(c)} value={checkpointKey(c)}>
                    {checkpointName(c)}
                  </option>
                ))}
              </Select>
            </label>
          </div>
          <Button
            disabled={voteTargetEmpty || voteTargetScheduled}
            onClick={designateVote}
          >
            {voteTargetScheduled
              ? `投票先を指定済み（${validatorLabel(vtValidator)} s${nextSlot}）`
              : '投票先を指定'}
          </Button>
          <span className="intervention-note">
            head / target の候補はそのバリデータのビュー内のブロック（target
            のエポックはスロットから定まる）、source はビュー内の枝のチェックポイント。
            未指定の成分は fork choice と FFG の規則どおり（head 指定時はその枝で計算）
          </span>
        </fieldset>

        <fieldset className="intervention-group">
          <legend>取り込みの省略</legend>
          <div className="form-line">
            {`s${nextSlot} の提案者 ${validatorLabel(nextProposer)} が ${blockName(inclusionParent)} 上の提案で省く項目:`}
          </div>
          {candidates.votes.length === 0 && candidates.evidence.length === 0 ? (
            <span className="intervention-note">
              取り込み候補はありません（ビュー内の未取り込みの投票・証拠がここに並びます）
            </span>
          ) : (
            <div className="validator-checks">
              {candidates.votes.map((v) => {
                const key = messageKey(voteRef(v))
                const label = `${validatorName(v.validator)} の投票（s${v.slot}, head ${blockName(v.head)}）`
                return (
                  <label key={key} className="check-inline">
                    <Checkbox
                      aria-label={`省略候補: ${label}`}
                      checked={omitVotes.includes(key)}
                      onChange={() => setOmitVotes(toggleKey(omitVotes, key))}
                    />
                    {label}
                  </label>
                )
              })}
              {candidates.evidence.map((e) => {
                const key = evidenceRefKey(evidenceRef(e))
                const label = evidenceLabel(e)
                return (
                  <label key={key} className="check-inline">
                    <Checkbox
                      aria-label={`省略候補: ${label}`}
                      checked={omitEvidence.includes(key)}
                      onChange={() => setOmitEvidence(toggleKey(omitEvidence, key))}
                    />
                    {label}
                  </label>
                )
              })}
            </div>
          )}
          <Button disabled={!omitSelected} onClick={scheduleOmission}>
            次の提案で省略
          </Button>
          <span className="intervention-note">
            省いた項目は後のブロックが取り込める（未指定時は規則どおりすべて取り込む）
          </span>
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
                <Button
                  onClick={() => {
                    const closed = closeSpanAt(i, cursor)
                    if (closed) replaceAt(index, closed)
                    else removeAt(index)
                  }}
                >
                  解消（次スロットから）
                </Button>
              )}
              <Button onClick={() => removeAt(index)}>削除</Button>
            </li>
          ))}
        </ul>
      ) : (
        <p className="empty-hint">
          介入はまだありません。上のフォームで指定すると、ここに一覧が並び、
          解消・削除で表示中の履歴が決定的に再計算されます。
        </p>
      )}
      </Disclosure>
    </section>
  )
}
