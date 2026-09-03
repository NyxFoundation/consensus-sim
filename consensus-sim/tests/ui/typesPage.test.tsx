// @vitest-environment jsdom
/**
 * Type catalog page (型一覧), driven through the real DOM: the tab
 * renders the domain types as a layered dependency graph, and selecting a
 * node shows the verbatim implementation declaration with its dependency
 * links.
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
    const top = (name: string) =>
      Number.parseInt((nodeButton(name) as HTMLElement).style.top, 10)
    // Layer 0 (the smallest top offset in the graph) holds the primitives.
    const minTop = Math.min(
      ...all('.type-node').map((b) => Number.parseInt((b as HTMLElement).style.top, 10)),
    )
    expect(top('ValidatorIndex')).toBe(minTop)
    expect(top('SlotIndex')).toBe(minTop)
    // Vote depends on the primitives, so it sits strictly lower.
    expect(top('Vote')).toBeGreaterThan(minTop)
  })

  it('shows the verbatim implementation declaration on selection', async () => {
    await click(buttonByText('型一覧'))
    await click(nodeButton('Vote'))
    const source = container.querySelector('.type-source')?.textContent ?? ''
    expect(source).toContain('export interface Vote')
    expect(DOMAIN_SOURCES['types'] ?? '').toContain(source.trim())
    // Dependency links navigate the detail to the linked type.
    const detail = container.querySelector('.type-detail')
    expect(detail?.textContent).toContain('依存する型')
    const link = [...(detail?.querySelectorAll('.type-link') ?? [])].find(
      (b) => b.textContent === 'ValidatorIndex',
    )
    await click(link)
    expect(container.querySelector('.type-detail h3')?.textContent).toContain(
      'ValidatorIndex',
    )
  })
})
