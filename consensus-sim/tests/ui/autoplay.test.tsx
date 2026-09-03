// @vitest-environment jsdom
/**
 * Auto-play (自動再生, 必須 31), driven through the real DOM with fake
 * timers (成功条件 28): choosing an attack on the list and pressing 実行開始
 * is the only input — slots advance on the timer, the generated actions,
 * the attackers' marks and the goal verdicts appear per slot, playback can
 * be paused and resumed, it stops by itself at the slot the goal is judged
 * achieved (A11 — 成功条件 19's achievement stop) or at the end slot when
 * the goal is missed (A01 under the merge preset — the mitigation case),
 * and after the stop the cursor rewinds and manual operation continues.
 * The achievement slots themselves are fixed by tests/domain/attackLibrary.
 */

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { App } from '../../src/ui/App'
import { PLAY_INTERVAL_MS } from '../../src/ui/useSimulation'

declare global {
  var IS_REACT_ACT_ENVIRONMENT: boolean
}
globalThis.IS_REACT_ACT_ENVIRONMENT = true

let container: HTMLDivElement
let root: Root

beforeEach(async () => {
  vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout'] })
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
  vi.useRealTimers()
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

/** Let the auto-play timer fire `times` times. */
async function tick(times: number) {
  for (let i = 0; i < times; i++) {
    await act(async () => {
      vi.advanceTimersByTime(PLAY_INTERVAL_MS)
    })
  }
}

async function chooseFromList(id: string) {
  await click(buttonByText('攻撃一覧'))
  await click(container.querySelector(`[aria-label="攻撃 ${id} を選択"]`))
}

const slot = () => text('.slot-current strong')
const playToggle = () => container.querySelector('.play-toggle') as HTMLButtonElement
const goalHeading = () => text('.goal-table th')

describe('auto-play from the attack list (成功条件 28)', () => {
  it('advances on the timer, shows each slot, and stops at the slot the goal is achieved', async () => {
    await chooseFromList('A11')
    expect(slot()).toBe('0')
    expect(playToggle().textContent).toBe('実行開始')
    expect(text('.play-readout')).toContain('終了 s8')

    await click(playToggle())
    expect(playToggle().textContent).toBe('一時停止')
    expect(text('.play-readout')).toContain('再生中')

    await tick(1)
    expect(slot()).toBe('1')
    expect(all('.tree-block')).toHaveLength(2)
    await tick(2)
    expect(slot()).toBe('3')
    expect(goalHeading()).toContain('判定中')
    expect(all('.state-table tbody tr.attacker-row')).toHaveLength(3)

    // Slot 4: the reorg is judged achieved — playback stops there.
    await tick(1)
    expect(slot()).toBe('4')
    expect(goalHeading()).toContain('達成 @s4')
    expect(playToggle().textContent).toBe('再開')
    expect(text('.play-readout')).not.toContain('再生中')
    const generated = all('.intervention-panel .attacker-action')
    expect(generated.length).toBeGreaterThan(0)
    for (const li of generated) expect(li.textContent).toContain('攻撃者')

    // No further advance without input.
    await tick(3)
    expect(slot()).toBe('4')

    // Resuming past the achievement carries the run to its end slot.
    await click(playToggle())
    await tick(10)
    expect(slot()).toBe('8')
    expect(playToggle().textContent).toBe('再開')
    expect(playToggle().disabled).toBe(true)
  })

  it('pauses and resumes', async () => {
    await chooseFromList('A11')
    await click(playToggle())
    await tick(2)
    expect(slot()).toBe('2')

    await click(playToggle())
    expect(playToggle().textContent).toBe('再開')
    await tick(3)
    expect(slot()).toBe('2')

    await click(playToggle())
    expect(playToggle().textContent).toBe('一時停止')
    await tick(2)
    expect(slot()).toBe('4')
    expect(goalHeading()).toContain('達成 @s4')
  })

  it('rewinds with the cursor after the stop, and manual operation continues', async () => {
    await chooseFromList('A11')
    await click(playToggle())
    await tick(4)
    expect(slot()).toBe('4')

    await click(container.querySelector('[aria-label="1 スロット戻る"]'))
    await click(container.querySelector('[aria-label="1 スロット戻る"]'))
    expect(slot()).toBe('2')
    expect(text('.slot-current')).toContain('最新 4')
    expect(goalHeading()).toContain('判定中')
    // The timer is idle while rewound.
    await tick(2)
    expect(slot()).toBe('2')

    await click(buttonByText('最新へ'))
    expect(slot()).toBe('4')
    // The manual advance and the intervention forms are as before.
    await click(buttonByText('＋1 スロット進める'))
    expect(slot()).toBe('5')
    expect(container.querySelector('.intervention-panel')).not.toBeNull()
    expect(container.querySelector('[aria-label="proposer boost"]')).not.toBeNull()
  })

  it('pauses when the cursor is moved during playback', async () => {
    await chooseFromList('A11')
    await click(playToggle())
    await tick(2)
    await click(container.querySelector('[aria-label="1 スロット戻る"]'))
    expect(slot()).toBe('1')
    expect(playToggle().textContent).toBe('再開')
    await tick(2)
    expect(slot()).toBe('1')
  })
})

describe('a missed goal stops at the end slot (成功条件 19, 28)', () => {
  it('A01 under its phase0 premise achieves, under the merge preset it runs to the end slot unachieved', async () => {
    await chooseFromList('A01')
    expect(text('.params-panel .panel-count')).toContain('phase0')
    await click(playToggle())
    await tick(6)
    const achievedAt = Number(/達成 @s(\d+)/.exec(goalHeading())?.[1])
    expect(achievedAt).toBeGreaterThan(0)
    expect(achievedAt).toBeLessThan(6)
    expect(slot()).toBe(String(achievedAt))

    // Fresh run under merge: the boost keeps the honest block.
    await chooseFromList('A01')
    const presets = container.querySelector('[aria-label="プロトコルプリセット"]')
    await click([...(presets?.querySelectorAll('button') ?? [])].find((b) => b.textContent === 'merge'))
    expect(text('.params-panel .panel-count')).toContain('merge')
    expect(text('.attack-panel')).toContain('前提と異なる（現在 merge）')

    await click(playToggle())
    await tick(6)
    expect(slot()).toBe('6')
    expect(goalHeading()).toContain('判定中')
    expect(goalHeading()).not.toContain('達成')
    expect(playToggle().textContent).toBe('再開')
    expect(playToggle().disabled).toBe(true)
    await tick(2)
    expect(slot()).toBe('6')
  })
})
