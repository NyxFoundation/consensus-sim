// @vitest-environment jsdom
/**
 * No-manual operability polish: every panel explains itself in place —
 * empty states carry hints, the message selector stays readable by grouping
 * per publish slot, panel headers summarize their contents and collapse, and
 * the equivocation legend is glossed in Japanese like the rest of the UI.
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
    await click(buttonByText('＋1 スロット進める'))
  }
}

describe('empty states explain the next step', () => {
  it('shows hints for the empty intervention list, scenario list and message log', () => {
    expect(text('.intervention-panel .empty-hint')).toContain(
      '介入はまだありません',
    )
    expect(text('.scenario-panel .empty-hint')).toContain(
      '保存されたシナリオはまだありません',
    )
    const select = container.querySelector(
      'select[aria-label="対象メッセージ"]',
    ) as HTMLSelectElement
    expect(select.disabled).toBe(true)
    expect(text('.intervention-panel')).toContain('メッセージはまだありません')
  })

  it('replaces the empty hints once content exists', async () => {
    const group = all('.intervention-group').find((g) =>
      g.querySelector('legend')?.textContent?.includes('分断'),
    )
    await click(group?.querySelectorAll('input[type="checkbox"]')[0])
    await click(buttonByText('選択集合を残りから分断'))
    expect(container.querySelector('.intervention-panel .empty-hint')).toBeNull()
    expect(text('.intervention-panel .intervention-list')).toContain('分断')

    await click(buttonByText('現在のシナリオを保存'))
    expect(container.querySelector('.scenario-panel .empty-hint')).toBeNull()
    expect(all('.scenario-panel .intervention-list li')).toHaveLength(1)
  })
})

describe('message selector grouped by publish slot', () => {
  it('groups messages per slot, newest slot first, and stays selectable', async () => {
    await advance(2)
    const select = container.querySelector(
      'select[aria-label="対象メッセージ"]',
    ) as HTMLSelectElement
    expect(select.disabled).toBe(false)
    const labels = [...select.querySelectorAll('optgroup')].map(
      (g) => (g as HTMLOptGroupElement).label,
    )
    expect(labels).toEqual(['発行スロット s2', '発行スロット s1'])
    // Each slot contributes its proposal plus one vote per validator (4).
    const perGroup = [...select.querySelectorAll('optgroup')].map(
      (g) => g.querySelectorAll('option').length,
    )
    expect(perGroup).toEqual([5, 5])

    await act(async () => {
      select.value = 'block:1'
      select.dispatchEvent(new Event('change', { bubbles: true }))
    })
    await click(buttonByText('適用'))
    expect(text('.intervention-list')).toContain('欠落 ブロック B1')
  })
})

describe('panel headers summarize and collapse', () => {
  it('summarizes scheduled interventions and saved scenarios in the summary line', async () => {
    await advance(1)
    const group = all('.intervention-group').find((g) =>
      g.querySelector('legend')?.textContent?.includes('分断'),
    )
    await click(group?.querySelectorAll('input[type="checkbox"]')[0])
    await click(buttonByText('選択集合を残りから分断'))
    expect(text('.intervention-panel .panel-summary')).toContain('1 件指定中')

    await click(buttonByText('現在のシナリオを保存'))
    expect(text('.scenario-panel .panel-summary')).toContain('保存 1 件')
  })

  it('keeps both panels open by default and collapsible via <details>', () => {
    const details = all('.intervention-panel details, .scenario-panel details')
    expect(details).toHaveLength(2)
    for (const d of details) {
      expect((d as HTMLDetailsElement).open).toBe(true)
      expect(d.querySelector('summary.panel-summary')).not.toBeNull()
    }
  })
})

describe('equivocation legend is glossed in Japanese', () => {
  it('labels the equivocation group with 二重提案・二重投票', () => {
    const legends = all('.intervention-group legend').map(
      (l) => l.textContent ?? '',
    )
    expect(
      legends.some((t) => t.includes('equivocation') && t.includes('二重提案・二重投票')),
    ).toBe(true)
  })
})
