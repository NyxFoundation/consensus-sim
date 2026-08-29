// @vitest-environment jsdom
/**
 * Scenario save / reload / replay, driven through the real DOM:
 * saving captures the run's identity (config + interventions + how far it
 * advanced), and reloading reproduces the identical displayed run even
 * after the live scenario has been mutated — determinism made visible.
 */

import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
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
    await click(
      buttonByText('＋1 スロット進める') ?? buttonByText('ここから進める'),
    )
  }
}

/** Click the operating-state button (稼働 / 停止 / オフライン) for a validator. */
async function setOpState(name: string, label: string) {
  const group = container.querySelector(`[aria-label="${name} の稼働状態"]`)
  const btn = [...(group?.querySelectorAll('button') ?? [])].find(
    (b) => b.textContent === label,
  )
  await click(btn)
}

describe('scenario save / reload / replay', () => {
  it('reproduces the saved run identically after the live scenario was mutated', async () => {
    // Build a distinctive run: V1 (ボブ) stopped from slot 1, advanced to slot 3.
    await setOpState('ボブ', '停止')
    await advance(3)
    // Slot 1 is empty (stopped proposer): anchor + blocks at slots 2, 3.
    expect(all('.tree-block')).toHaveLength(3)
    expect(all('.vote-table tbody tr')).toHaveLength(3)

    await click(buttonByText('現在のシナリオを保存'))
    expect(text('.scenario-status')).toContain('保存しました')
    expect(all('.scenario-panel .intervention-list li')).toHaveLength(1)

    // Mutate the live scenario: remove the stop (history rewrites) and advance.
    await click(
      all('.intervention-panel .intervention-list li button').find((b) =>
        b.textContent?.includes('削除'),
      ),
    )
    await advance(2)
    expect(text('.slot-current')).toContain('5')
    expect(all('.tree-block')).toHaveLength(6) // no empty slot anymore

    // Reload: the saved run comes back exactly.
    await click(buttonByText('読込・再実行'))
    expect(text('.scenario-status')).toContain('再実行しました')
    expect(text('.slot-current')).toContain('3')
    expect(all('.tree-block')).toHaveLength(3)
    expect(all('.vote-table tbody tr')).toHaveLength(3)
    // The stop intervention is part of the scenario and is listed again.
    expect(text('.intervention-panel .intervention-list')).toContain('停止 ボブ')
  })

  it('restores the saved validator count', async () => {
    await advance(2)
    await click(buttonByText('現在のシナリオを保存'))

    // Switch to 7 validators (fresh run), then reload the 4-validator save.
    const select = container.querySelector('.field-inline select')
    if (!(select instanceof HTMLSelectElement)) throw new Error('select not found')
    await act(async () => {
      select.value = '7'
      select.dispatchEvent(new Event('change', { bubbles: true }))
    })
    await advance(1)
    expect(all('.vote-table tbody tr')).toHaveLength(7)

    await click(buttonByText('読込・再実行'))
    expect(select.value).toBe('4')
    expect(text('.slot-current')).toContain('2')
    expect(all('.vote-table tbody tr')).toHaveLength(4)
  })

  it('deletes a saved scenario from the list', async () => {
    await click(buttonByText('現在のシナリオを保存'))
    expect(all('.scenario-panel .intervention-list li')).toHaveLength(1)
    await click(
      all('.scenario-panel .intervention-list li button').find((b) =>
        b.textContent?.includes('削除'),
      ),
    )
    expect(all('.scenario-panel .intervention-list li')).toHaveLength(0)
  })
})
