// @vitest-environment jsdom
/**
 * Interventions and rewind, driven through the real DOM:
 * partitions diverge the network cards, stops silence validators, double
 * proposals fork the tree, drops rewrite the displayed history, and the
 * slot cursor rewinds and truncates — the same operations a user performs.
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
    await click(
      buttonByText('＋1 スロット進める') ?? buttonByText('ここから進める'),
    )
  }
}

/** Check the n-th validator checkbox inside the 分断 fieldset. */
async function checkPartitionValidator(v: number) {
  const group = all('.intervention-group').find((g) =>
    g.querySelector('legend')?.textContent?.includes('分断'),
  )
  const box = group?.querySelectorAll('input[type="checkbox"]')[v]
  if (!box) throw new Error('partition checkbox not found')
  await click(box)
}

/** The state-table cells of the latest slot column that carry a difference mark. */
function latestColumnDiffs(): Element[] {
  return all('.state-table tbody tr').flatMap((row) => {
    const cells = row.querySelectorAll('td .state-cell')
    const last = cells[cells.length - 1]
    return last?.classList.contains('state-cell-diff') ? [last] : []
  })
}

describe('partition intervention from the UI', () => {
  it('diverges the state table and reconverges after healing', async () => {
    await checkPartitionValidator(0)
    await checkPartitionValidator(1)
    await click(buttonByText('選択集合を残りから分断'))
    expect(text('.intervention-list')).toContain('分断')

    await advance(6)
    expect(all('.state-cell-diff').length).toBeGreaterThan(0)

    await click(buttonByText('解消（次スロットから）'))
    await advance(2)
    expect(latestColumnDiffs()).toHaveLength(0)
  })
})

/** Every span shown in the queue as s<from>〜s<to> must satisfy from ≤ to. */
function expectNoInvalidSpanInQueue() {
  for (const item of all('.intervention-list li')) {
    const m = item.textContent?.match(/s(\d+)〜s(\d+)/)
    if (m) expect(Number(m[2])).toBeGreaterThanOrEqual(Number(m[1]))
  }
}

describe('intervention queue soundness', () => {
  it('healing a partition before it takes effect removes it outright', async () => {
    await checkPartitionValidator(0)
    await checkPartitionValidator(1)
    await click(buttonByText('選択集合を残りから分断'))
    expect(text('.intervention-list')).toContain('分断')

    // Heal immediately: fromSlot (1) is still ahead of the cursor (0), so
    // closing would create a toSlot-before-fromSlot span — the entry must
    // disappear instead of turning invalid.
    await click(buttonByText('解消（次スロットから）'))
    expect(all('.intervention-list li')).toHaveLength(0)
    expect(text('.intervention-panel')).toContain('介入はまだありません')
  })

  it('healing an effective partition closes it at the cursor', async () => {
    await checkPartitionValidator(0)
    await checkPartitionValidator(1)
    await click(buttonByText('選択集合を残りから分断'))
    await advance(3)
    await click(buttonByText('解消（次スロットから）'))
    expect(text('.intervention-list')).toContain('s1〜s3')
    expectNoInvalidSpanInQueue()
  })

  it('rapid operating-state toggling leaves no invalid or stale span', async () => {
    // 停止 → オフライン → 稼働 without ever advancing: each transition
    // touches a span that has not taken effect yet, so the queue must end
    // empty rather than holding closed-before-open remnants.
    await click(opStateButton('ボブ', '停止'))
    await click(opStateButton('ボブ', 'オフライン'))
    expect(text('.intervention-list')).toContain('オフライン ボブ')
    expectNoInvalidSpanInQueue()
    await click(opStateButton('ボブ', '稼働'))
    expect(all('.intervention-list li')).toHaveLength(0)
  })

  it('repeated designate/heal cycles across advances keep every span valid', async () => {
    await checkPartitionValidator(0)
    await click(buttonByText('選択集合を残りから分断'))
    await advance(2)
    await click(buttonByText('解消（次スロットから）'))
    await checkPartitionValidator(1)
    await click(buttonByText('選択集合を残りから分断'))
    await click(buttonByText('解消（次スロットから）'))
    await advance(1)
    // First heal closed s1〜s2; the second entry (never effective) vanished.
    expect(all('.intervention-list li')).toHaveLength(1)
    expect(text('.intervention-list')).toContain('s1〜s2')
    expectNoInvalidSpanInQueue()
  })
})

/** The operating-state control (稼働 / 停止 / オフライン) for a validator. */
function opStateButton(name: string, label: string): Element | undefined {
  const group = container.querySelector(`[aria-label="${name} の稼働状態"]`)
  return [...(group?.querySelectorAll('button') ?? [])].find(
    (b) => b.textContent === label,
  )
}

describe('operating states from the UI', () => {
  it('a stopped proposer leaves the slot empty and resuming restores votes', async () => {
    // Slot 1's proposer is V1 (ボブ): stop it before the first advance.
    await click(opStateButton('ボブ', '停止'))
    expect(opStateButton('ボブ', '停止')?.getAttribute('aria-pressed')).toBe('true')
    expect(text('.intervention-list')).toContain('停止 ボブ')
    await advance(1)
    // Anchor only — the stopped proposer published nothing.
    expect(all('.tree-block')).toHaveLength(1)
    expect(all('.vote-table tbody tr')).toHaveLength(3)

    await click(opStateButton('ボブ', '稼働'))
    await advance(1)
    expect(all('.vote-table tbody tr')).toHaveLength(4)
  })

  it('an offline validator freezes and catches up after returning', async () => {
    await click(opStateButton('ボブ', 'オフライン'))
    expect(text('.intervention-list')).toContain('オフライン ボブ')
    await advance(3)
    // Slot 1 (ボブ's proposal) is empty; slots 2 and 3 propose.
    expect(all('.tree-block')).toHaveLength(3)

    // ボブ's row is frozen at the anchor while everyone else moved on: the
    // latest column marks exactly that row as differing, with head B0.
    const diverged = latestColumnDiffs()
    expect(diverged).toHaveLength(1)
    expect(diverged[0]?.closest('tr')?.textContent).toContain('ボブ')
    expect(diverged[0]?.textContent).toContain('B0')

    // Return to 稼働: pent-up messages arrive through normal propagation
    // and the views reconverge on the latest column.
    await click(opStateButton('ボブ', '稼働'))
    await advance(2)
    expect(latestColumnDiffs()).toHaveLength(0)
    expect(all('.vote-table tbody tr')).toHaveLength(4)
  })

  it('a merely stopped validator keeps receiving: no divergence, one vote fewer', async () => {
    await click(opStateButton('キャロル', '停止'))
    expect(text('.intervention-list')).toContain('停止 キャロル')
    await advance(2)
    expect(latestColumnDiffs()).toHaveLength(0)
    expect(all('.vote-table tbody tr')).toHaveLength(3)
  })

  it('leaves a span scheduled beyond the cursor untouched when the state is changed after a rewind', async () => {
    // Schedule ボブ offline from s2, then rewind so the span lies ahead of
    // the control's next slot: the control reads 稼働 and setting 停止 must
    // add a new span without silently deleting the scheduled one.
    await advance(1)
    await click(opStateButton('ボブ', 'オフライン'))
    expect(text('.intervention-list')).toContain('オフライン ボブ s2〜')
    const back = container.querySelector('button[aria-label="1 スロット戻る"]')
    await click(back)
    expect(opStateButton('ボブ', '稼働')?.getAttribute('aria-pressed')).toBe('true')
    await click(opStateButton('ボブ', '停止'))
    expect(text('.intervention-list')).toContain('オフライン ボブ s2〜')
    expect(text('.intervention-list')).toContain('停止 ボブ s1〜')
    expectNoInvalidSpanInQueue()
  })
})

describe('fork creation from the UI', () => {
  async function selectParent(value: string) {
    const select = container.querySelector(
      'select[aria-label="提案の parent ブロック"]',
    )
    if (!(select instanceof HTMLSelectElement)) throw new Error('select not found')
    await act(async () => {
      select.value = value
      select.dispatchEvent(new Event('change', { bubbles: true }))
    })
  }
  async function designateParent(value: string) {
    await selectParent(value)
    await click(buttonByText('フォークを作成'))
  }
  const createButton = () => buttonByText('フォークを作成') as HTMLButtonElement
  const forkGroup = () =>
    all('.intervention-group').find((g) =>
      g.querySelector('legend')?.textContent?.includes('フォーク作成'),
    )?.textContent ?? ''

  it('the designated parent forks the tree; unspecified slots follow fork choice', async () => {
    await advance(2)
    await designateParent('1')
    expect(text('.intervention-list')).toContain('フォーク作成 parent B1 @ s3')
    await advance(1)
    // B3 was built on B1, not on the fork-choice head B2: 4 blocks, forked.
    expect(all('.tree-block')).toHaveLength(4)
  })

  it('refuses a designation that would push the fork count past 4 and accepts again once finality advances', async () => {
    // B1 honest; B2, B3 designated on the anchor; B4 honest on the head B1
    // at the epoch boundary; B5 designated on the anchor: 4 forks.
    await advance(1)
    await designateParent('0')
    expect(text('.intervention-list')).toContain('フォーク作成 parent B0 @ s2')
    await advance(1)
    await designateParent('0')
    await advance(2)
    expect(forkGroup()).toContain('フォーク数 3／上限 4')
    await designateParent('0')
    expect(forkGroup()).toContain('フォーク数 3（未実行の指定を含めて 4）')
    await advance(1)
    expect(forkGroup()).toContain('フォーク数 4／上限 4')

    // Another proposal on the anchor would make 5: refused, with the reason.
    await selectParent('0')
    expect(createButton().disabled).toBe(true)
    expect(forkGroup()).toContain('フォーク数が 5 となり上限を超えるため受け付けません')
    // Extending the leaf B4 adds no fork, so it is still accepted.
    await selectParent('4')
    expect(createButton().disabled).toBe(false)
    await selectParent('')

    // Honest slots build on B4; it is finalized at slot 9, so the
    // anchor-level forks fall out of the count and B4 can be forked again.
    await advance(4)
    expect(forkGroup()).toContain('フォーク数 1／上限 4')
    await designateParent('4')
    expect(text('.intervention-list')).toContain('フォーク作成 parent B4 @ s10')
  })

  it('reports forks arising from equivocation without constraining them', async () => {
    for (let i = 0; i < 5; i++) {
      await click(buttonByText('次スロットで二重提案'))
      await advance(1)
    }
    expect(forkGroup()).toContain('フォーク数 6／上限 4')
    // The equivocation control is untouched by the limit; only a fork
    // designation is refused.
    expect((buttonByText('次スロットで二重提案') as HTMLButtonElement).disabled).toBe(false)
    await selectParent('0')
    expect(createButton().disabled).toBe(true)
  })
})

describe('equivocation from the UI', () => {
  it('double propose forks the next slot into two sibling blocks', async () => {
    await click(buttonByText('次スロットで二重提案（提案者 ボブ）'))
    expect(text('.intervention-list')).toContain('二重提案 ボブ @ s1')
    await advance(1)
    // The overlaid chain display: anchor + two competing slot-1 blocks.
    expect(all('.tree-block')).toHaveLength(3)
  })

  it('double vote produces two vote chips for one validator', async () => {
    await advance(2)
    const select = container.querySelector(
      'select[aria-label="二重投票するバリデータ"]',
    )
    if (!(select instanceof HTMLSelectElement)) throw new Error('select not found')
    await act(async () => {
      select.value = '3'
      select.dispatchEvent(new Event('change', { bubbles: true }))
    })
    await click(buttonByText('次スロットで二重投票'))
    expect(text('.intervention-list')).toContain('二重投票 デイブ @ s3')
    await advance(1)
    // The latest-vote table still shows one resolved row per validator.
    expect(all('.vote-table tbody tr')).toHaveLength(4)
  })
})

describe('message drop from the UI', () => {
  it('dropping a block rewrites history deterministically for its observers', async () => {
    await advance(1)
    const select = container.querySelector('select[aria-label="対象メッセージ"]')
    if (!(select instanceof HTMLSelectElement)) throw new Error('select not found')
    const blockOption = [...select.options].find((o) =>
      o.textContent?.includes('ブロック B1'),
    )
    if (!blockOption) throw new Error('block option not found')
    await act(async () => {
      select.value = blockOption.value
      select.dispatchEvent(new Event('change', { bubbles: true }))
    })
    await click(buttonByText('適用'))
    expect(text('.intervention-list')).toContain('欠落 ブロック B1')

    // Everyone but the sender (V1) loses B1: the state table diverges.
    expect(all('.state-cell-diff').length).toBeGreaterThan(0)

    // Removing the intervention restores the original history.
    await click(buttonByText('削除'))
    expect(all('.state-cell-diff')).toHaveLength(0)
  })
})

describe('rewind', () => {
  it('rewinds to a past slot and reproduces that state exactly', async () => {
    await advance(5)
    expect(text('.slot-current')).toContain('5')
    const back = container.querySelector('button[aria-label="1 スロット戻る"]')
    await click(back)
    await click(back)
    await click(back)
    expect(text('.slot-current')).toContain('2')
    expect(text('.slot-current')).toContain('最新 5')
    // State at slot 2: anchor + blocks of slots 1..2.
    expect(all('.tree-block')).toHaveLength(3)
    expect(buttonByText('ここから進める（以降の履歴を破棄）')).toBeDefined()

    await click(buttonByText('最新へ'))
    expect(text('.slot-current')).toContain('5')
    expect(all('.tree-block')).toHaveLength(6)
  })

  it('advancing from a past cursor truncates the discarded future', async () => {
    await advance(4)
    const back = container.querySelector('button[aria-label="1 スロット戻る"]')
    await click(back)
    await click(back)
    expect(text('.slot-current')).toContain('2')
    await click(buttonByText('ここから進める（以降の履歴を破棄）'))
    expect(text('.slot-current')).toContain('3')
    // The run now ends at slot 3: no 最新へ button, forward step disabled.
    expect(buttonByText('最新へ')).toBeUndefined()
    expect(all('.tree-block')).toHaveLength(4)
  })
})
