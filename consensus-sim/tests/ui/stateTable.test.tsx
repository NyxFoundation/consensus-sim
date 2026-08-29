// @vitest-environment jsdom
/**
 * State table, driven through the real DOM: one row per validator
 * and one column per slot aligned with the chain display, dynamic selection
 * of the cell item, difference highlighting that shows divergence during a
 * partition and reconvergence after healing (成功条件 3・4), and cell
 * expansion into the validator's full local observation.
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

function tableRows(): Element[] {
  return all('.chain-mode .state-table tbody tr')
}

/** The cell button of validator row v at slot column s. */
function cell(v: number, s: number): Element | undefined {
  return tableRows()[v]?.querySelectorAll('td .state-cell')[s]
}

async function checkPartitionValidator(v: number) {
  const group = all('.intervention-group').find((g) =>
    g.querySelector('legend')?.textContent?.includes('分断'),
  )
  const box = group?.querySelectorAll('input[type="checkbox"]')[v]
  if (!box) throw new Error('partition checkbox not found')
  await click(box)
}

describe('table shape and alignment', () => {
  it('renders one row per validator and one column per slot', async () => {
    await advance(4)
    const rows = tableRows()
    expect(rows).toHaveLength(4)
    for (let v = 0; v < 4; v++) {
      expect(rows[v]?.querySelector('th')?.textContent).toContain(
        validatorName(v),
      )
      expect(rows[v]?.querySelectorAll('td .state-cell')).toHaveLength(5)
    }
    // Column headers count slots 0..4 alongside the label column.
    const headers = all('.chain-mode .state-table thead th').map(
      (h) => h.textContent,
    )
    expect(headers).toEqual(['バリデータ', '0', '1', '2', '3', '4'])
  })

  it('reflects the validator count in the rows', async () => {
    const select = container.querySelector('.field-inline select')
    if (!(select instanceof HTMLSelectElement)) throw new Error('select not found')
    await act(async () => {
      select.value = '7'
      select.dispatchEvent(new Event('change', { bubbles: true }))
    })
    expect(tableRows()).toHaveLength(7)
  })
})

describe('dynamic cell item selection', () => {
  it('switches the displayed item from head to finalized', async () => {
    await advance(9)
    // Default item: head — everyone follows B9 at slot 9 under instant delivery.
    expect(cell(0, 9)?.textContent).toBe('B9')
    await click(
      all('.state-table-toolbar .segmented button').find(
        (b) => b.textContent === 'finalized',
      ),
    )
    // Slot 9: finalized = B4 (same run as the badge test); slot 0: anchor B0.
    expect(cell(0, 9)?.textContent).toBe('B4')
    expect(cell(0, 0)?.textContent).toBe('B0')
  })

  it('shows View elements as cell items', async () => {
    await advance(2)
    await click(
      all('.state-table-toolbar .segmented button').find(
        (b) => b.textContent === 'ブロック数',
      ),
    )
    // Slot 2 under instant delivery: anchor + B1 + B2 visible to everyone.
    expect(cell(1, 2)?.textContent).toBe('3')
  })
})

describe('difference highlighting (成功条件 3・4)', () => {
  it('has no highlighted cell while every validator agrees', async () => {
    await advance(4)
    expect(all('.state-cell-diff')).toHaveLength(0)
  })

  it('highlights diverging cells during a partition and shows convergence after healing', async () => {
    await checkPartitionValidator(0)
    await checkPartitionValidator(1)
    await click(buttonByText('選択集合を残りから分断'))
    await advance(6)
    // The two camps disagree: highlighted cells appear in later columns.
    expect(all('.state-cell-diff').length).toBeGreaterThan(0)

    await click(buttonByText('解消（次スロットから）'))
    await advance(2)
    // Convergence is visible on the table: the latest column agrees again
    // while the historical divergence stays highlighted.
    const rows = tableRows()
    for (const row of rows) {
      const cells = row.querySelectorAll('td .state-cell')
      const last = cells[cells.length - 1]
      expect(last?.classList.contains('state-cell-diff')).toBe(false)
    }
    expect(all('.state-cell-diff').length).toBeGreaterThan(0)
  })
})

describe('cell expansion into the local observation', () => {
  it('expands a cell into that validator view at that slot and closes again', async () => {
    await advance(4)
    expect(container.querySelector('.state-detail')).toBeNull()
    await click(cell(2, 2))
    expect(text('.state-detail h3')).toContain('キャロル の視点')
    expect(text('.state-detail h3')).toContain('スロット 2')
    // View at slot 2: anchor + B1 + B2.
    expect(all('.state-detail .tree-block')).toHaveLength(3)
    // The expansion lists every vote in the view (slots 1 and 2, 4 voters
    // each), not just the latest per validator.
    expect(text('.state-detail')).toContain('全 8 件')
    expect(all('.state-detail .vote-table tbody tr')).toHaveLength(8)
    expect(text('.state-detail .status-list')).toContain('finalized')

    await click(buttonByText('閉じる'))
    expect(container.querySelector('.state-detail')).toBeNull()
  })

  it('lists both votes of a double vote individually (各投票の支持先)', async () => {
    await advance(1)
    // アリス double-votes at s2: her honest vote and the conflicting second
    // one must both stay observable in the expansion.
    const select = container.querySelector<HTMLSelectElement>(
      'select[aria-label="二重投票するバリデータ"]',
    )
    expect(select).not.toBeNull()
    await act(async () => {
      select!.value = '0'
      select!.dispatchEvent(new Event('change', { bubbles: true }))
    })
    await click(buttonByText('次スロットで二重投票'))
    await advance(1)
    await click(cell(1, 2))
    const rows = all('.state-detail .vote-table tbody tr')
    // 4 honest slot-1 votes + 4 honest slot-2 votes + 1 equivocal vote.
    expect(rows).toHaveLength(9)
    const aliceSlot2 = rows.filter(
      (r) =>
        r.textContent?.includes('アリス') && r.children[1]?.textContent === '2',
    )
    expect(aliceSlot2).toHaveLength(2)
    const heads = new Set(aliceSlot2.map((r) => r.children[2]?.textContent))
    expect(heads.size).toBe(2)
  })

  it('toggles the same cell closed on a second click', async () => {
    await advance(3)
    await click(cell(1, 1))
    expect(text('.state-detail h3')).toContain('ボブ の視点')
    await click(cell(1, 1))
    expect(container.querySelector('.state-detail')).toBeNull()
  })
})
