// @vitest-environment jsdom
/**
 * Protocol parameter panel, driven through the real DOM (成功条件 14・22・
 * 23・25): presets switch every value at once and the default is merge,
 * committee size limits who votes and the seed picks whom, boost changes
 * the fork-choice outcome of the same run, slashing and the inactivity
 * leak show up in the state table's stake item, and per-validator initial
 * stakes are saved with the scenario.
 */

import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import {
  PRESETS,
  committeeForSlot,
  equalStakes,
  validatorName,
} from '../../src/domain'
import { App } from '../../src/ui/App'

declare global {
  var IS_REACT_ACT_ENVIRONMENT: boolean
}
globalThis.IS_REACT_ACT_ENVIRONMENT = true

let container: HTMLDivElement
let root: Root

beforeEach(async () => {
  localStorage.clear()
  container = document.createElement('div')
  document.body.appendChild(container)
  root = createRoot(container)
  await act(async () => {
    root.render(<App />)
  })
})

afterEach(async () => {
  await act(async () => {
    root.unmount()
  })
  container.remove()
})

function text(selector: string): string {
  return container.querySelector(selector)?.textContent ?? ''
}

function all(selector: string): Element[] {
  return [...container.querySelectorAll(selector)]
}

async function click(el: Element | null | undefined) {
  if (!el) throw new Error('click target not found')
  await act(async () => {
    el.dispatchEvent(new MouseEvent('click', { bubbles: true }))
  })
}

function buttonByText(label: string): Element | undefined {
  return all('button').find((b) => b.textContent?.includes(label))
}

async function advance(times: number) {
  for (let i = 0; i < times; i++) {
    await click(buttonByText('＋1 スロット進める'))
  }
}

function input(label: string): HTMLInputElement {
  const el = container.querySelector(`input[aria-label="${label}"]`)
  if (!(el instanceof HTMLInputElement)) throw new Error(`input ${label} not found`)
  return el
}

/** Type into a controlled number input (through the native value setter so
 * React sees the change). */
async function type(label: string, value: string) {
  const el = input(label)
  const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set
  await act(async () => {
    setter?.call(el, value)
    el.dispatchEvent(new Event('input', { bubbles: true }))
  })
}

function segment(group: string, label: string): Element | undefined {
  const g = container.querySelector(`[role="group"][aria-label="${group}"]`)
  return [...(g?.querySelectorAll('button') ?? [])].find((b) => b.textContent === label)
}

function pressed(group: string): string {
  const g = container.querySelector(`[role="group"][aria-label="${group}"]`)
  return (
    [...(g?.querySelectorAll('button') ?? [])].find(
      (b) => b.getAttribute('aria-pressed') === 'true',
    )?.textContent ?? ''
  )
}

async function press(group: string, label: string) {
  await click(segment(group, label))
}

async function setOpState(name: string, label: string) {
  await press(`${name} の稼働状態`, label)
}

async function selectItem(label: string) {
  await click(
    all('.state-table-toolbar .segmented button').find((b) => b.textContent === label),
  )
}

function cell(v: number, s: number): string {
  return (
    all('.chain-mode .state-table tbody tr')[v]?.querySelectorAll('td .state-cell')[s]
      ?.textContent ?? ''
  )
}

describe('presets and individual parameters (成功条件 14)', () => {
  it('starts on merge and switches every value with a preset', async () => {
    expect(pressed('プロトコルプリセット')).toBe('merge')
    expect(text('.params-panel .panel-summary')).toContain('merge')
    expect(input('proposer boost').value).toBe('0.4')
    expect(pressed('committee 割当')).toBe('全員')
    expect(pressed('fork choice 規則')).toBe('LMD-GHOST')
    expect(pressed('エクイボケーション割引')).toBe('on')
    expect(pressed('justified チェックポイント切替')).toBe('window')
    expect(pressed('スラッシング')).toBe('on')
    expect(pressed('inactivity leak')).toBe('on')
    expect(input('inactivity leak N').value).toBe('4')

    await press('プロトコルプリセット', 'phase0')
    expect(input('proposer boost').value).toBe('0')
    expect(pressed('エクイボケーション割引')).toBe('off')
    expect(pressed('justified チェックポイント切替')).toBe('window')
    expect(text('.params-panel .panel-summary')).toContain('phase0')

    await press('プロトコルプリセット', 'current')
    expect(input('proposer boost').value).toBe('0.4')
    expect(pressed('justified チェックポイント切替')).toBe('unrealized')
  })

  it('leaves the preset once a single value departs from it, and returns on reselect', async () => {
    await type('proposer boost', '0.3')
    expect(pressed('プロトコルプリセット')).toBe('')
    expect(text('.params-panel .panel-summary')).toContain('カスタム')
    await press('justified チェックポイント切替', 'off')
    expect(pressed('justified チェックポイント切替')).toBe('off')
    await press('プロトコルプリセット', 'merge')
    expect(input('proposer boost').value).toBe('0.4')
    expect(pressed('justified チェックポイント切替')).toBe('window')
    expect(pressed('プロトコルプリセット')).toBe('merge')
  })

  it('ignores an out-of-range value without losing the typed text', async () => {
    await type('proposer boost', '1.5')
    expect(input('proposer boost').value).toBe('1.5')
    expect(pressed('プロトコルプリセット')).toBe('merge')
    await type('proposer boost', '')
    await type('proposer boost', '1')
    expect(pressed('プロトコルプリセット')).toBe('')
  })
})

describe('committee size and seed', () => {
  it('lets only the c committee members vote each slot, drawn by the seed', async () => {
    await press('committee 割当', 'サイズ c')
    await type('committee サイズ c', '2')
    await advance(3)
    await selectItem('投票数')
    // Every view holds the 2 votes of each slot (instant delivery).
    expect(cell(0, 1)).toBe('2')
    expect(cell(0, 3)).toBe('6')

    // The slot-3 committee under seed 0, then under seed 7, matches the schedule.
    const expectVoters = async (seed: number) => {
      const config = {
        validatorCount: 4,
        seed,
        params: { ...PRESETS.merge, committee: { kind: 'sized', size: 2 } as const },
        initialStakes: equalStakes(4),
      }
      const expected = [...committeeForSlot(3, config)].map(validatorName)
      const voters = all('.vote-table tbody tr')
        .filter((r) => r.querySelectorAll('td')[1]?.textContent === '3')
        .map((r) => r.querySelectorAll('td')[0]?.textContent?.trim())
      expect(voters).toEqual(expected)
    }
    await expectVoters(0)
    await type('シード', '7')
    expect(text('.params-panel .panel-summary')).toContain('シード 7')
    await expectVoters(7)
  })
})

describe('proposer boost changes fork choice on the same run', () => {
  it('flips the slot-3 heads between merge and phase0 with the interventions kept', async () => {
    // Slot 2: only キャロル (its proposer) is active, so B2 gets one vote.
    await advance(1)
    for (const name of ['アリス', 'ボブ', 'デイブ']) await setOpState(name, '停止')
    await advance(1)
    for (const name of ['アリス', 'ボブ', 'デイブ']) await setOpState(name, '稼働')
    // Slot 3: デイブ forks onto B1; B3 competes with B2 for the slot-3 votes.
    const parent = container.querySelector('select[aria-label="提案の parent ブロック"]')
    if (!(parent instanceof HTMLSelectElement)) throw new Error('parent select not found')
    await act(async () => {
      parent.value = '1'
      parent.dispatchEvent(new Event('change', { bubbles: true }))
    })
    await click(buttonByText('フォークを作成'))
    await advance(1)
    expect(all('.intervention-panel .intervention-list li')).toHaveLength(4)

    // merge (boost 0.4): everyone's head at slot 3 is the boosted B3.
    expect([0, 1, 2, 3].map((v) => cell(v, 3))).toEqual(['B3', 'B3', 'B3', 'B3'])
    // phase0 (no boost): the same run recomputes and B2's branch keeps the head.
    await press('プロトコルプリセット', 'phase0')
    expect(all('.intervention-panel .intervention-list li')).toHaveLength(4)
    expect(text('.slot-current')).toContain('3')
    expect([0, 1, 2, 3].map((v) => cell(v, 3))).toEqual(['B2', 'B2', 'B2', 'B2'])
    // Back to boost alone (0.4 on top of phase0) and B3 wins again.
    await type('proposer boost', '0.4')
    expect([0, 1, 2, 3].map((v) => cell(v, 3))).toEqual(['B3', 'B3', 'B3', 'B3'])
  })
})

describe('penalties in the state table (成功条件 22・23)', () => {
  it('shows the slashed equivocator at stake 0 from the including block, not when slashing is off', async () => {
    const dv = container.querySelector('select[aria-label="二重投票するバリデータ"]')
    if (!(dv instanceof HTMLSelectElement)) throw new Error('double-vote select not found')
    await act(async () => {
      dv.value = '1'
      dv.dispatchEvent(new Event('change', { bubbles: true }))
    })
    await click(buttonByText('次スロットで二重投票'))
    await advance(2)
    await selectItem('ステーク')
    // B2 (slot 2) includes the evidence: ボブ is 0 there, 32 one slot earlier.
    expect(cell(1, 1)).toBe('32')
    expect(cell(1, 2)).toBe('0')
    expect(cell(0, 2)).toBe('32')
    expect(all('.state-cell-diff').length).toBeGreaterThan(0)
    await press('スラッシング', 'off')
    expect(cell(1, 2)).toBe('32')
  })

  it('leaks the non-participants once finality has stalled N epochs, not when the leak is off', async () => {
    await setOpState('キャロル', '停止')
    await setOpState('デイブ', '停止')
    await advance(24)
    await selectItem('ステーク')
    expect([0, 1, 2, 3].map((v) => cell(v, 23))).toEqual(['32', '32', '32', '32'])
    expect([0, 1, 2, 3].map((v) => cell(v, 24))).toEqual(['32', '32', '24', '24'])
    await press('inactivity leak', 'off')
    expect([0, 1, 2, 3].map((v) => cell(v, 24))).toEqual(['32', '32', '32', '32'])
  })
})

describe('initial stakes (成功条件 25)', () => {
  it('default to equal stakes, are set per validator, and are saved with the scenario', async () => {
    for (let v = 0; v < 4; v++) {
      expect(input(`${validatorName(v)} の初期ステーク`).value).toBe('32')
    }
    await selectItem('ステーク')
    await type('ボブ の初期ステーク', '48')
    expect(cell(1, 0)).toBe('48')
    expect(cell(0, 0)).toBe('32')
    await advance(1)
    expect(cell(1, 1)).toBe('48')

    await click(buttonByText('現在のシナリオを保存'))
    expect(text('.scenario-panel .intervention-list')).toContain('merge')
    await type('ボブ の初期ステーク', '16')
    expect(cell(1, 1)).toBe('16')
    await click(buttonByText('読込・再実行'))
    expect(input('ボブ の初期ステーク').value).toBe('48')
    expect(cell(1, 1)).toBe('48')

    await click(buttonByText('全員等しく'))
    expect(input('ボブ の初期ステーク').value).toBe('32')
    expect(cell(1, 1)).toBe('32')
  })

  it('keeps the parameters and resizes the stakes when the validator count changes', async () => {
    await press('プロトコルプリセット', 'current')
    await type('アリス の初期ステーク', '40')
    const select = container.querySelector('.field-inline select')
    if (!(select instanceof HTMLSelectElement)) throw new Error('select not found')
    await act(async () => {
      select.value = '6'
      select.dispatchEvent(new Event('change', { bubbles: true }))
    })
    expect(pressed('プロトコルプリセット')).toBe('current')
    expect(all('.params-panel input[aria-label$="の初期ステーク"]')).toHaveLength(6)
    expect(input('アリス の初期ステーク').value).toBe('40')
    expect(input('フランク の初期ステーク').value).toBe('32')
  })
})
