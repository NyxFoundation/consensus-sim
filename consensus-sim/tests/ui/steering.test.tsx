// @vitest-environment jsdom
/**
 * Vote designation, omitted inclusion and the receiver set of a delay /
 * drop, driven through the real DOM (成功条件 5 (d)(f)(g)): each is
 * specified at the slot boundary from the panel and its result is read off
 * the next slot's vote table / block body.
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

async function select(label: string, value: string) {
  const el = container.querySelector(`select[aria-label="${label}"]`)
  if (!(el instanceof HTMLSelectElement)) throw new Error(`select ${label} not found`)
  await act(async () => {
    el.value = value
    el.dispatchEvent(new Event('change', { bubbles: true }))
  })
}

/** Select the option whose visible label starts with `textPrefix` — the
 * option's value is an internal key not asserted on here. */
async function selectByLabel(label: string, textPrefix: string) {
  const el = container.querySelector(`select[aria-label="${label}"]`)
  if (!(el instanceof HTMLSelectElement)) throw new Error(`select ${label} not found`)
  const option = [...el.querySelectorAll('option')].find((o) =>
    o.textContent?.startsWith(textPrefix),
  ) as HTMLOptionElement | undefined
  if (!option) throw new Error(`option starting with ${textPrefix} not found in ${label}`)
  await act(async () => {
    el.value = option.value
    el.dispatchEvent(new Event('change', { bubbles: true }))
  })
}

/** Rows of the chain display's vote table as [validator, slot, head]. */
function voteRows(): string[][] {
  return all('.chain-mode .panel-row .vote-table tbody tr').map((r) =>
    [...r.querySelectorAll('td')].slice(0, 3).map((td) => td.textContent?.trim() ?? ''),
  )
}

function cell(v: number, s: number): Element | undefined {
  return all('.chain-mode .state-table tbody tr')[v]?.querySelectorAll('td .state-cell')[s]
}

describe('vote designation (投票先指定)', () => {
  it('steers the chosen validator\'s next vote to a block of its own view', async () => {
    await advance(3)
    await select('投票先を指定するバリデータ', '1')
    // ボブ's view at slot 3 offers B0..B3.
    const heads = [
      ...(container.querySelector('select[aria-label="投票の head"]') as HTMLSelectElement).options,
    ]
    expect(heads.map((o) => o.value)).toEqual(['', '0', '1', '2', '3'])
    await select('投票の head', '1')
    await click(buttonByText('投票先を指定'))
    expect(text('.intervention-list')).toContain('投票先指定 ボブ @ s4（head B1）')
    expect((buttonByText('投票先を指定済み') as HTMLButtonElement).disabled).toBe(true)

    await advance(1)
    const rows = voteRows()
    expect(rows.find((r) => r[0]?.includes('ボブ'))?.slice(1)).toEqual(['4', 'B1'])
    expect(rows.find((r) => r[0]?.includes('アリス'))?.slice(1)).toEqual(['4', 'B4'])
  })

  it('requires at least one component', async () => {
    await advance(1)
    expect((buttonByText('投票先を指定') as HTMLButtonElement).disabled).toBe(true)
    await select('投票の target', '0')
    expect((buttonByText('投票先を指定') as HTMLButtonElement).disabled).toBe(false)
  })
})

describe('omitted inclusion (取り込みの省略)', () => {
  it('keeps the chosen vote out of the next block, and a later block includes it', async () => {
    await advance(2)
    // Next slot 3 is proposed by デイブ; its candidates are the four slot-2 votes.
    expect(text('.intervention-panel')).toContain('s3 の提案者 デイブ が B2 上の提案で省く項目')
    const boxes = all('input[aria-label^="省略候補: "]')
    expect(boxes).toHaveLength(4)
    expect((buttonByText('次の提案で省略') as HTMLButtonElement).disabled).toBe(true)
    await click(container.querySelector('input[aria-label="省略候補: アリス の投票（s2, head B2）"]'))
    await click(buttonByText('次の提案で省略'))
    expect(text('.intervention-list')).toContain(
      '取り込み省略 @ s3（提案者 デイブ）: 投票 1 件・証拠 0 件',
    )

    await advance(1)
    await click(cell(3, 3))
    let body = text('.state-detail .block-body')
    expect(body).toContain('3 件')
    expect(body).not.toContain('アリス')
    // Slot 4's candidates include the left-out vote again, and B4 carries it.
    expect(text('.intervention-panel')).toContain('アリス の投票（s2, head B2）')
    await advance(1)
    await click(cell(0, 4))
    body = text('.state-detail .block-body')
    expect(body).toContain('5 件')
    expect(body).toContain('アリス B2@s2')
  })

  it('offers included equivocation evidence as a candidate', async () => {
    await advance(1)
    await select('二重投票するバリデータ', '1')
    await click(buttonByText('次スロットで二重投票'))
    await advance(1)
    const evidenceBox = container.querySelector('input[aria-label^="省略候補: 二重投票 ボブ @2"]')
    expect(evidenceBox).not.toBeNull()
    await click(evidenceBox)
    await click(buttonByText('次の提案で省略'))
    expect(text('.intervention-list')).toContain('投票 0 件・証拠 1 件')
    await advance(1)
    await click(cell(0, 3))
    expect(text('.state-detail .block-body')).toContain('証拠なし')
  })
})

describe('receiver set of a delay / drop (受信者集合)', () => {
  it('scopes a drop to the chosen observers', async () => {
    await advance(1)
    await selectByLabel('対象メッセージ', 'ブロック B1')
    // The message fieldset's 対象 checkboxes carry the validator names; pick ボブ.
    const group = all('.intervention-group').find((g) =>
      g.querySelector('legend')?.textContent?.includes('メッセージの遅延・欠落'),
    )
    const bob = [...(group?.querySelectorAll('input[type="checkbox"]') ?? [])].find((b) =>
      b.parentElement?.textContent?.includes('ボブ'),
    )
    await click(bob)
    await click(buttonByText('適用'))
    expect(text('.intervention-list')).toContain('欠落 ブロック B1（対象: ボブ）')
  })
})
