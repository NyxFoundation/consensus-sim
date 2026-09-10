// @vitest-environment jsdom
/**
 * Keyboard shortcuts (任意: 介入・シナリオ操作のキーボードショートカット),
 * driven through the real DOM: the slot bar's operations — N advances,
 * ← / → move the cursor, Home / End jump, Space starts and pauses
 * auto-play — and the scenario panel's S saves; none fires while a text
 * entry has the focus, while a modifier is held, or (for Space) on a focused
 * button; none fires on the other pages; and the bound buttons announce
 * their key.
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

async function press(key: string, init: KeyboardEventInit = {}, target: EventTarget = window) {
  await act(async () => {
    target.dispatchEvent(
      new KeyboardEvent('keydown', { key, bubbles: true, cancelable: true, ...init }),
    )
  })
}

async function tick(times: number) {
  for (let i = 0; i < times; i++) {
    await act(async () => {
      vi.advanceTimersByTime(PLAY_INTERVAL_MS)
    })
  }
}

const slot = () => text('.slot-current strong')
const playToggle = () => container.querySelector('.play-toggle') as HTMLButtonElement

describe('keyboard shortcuts on the chain display', () => {
  it('N advances; ← → move the cursor; Home / End jump to the first / latest slot', async () => {
    await press('n')
    await press('N')
    expect(slot()).toBe('2')
    expect(all('.tree-block')).toHaveLength(3)

    await press('ArrowLeft')
    expect(slot()).toBe('1')
    expect(text('.slot-current')).toContain('最新 2')
    await press('ArrowLeft')
    await press('ArrowLeft')
    expect(slot()).toBe('0')

    await press('End')
    expect(slot()).toBe('2')
    await press('ArrowRight')
    expect(slot()).toBe('2')
    await press('Home')
    expect(slot()).toBe('0')
    await press('ArrowRight')
    expect(slot()).toBe('1')
  })

  it('Space starts and pauses auto-play', async () => {
    await press(' ')
    expect(playToggle().textContent).toBe('一時停止')
    await tick(2)
    expect(slot()).toBe('2')
    await press(' ')
    expect(playToggle().textContent).toBe('自動再生')
    await tick(2)
    expect(slot()).toBe('2')
  })

  it('S saves the current scenario', async () => {
    await press('n')
    await press('s')
    expect(all('.scenario-panel .intervention-list li')).toHaveLength(1)
    expect(text('.scenario-status')).toContain('保存しました')
    expect(text('.scenario-entry .scenario-summary')).toContain('スロット 1')
  })

  it('stays quiet in a text entry, with a modifier held, and on a focused button for Space', async () => {
    const name = container.querySelector('[aria-label="シナリオ名"]')
    if (!name) throw new Error('scenario name field not found')
    await press('n', {}, name)
    await press('s', {}, name)
    expect(slot()).toBe('0')
    expect(all('.scenario-panel .intervention-list li')).toHaveLength(0)

    await press('n', { metaKey: true })
    await press('n', { ctrlKey: true })
    await press('n', { altKey: true })
    expect(slot()).toBe('0')

    const advance = buttonByText('＋1 スロット進める')
    if (!advance) throw new Error('advance button not found')
    await press(' ', {}, advance)
    expect(playToggle().textContent).toBe('自動再生')
    // Keys a button does not activate natively still work from it.
    await press('n', {}, advance)
    expect(slot()).toBe('1')
    await press('ArrowLeft', {}, advance)
    expect(slot()).toBe('0')
  })

  it('is inactive on the attack list and type catalog pages', async () => {
    await press('n')
    await click(buttonByText('型一覧'))
    await press('n')
    await press('s')
    await click(buttonByText('攻撃一覧'))
    await press('n')
    await click(buttonByText('チェーン表示'))
    expect(slot()).toBe('1')
    expect(all('.scenario-panel .intervention-list li')).toHaveLength(0)
  })

  it('announces the keys on the bound buttons and lists them in the slot bar hint', async () => {
    expect(buttonByText('＋1 スロット進める')?.getAttribute('aria-keyshortcuts')).toBe('N')
    expect(playToggle().getAttribute('aria-keyshortcuts')).toBe('Space')
    expect(container.querySelector('[aria-label="1 スロット戻る"]')?.getAttribute('aria-keyshortcuts')).toBe('ArrowLeft')
    expect(container.querySelector('[aria-label="1 スロット先へ"]')?.getAttribute('aria-keyshortcuts')).toBe('ArrowRight')
    expect(buttonByText('現在のシナリオを保存')?.getAttribute('aria-keyshortcuts')).toBe('S')
    await press('n')
    await press('ArrowLeft')
    expect(buttonByText('最新へ')?.getAttribute('aria-keyshortcuts')).toBe('End')
    const hint = container.querySelector('.slot-bar .shortcut-hint')?.getAttribute('data-hint') ?? ''
    for (const key of ['←', '→', 'Home', 'End', 'Space', 'N', 'S']) expect(hint).toContain(key)
  })
})
