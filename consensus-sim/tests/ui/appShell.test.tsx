// @vitest-environment jsdom
/**
 * Shell behaviour, driven through the real DOM: slot advancing, the three
 * mode tabs, and chain mode's local/god perspective switching — the same
 * interactions a user performs, minus the pixels.
 */

import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { App } from '../../src/ui/App'

declare global {
  // eslint-disable-next-line no-var
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

describe('App shell (T-006)', () => {
  it('starts at slot 0 with the anchor block only and three mode tabs', () => {
    expect(text('h1')).toBe('consensus-sim')
    expect(text('.slot-current')).toContain('0')
    expect(all('.mode-tabs button').map((b) => b.textContent)).toEqual([
      'チェーンモード',
      'ネットワークモード',
      '全体モード',
    ])
    expect(all('.tree-block')).toHaveLength(1)
  })

  it('advances one block per slot and reflects votes in the table', async () => {
    await advance(4)
    expect(text('.slot-current')).toContain('4')
    expect(all('.tree-block')).toHaveLength(5)
    expect(all('.vote-table tbody tr')).toHaveLength(4)
  })

  it('switches to network and global modes and back', async () => {
    await click(buttonByText('ネットワークモード'))
    expect(text('.mode-placeholder h2')).toContain('ネットワーク')
    await click(buttonByText('全体モード'))
    expect(text('.mode-placeholder h2')).toContain('全体')
    await click(buttonByText('チェーンモード'))
    expect(all('.tree-block').length).toBeGreaterThan(0)
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

describe('Chain mode perspectives (T-007)', () => {
  it('shows the selected validator local state and switches validators', async () => {
    await advance(4)
    expect(text('.panel h3')).toContain('V0 の局所状態')
    await click(buttonByText('V2'))
    expect(text('.panel h3')).toContain('V2 の局所状態')
    expect(text('.status-list')).toContain('head')
  })

  it('shows every validator head in the god perspective', async () => {
    await advance(4)
    await click(buttonByText('神視点'))
    const status = text('.status-list')
    for (const v of [0, 1, 2, 3]) expect(status).toContain(`V${v}:`)
  })

  it('marks justified and finalized checkpoints with badges as epochs pass', async () => {
    await advance(9)
    expect(all('.badge-finalized')).toHaveLength(1)
    expect(all('.badge-justified').length).toBeGreaterThan(0)
    expect(text('.status-list')).toContain('finalized')
  })
})
