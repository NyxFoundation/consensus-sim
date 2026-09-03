// @vitest-environment jsdom
/**
 * Machine check for "no resident explanation" (成功条件 26 (c)): every
 * panel carries controls, labels and readouts only; supplementary prose is
 * an on-demand ⓘ hint (src/ui/components/Hint) whose text lives in the
 * data-hint attribute and is never a text node. The check renders the app,
 * drives it through the displays and the typical interactions, and asserts
 * over the rendered text nodes: no sentence (no 。), no legacy note element,
 * and every hint holds its text in attributes only.
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

/** Every non-blank text node under the app, with the path to its element. */
function textNodes(scope: Element): { text: string; where: string }[] {
  const out: { text: string; where: string }[] = []
  const walker = document.createTreeWalker(scope, NodeFilter.SHOW_TEXT)
  for (let n = walker.nextNode(); n; n = walker.nextNode()) {
    const text = n.textContent?.trim() ?? ''
    if (text === '') continue
    const el = n.parentElement
    const where = el
      ? `${el.tagName.toLowerCase()}${el.className ? `.${String(el.className).split(' ').join('.')}` : ''}`
      : '?'
    out.push({ text, where })
  }
  return out
}

/** The classes the pre-refresh UI used for resident notes: none may remain. */
const LEGACY_NOTE_CLASSES = ['intervention-note', 'pane-note', 'types-caption p', 'network-hint p']

function expectNoResidentProse(label: string) {
  const sentences = textNodes(container).filter((t) => t.text.includes('。'))
  expect(
    sentences,
    `${label}: sentence(s) rendered as resident text:\n${sentences
      .map((s) => `${s.where}: ${s.text}`)
      .join('\n')}`,
  ).toEqual([])
  for (const cls of LEGACY_NOTE_CLASSES) {
    expect(container.querySelector(`.${cls}`), `${label}: legacy note .${cls}`).toBeNull()
  }
  // Every hint holds its explanation in attributes, never as a text node.
  for (const hint of all('[data-ui="hint"]')) {
    const text = hint.getAttribute('data-hint') ?? ''
    expect(text.length, `${label}: empty hint`).toBeGreaterThan(0)
    expect(hint.getAttribute('aria-label')).toBe(text)
    expect(hint.textContent?.trim()).toBe('ⓘ')
  }
}

describe('no resident explanation: prose lives only in on-demand hints', () => {
  it('holds at the initial display', () => {
    expectNoResidentProse('initial')
    // The dock and the stage both carry hints — the explanation moved, it
    // did not vanish.
    expect(all('.dock [data-ui="hint"]').length).toBeGreaterThan(5)
    expect(all('.stage [data-ui="hint"]').length).toBeGreaterThan(0)
  })

  it('holds after advancing, expanding a cell and scheduling interventions', async () => {
    await advance(5)
    expectNoResidentProse('after advancing')

    const cell = all('.chain-mode .state-table tbody tr')[1]?.querySelectorAll('td .state-cell')[3]
    await click(cell)
    expect(container.querySelector('.state-detail')).not.toBeNull()
    expectNoResidentProse('with a cell expanded')

    const group = all('.intervention-group').find((g) =>
      g.querySelector('legend')?.textContent?.includes('分断'),
    )
    await click(group?.querySelectorAll('input[type="checkbox"]')[0])
    await click(buttonByText('選択集合を残りから分断'))
    await click(buttonByText('現在のシナリオを保存'))
    expectNoResidentProse('with an intervention and a saved scenario')
  })

  it('holds on the type catalog page', async () => {
    await advance(3)
    await click(buttonByText('型一覧'))
    expectNoResidentProse('types')
    await click(all('.type-node')[3])
    expectNoResidentProse('types with a selection')
  })
})

describe('a hint shows its explanation only on demand', () => {
  it('renders the tooltip while hovered or focused and removes it after', async () => {
    const hint = all('.dock [data-ui="hint"]')[0]
    if (!hint) throw new Error('no hint in the dock')
    expect(document.querySelector('.hint-tooltip')).toBeNull()
    await act(async () => {
      hint.dispatchEvent(new MouseEvent('mouseenter', { bubbles: false }))
    })
    // React attaches mouseenter through mouseover on the root.
    await act(async () => {
      hint.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }))
    })
    const tooltip = document.querySelector('.hint-tooltip')
    expect(tooltip?.textContent).toBe(hint.getAttribute('data-hint'))
    await act(async () => {
      hint.dispatchEvent(new MouseEvent('mouseout', { bubbles: true }))
    })
    expect(document.querySelector('.hint-tooltip')).toBeNull()

    await act(async () => {
      ;(hint as HTMLElement).focus()
    })
    expect(document.querySelector('.hint-tooltip')).not.toBeNull()
    await act(async () => {
      ;(hint as HTMLElement).blur()
    })
    expect(document.querySelector('.hint-tooltip')).toBeNull()
  })
})

describe('the dock summarizes rather than explains', () => {
  it('each dock section opens with a one-line summary: title, count readout, hint', () => {
    for (const section of ['.params-panel', '.intervention-panel', '.scenario-panel']) {
      const summary = container.querySelector(`${section} summary .panel-title`)
      expect(summary, `${section} has no titled summary`).not.toBeNull()
      expect(summary?.querySelector('[data-ui="hint"]')).not.toBeNull()
    }
    expect(container.querySelector('.params-panel .panel-count')?.textContent).toContain('merge')
  })
})
