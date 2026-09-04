// @vitest-environment jsdom
/**
 * Type catalog page (型一覧), driven through the real DOM: the page renders
 * the domain types as a layered dependency graph with one type always in
 * focus (成功条件 2: the first type of the top layer when the page opens),
 * and the focus pane shows the verbatim implementation declaration — doc
 * comment included — with its dependency links.
 */

import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { App } from '../../src/ui/App'
import { DOMAIN_SOURCES } from '../../src/ui/domainSources'

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

function nodeButton(name: string): Element | undefined {
  return all('.type-node').find(
    (b) => b.querySelector('.type-node-name')?.textContent === name,
  )
}

function nodeName(el: Element | undefined): string | undefined {
  return el?.querySelector('.type-node-name')?.textContent ?? undefined
}

function offset(el: Element | undefined, prop: 'top' | 'left'): number {
  return Number.parseInt((el as HTMLElement).style[prop], 10)
}

describe('type catalog page', () => {
  it('renders the domain types as a graph with edges', async () => {
    await click(buttonByText('型一覧'))
    const names = all('.type-node .type-node-name').map((n) => n.textContent)
    for (const expected of ['ValidatorIndex', 'Block', 'Vote', 'View', 'ChainState', 'ProtocolParams']) {
      expect(names).toContain(expected)
    }
    // The sim module's constraint types are not part of the catalog.
    for (const absent of ['Scenario', 'Intervention', 'SimulationState', 'Delivery']) {
      expect(names).not.toContain(absent)
    }
    expect(all('.type-edge').length).toBeGreaterThan(0)
    // The caption is an on-demand hint: its explanation lives in data-hint.
    expect(container.querySelector('.types-caption')?.getAttribute('data-hint')).toContain(
      '本質的仕様モジュール',
    )
  })

  it('places no-dependency index types on the top row', async () => {
    await click(buttonByText('型一覧'))
    const top = (name: string) => offset(nodeButton(name), 'top')
    // Layer 0 (the smallest top offset in the graph) holds the primitives.
    const minTop = Math.min(...all('.type-node').map((b) => offset(b, 'top')))
    expect(top('ValidatorIndex')).toBe(minTop)
    expect(top('SlotIndex')).toBe(minTop)
    // Vote depends on the primitives, so it sits strictly lower.
    expect(top('Vote')).toBeGreaterThan(minTop)
  })

  it('has its own layout: header bar only, graph pane beside the focus pane', async () => {
    await click(buttonByText('型一覧'))
    const page = container.querySelector('.types-page')
    expect(page).not.toBeNull()
    // No slot bar, no operation dock, no validator count (必須 8).
    expect(container.querySelector('.slot-bar')).toBeNull()
    expect(container.querySelector('.dock')).toBeNull()
    expect(container.querySelector('.field-inline')).toBeNull()
    expect(container.querySelector('.mode-tabs')).not.toBeNull()
    expect(container.querySelector('.theme-toggle')).not.toBeNull()
    // Two panes, graph first then the focused type.
    expect(page?.children).toHaveLength(2)
    expect(page?.children[0]?.classList.contains('types-graph-pane')).toBe(true)
    expect(page?.children[1]?.classList.contains('type-detail')).toBe(true)
  })

  it('opens with the first type of the top layer in focus', async () => {
    await click(buttonByText('型一覧'))
    const nodes = all('.type-node')
    const minTop = Math.min(...nodes.map((b) => offset(b, 'top')))
    const topRow = nodes.filter((b) => offset(b, 'top') === minTop)
    const first = topRow.reduce((a, b) => (offset(b, 'left') < offset(a, 'left') ? b : a))
    const active = all('.type-node.active')
    expect(active).toHaveLength(1)
    expect(nodeName(active[0])).toBe(nodeName(first))
    expect(container.querySelector('.type-detail h3')?.textContent).toContain(nodeName(first))
    expect(container.querySelector('.type-source')?.textContent).toContain(nodeName(first))
  })

  it('moves the focus to the selected node and never leaves it empty', async () => {
    await click(buttonByText('型一覧'))
    await click(nodeButton('Vote'))
    expect(container.querySelector('.type-detail h3')?.textContent).toContain('Vote')
    expect(nodeName(all('.type-node.active')[0])).toBe('Vote')
    // Selecting the focused node again keeps it in focus.
    await click(nodeButton('Vote'))
    expect(all('.type-node.active')).toHaveLength(1)
    expect(container.querySelector('.type-detail')).not.toBeNull()
  })

  it('shows the verbatim implementation declaration with its comment on selection', async () => {
    await click(buttonByText('型一覧'))
    await click(nodeButton('Vote'))
    const source = container.querySelector('.type-source')?.textContent ?? ''
    expect(source).toContain('export interface Vote')
    expect(source.trimStart().startsWith('/**')).toBe(true)
    expect(DOMAIN_SOURCES['types'] ?? '').toContain(source.trim())
    // Dependency links navigate the focus to the linked type.
    const detail = container.querySelector('.type-detail')
    expect(detail?.textContent).toContain('依存する型')
    expect(detail?.textContent).toContain('この型に依存する型')
    const link = [...(detail?.querySelectorAll('.type-link') ?? [])].find(
      (b) => b.textContent === 'ValidatorIndex',
    )
    await click(link)
    expect(container.querySelector('.type-detail h3')?.textContent).toContain(
      'ValidatorIndex',
    )
    expect(nodeName(all('.type-node.active')[0])).toBe('ValidatorIndex')
  })
})
