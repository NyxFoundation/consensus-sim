// @vitest-environment jsdom
/**
 * Shell behaviour, driven through the real DOM: slot advancing, the three
 * display tabs, and the chain display's always-overlaid tree — the same
 * interactions a user performs, minus the pixels.
 */

import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { validatorName } from '../../src/domain'
import { App } from '../../src/ui/App'

declare global {
  var IS_REACT_ACT_ENVIRONMENT: boolean
}
globalThis.IS_REACT_ACT_ENVIRONMENT = true

let container: HTMLDivElement
let root: Root

beforeEach(async () => {
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
  for (let i = 0; i < times; i++) await click(buttonByText('＋1 スロット進める'))
}

describe('App shell', () => {
  it('starts at slot 0 with the anchor block only and the three page tabs', () => {
    expect(text('h1')).toBe('consensus-sim')
    expect(text('.slot-current')).toContain('0')
    expect(all('.mode-tabs button').map((b) => b.textContent)).toEqual([
      'チェーン表示',
      '攻撃一覧',
      '型一覧',
    ])
    expect(all('.tree-block')).toHaveLength(1)
  })

  it('advances one block per slot and reflects votes in the table', async () => {
    await advance(4)
    expect(text('.slot-current')).toContain('4')
    expect(all('.tree-block')).toHaveLength(5)
    expect(all('.vote-table tbody tr')).toHaveLength(4)
  })

  it('switches to the type catalog page and back without losing the run', async () => {
    await advance(2)
    await click(buttonByText('型一覧'))
    expect(container.querySelector('.types-page')).not.toBeNull()
    // The catalog page has its own layout: no slot bar, no dock, no
    // validator count — only the header bar frames it (必須 8).
    expect(container.querySelector('.slot-bar')).toBeNull()
    expect(container.querySelector('.dock')).toBeNull()
    expect(container.querySelector('.field-inline select')).toBeNull()
    expect(container.querySelector('.theme-toggle')).not.toBeNull()
    await click(buttonByText('チェーン表示'))
    expect(text('.slot-current')).toContain('2')
    expect(all('.tree-block')).toHaveLength(3)
    expect(container.querySelector('.dock')).not.toBeNull()
  })

  it('resets to slot 0 when the validator count changes', async () => {
    await advance(3)
    const select = container.querySelector('.field-inline select')
    if (!(select instanceof HTMLSelectElement)) throw new Error('select not found')
    await act(async () => {
      select.value = '7'
      select.dispatchEvent(new Event('change', { bubbles: true }))
    })
    expect(text('.slot-current')).toContain('0')
    // Advance once: slot 1's proposer under 7 validators is V1 of 7.
    await advance(1)
    expect(all('.vote-table tbody tr')).toHaveLength(7)
  })
})

describe('Chain display overlay', () => {
  it('always overlays every validator head with no perspective toggle', async () => {
    await advance(4)
    const status = text('.status-list')
    for (const v of [0, 1, 2, 3]) expect(status).toContain(`${validatorName(v)}:`)
    expect(buttonByText('神視点')).toBeUndefined()
    expect(buttonByText('局所視点')).toBeUndefined()
  })

  it('marks justified and finalized checkpoints with badges as epochs pass', async () => {
    await advance(9)
    // Slot 9: finalized = B4, so the anchor and B4 both carry F (成功条件 8);
    // the justified frontier B8 stays J.
    expect(all('.badge-finalized')).toHaveLength(2)
    expect(all('.badge-justified').length).toBeGreaterThan(0)
    expect(text('.status-list')).toContain('finalized')
  })
})
