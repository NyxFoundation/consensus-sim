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
      'チェーン表示',
      'ネットワーク表示',
      '全体表示',
    ])
    expect(all('.tree-block')).toHaveLength(1)
  })

  it('advances one block per slot and reflects votes in the table', async () => {
    await advance(4)
    expect(text('.slot-current')).toContain('4')
    expect(all('.tree-block')).toHaveLength(5)
    expect(all('.vote-table tbody tr')).toHaveLength(4)
  })

  it('switches to network and global displays and back', async () => {
    await click(buttonByText('ネットワーク表示'))
    expect(container.querySelector('.network-mode')).not.toBeNull()
    await click(buttonByText('全体表示'))
    expect(container.querySelector('.global-mode')).not.toBeNull()
    await click(buttonByText('チェーン表示'))
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

describe('Chain display overlay (T-019)', () => {
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

async function hover(el: Element | null | undefined) {
  if (!el) throw new Error('hover target not found')
  await act(async () => {
    el.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }))
  })
}

describe('Network mode (T-008)', () => {
  it('shows one card per validator with head / justified / finalized / vote', async () => {
    await advance(9)
    await click(buttonByText('ネットワーク表示'))
    const cards = all('.validator-card')
    expect(cards).toHaveLength(4)
    for (const card of cards) {
      const body = card.textContent ?? ''
      expect(body).toContain('head')
      expect(body).toContain('justified')
      expect(body).toContain('finalized')
      expect(body).toContain('最新投票')
    }
    // Instant delivery: everyone agrees, so no card is flagged as diverged.
    expect(all('.validator-card.diverged')).toHaveLength(0)
  })

  it('shows the hovered validator view as a block tree', async () => {
    await advance(4)
    await click(buttonByText('ネットワーク表示'))
    expect(container.querySelector('.network-hint')).not.toBeNull()
    expect(container.querySelector('.network-detail')).toBeNull()

    const cards = all('.validator-card')
    await hover(cards[2])
    expect(text('.network-detail h3')).toContain('キャロル のビュー')
    // 5 blocks visible in V2's local view at slot 4 (anchor + one per slot).
    expect(all('.network-detail .tree-block')).toHaveLength(5)

    await hover(cards[0])
    expect(text('.network-detail h3')).toContain('アリス のビュー')
  })

  it('reflects the validator count in the card grid', async () => {
    const select = container.querySelector('.field-inline select')
    if (!(select instanceof HTMLSelectElement)) throw new Error('select not found')
    await act(async () => {
      select.value = '7'
      select.dispatchEvent(new Event('change', { bubbles: true }))
    })
    await click(buttonByText('ネットワーク表示'))
    expect(all('.validator-card')).toHaveLength(7)
  })
})

describe('Global mode (T-008)', () => {
  it('shows the chain pane on the left and the network pane on the right', async () => {
    await advance(4)
    await click(buttonByText('全体表示'))
    const panes = all('.global-pane')
    expect(panes).toHaveLength(2)
    expect(panes[0]?.querySelector('.chain-mode')).not.toBeNull()
    expect(panes[0]?.querySelectorAll('.tree-block').length).toBeGreaterThan(0)
    expect(panes[0]?.querySelector('.state-table')).not.toBeNull()
    expect(panes[1]?.querySelectorAll('.validator-card')).toHaveLength(4)
  })

  it('keeps chain interactions working inside the global layout', async () => {
    await advance(4)
    await click(buttonByText('全体表示'))
    // State-table cell expansion works inside the global chain pane.
    const rows = all('.global-pane .state-table tbody tr')
    const cell = rows[2]?.querySelectorAll('td .state-cell')[2]
    await click(cell)
    expect(text('.state-detail h3')).toContain('キャロル の視点')
    const cards = all('.validator-card')
    await hover(cards[1])
    expect(text('.network-detail h3')).toContain('ボブ のビュー')
  })
})
