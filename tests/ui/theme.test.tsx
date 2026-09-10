// @vitest-environment jsdom
/**
 * Theme selection, driven through the real DOM: system is the default and
 * writes no data-theme attribute (the OS media query in tokens.css carries
 * it), choosing an explicit mode sets data-theme and persists it, a reload
 * reads the persisted mode back, and system mode resolves to the OS
 * preference when it is queried.
 */

import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { App } from '../../src/ui/App'
import { useThemeMode } from '../../src/ui/useTheme'

declare global {
  var IS_REACT_ACT_ENVIRONMENT: boolean
}
globalThis.IS_REACT_ACT_ENVIRONMENT = true

const STORAGE_KEY = 'consensus-sim.theme'

let container: HTMLDivElement
let root: Root

beforeEach(() => {
  localStorage.clear()
  document.documentElement.removeAttribute('data-theme')
  container = document.createElement('div')
  document.body.appendChild(container)
})

afterEach(async () => {
  if (root) {
    await act(async () => {
      root.unmount()
    })
  }
  container.remove()
  document.documentElement.removeAttribute('data-theme')
  delete (window as { matchMedia?: unknown }).matchMedia
})

async function renderApp() {
  root = createRoot(container)
  await act(async () => {
    root.render(<App />)
  })
}

function all(selector: string): Element[] {
  return [...container.querySelectorAll(selector)]
}

function themeGroup(): Element | null {
  return container.querySelector('[role="group"][aria-label="テーマ"]')
}

function themeButton(label: string): Element | undefined {
  return [...(themeGroup()?.querySelectorAll('button') ?? [])].find(
    (b) => b.textContent === label,
  )
}

async function click(el: Element | null | undefined) {
  if (!el) throw new Error('click target not found')
  await act(async () => {
    el.dispatchEvent(new MouseEvent('click', { bubbles: true }))
  })
}

describe('theme selection', () => {
  it('defaults to system mode and writes no data-theme attribute', async () => {
    await renderApp()
    expect(document.documentElement.hasAttribute('data-theme')).toBe(false)
    expect(themeButton('自動')?.getAttribute('aria-pressed')).toBe('true')
  })

  it('choosing ライト sets data-theme="light" and persists it', async () => {
    await renderApp()
    await click(themeButton('ライト'))
    expect(document.documentElement.dataset['theme']).toBe('light')
    expect(localStorage.getItem(STORAGE_KEY)).toBe('light')
    expect(themeButton('ライト')?.getAttribute('aria-pressed')).toBe('true')
  })

  it('a reload reads the persisted mode back', async () => {
    await renderApp()
    await click(themeButton('ダーク'))
    expect(document.documentElement.dataset['theme']).toBe('dark')

    // Simulate a reload: unmount, drop the attribute a fresh load would not
    // carry over, and mount a brand new tree from scratch.
    await act(async () => {
      root.unmount()
    })
    document.documentElement.removeAttribute('data-theme')
    await renderApp()

    expect(document.documentElement.dataset['theme']).toBe('dark')
    expect(themeButton('ダーク')?.getAttribute('aria-pressed')).toBe('true')
  })

  it('cycles system → light → dark → system', async () => {
    await renderApp()
    const cycleButton = () => all('button').find((b) => b.textContent === '自動')
    // The 自動 option itself doubles as the cycle entry point in the group;
    // exercise the full cycle through explicit selections instead, which is
    // the control the UI actually exposes.
    await click(themeButton('ライト'))
    expect(document.documentElement.dataset['theme']).toBe('light')
    await click(themeButton('ダーク'))
    expect(document.documentElement.dataset['theme']).toBe('dark')
    await click(themeButton('自動'))
    expect(document.documentElement.hasAttribute('data-theme')).toBe(false)
    expect(cycleButton()).toBeDefined()
  })
})

describe('useThemeMode resolution', () => {
  function mockMatchMedia(matchesDark: boolean) {
    ;(window as unknown as { matchMedia: typeof window.matchMedia }).matchMedia = ((
      query: string,
    ) => ({
      matches: query.includes('dark') && matchesDark,
      media: query,
      onchange: null,
      addEventListener: () => {},
      removeEventListener: () => {},
      addListener: () => {},
      removeListener: () => {},
      dispatchEvent: () => false,
    })) as unknown as typeof window.matchMedia
  }

  function Probe() {
    const theme = useThemeMode()
    return <span data-testid="resolved">{theme.resolved}</span>
  }

  it('resolves to dark in system mode when the OS prefers dark', async () => {
    mockMatchMedia(true)
    root = createRoot(container)
    await act(async () => {
      root.render(<Probe />)
    })
    expect(container.querySelector('[data-testid="resolved"]')?.textContent).toBe('dark')
  })

  it('resolves to light in system mode when the OS prefers light', async () => {
    mockMatchMedia(false)
    root = createRoot(container)
    await act(async () => {
      root.render(<Probe />)
    })
    expect(container.querySelector('[data-testid="resolved"]')?.textContent).toBe('light')
  })
})
