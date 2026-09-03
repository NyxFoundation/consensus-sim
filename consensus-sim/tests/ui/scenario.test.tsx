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
import { listScenarios } from '../../src/ui/scenarioStore'

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

/** Type into a controlled text entry (through the native value setter so
 * React sees the change). */
async function type(el: Element | null, value: string) {
  if (!(el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement)) {
    throw new Error('text entry not found')
  }
  const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'value')?.set
  await act(async () => {
    setter?.call(el, value)
    el.dispatchEvent(new Event('input', { bubbles: true }))
  })
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

describe('scenario name and note (任意: 命名・メモ)', () => {
  const STORE_KEY = 'consensus-sim.scenarios'

  it('saves under a name and a note, lists them, and edits them afterwards', async () => {
    await setOpState('ボブ', '停止')
    await advance(2)
    await type(container.querySelector('.scenario-save-form [aria-label="シナリオ名"]'), 'ボブ停止で finality 遅延')
    await type(
      container.querySelector('.scenario-save-form [aria-label="メモ"]'),
      '停止者 1/4 でも finality が進むことを確かめる',
    )
    await click(buttonByText('現在のシナリオを保存'))
    expect(text('.scenario-status')).toContain('「ボブ停止で finality 遅延」を保存しました')
    expect(text('.scenario-entry .scenario-name')).toBe('ボブ停止で finality 遅延')
    expect(text('.scenario-entry .scenario-note')).toBe('停止者 1/4 でも finality が進むことを確かめる')
    expect(text('.scenario-entry .scenario-summary')).toContain('介入 1 件')
    expect(text('.scenario-entry .scenario-summary')).toContain('スロット 2')
    // The form clears for the next save, and the labels are in the store.
    expect((container.querySelector('.scenario-save-form [aria-label="シナリオ名"]') as HTMLInputElement).value).toBe('')
    expect((container.querySelector('.scenario-save-form [aria-label="メモ"]') as HTMLTextAreaElement).value).toBe('')
    expect(listScenarios()[0]).toMatchObject({
      name: 'ボブ停止で finality 遅延',
      note: '停止者 1/4 でも finality が進むことを確かめる',
    })

    // Edit afterwards: the note records what the run confirmed.
    await click(buttonByText('編集'))
    const edit = container.querySelector('.scenario-edit')
    expect(edit).not.toBeNull()
    expect((edit?.querySelector('[aria-label="シナリオ名"]') as HTMLInputElement).value).toBe('ボブ停止で finality 遅延')
    await type(edit?.querySelector('[aria-label="メモ"]') ?? null, '確認済み: スロット 8 で finalized が e1 に進んだ')
    await click([...(edit?.querySelectorAll('button') ?? [])].find((b) => b.textContent === '保存'))
    expect(container.querySelector('.scenario-edit')).toBeNull()
    expect(text('.scenario-entry .scenario-note')).toBe('確認済み: スロット 8 で finalized が e1 に進んだ')
    expect(text('.scenario-entry .scenario-name')).toBe('ボブ停止で finality 遅延')
    expect(listScenarios()[0]?.note).toBe('確認済み: スロット 8 で finalized が e1 に進んだ')

    // The run itself is untouched: reloading replays it.
    await advance(2)
    expect(text('.slot-current')).toContain('4')
    await click(buttonByText('読込・再実行'))
    expect(text('.slot-current')).toContain('2')
    expect(text('.intervention-panel .intervention-list')).toContain('停止 ボブ')
  })

  it('cancels an edit without changing the entry', async () => {
    await type(container.querySelector('.scenario-save-form [aria-label="シナリオ名"]'), '基準')
    await click(buttonByText('現在のシナリオを保存'))
    await click(buttonByText('編集'))
    await type(container.querySelector('.scenario-edit [aria-label="シナリオ名"]'), '変更中')
    await click([...(container.querySelector('.scenario-edit')?.querySelectorAll('button') ?? [])].find((b) => b.textContent === '取消'))
    expect(container.querySelector('.scenario-edit')).toBeNull()
    expect(text('.scenario-entry .scenario-name')).toBe('基準')
  })

  it('saves without a name or note as before, treats blanks as absent, and ignores malformed stored labels', async () => {
    await type(container.querySelector('.scenario-save-form [aria-label="メモ"]'), '   ')
    await click(buttonByText('現在のシナリオを保存'))
    expect(text('.scenario-status')).toContain('現在のシナリオを保存しました')
    expect(container.querySelector('.scenario-name')).toBeNull()
    expect(container.querySelector('.scenario-note')).toBeNull()
    expect(listScenarios()[0]?.note).toBeUndefined()

    // A record whose labels are not strings (or predate them) still loads, without them.
    const raw = JSON.parse(localStorage.getItem(STORE_KEY) ?? '[]') as Record<string, unknown>[]
    raw[0]!.name = 42
    raw[0]!.note = { text: 'x' }
    localStorage.setItem(STORE_KEY, JSON.stringify(raw))
    const [entry] = listScenarios()
    expect(entry?.name).toBeUndefined()
    expect(entry?.note).toBeUndefined()
    expect(entry?.data.runSlot).toBe(0)
  })
})
