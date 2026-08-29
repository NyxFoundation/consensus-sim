// @vitest-environment jsdom
/**
 * Interventions (T-009) and rewind (T-010), driven through the real DOM:
 * partitions diverge the network cards, stops silence validators, double
 * proposals fork the tree, drops rewrite the displayed history, and the
 * slot cursor rewinds and truncates — the same operations a user performs.
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

describe('partition intervention from the UI (T-009)', () => {
  it('diverges the network cards and reconverges after healing', async () => {
    await checkPartitionValidator(0)
    await checkPartitionValidator(1)
    await click(buttonByText('選択集合を残りから分断'))
    expect(text('.intervention-list')).toContain('分断')

    await advance(6)
    await click(buttonByText('ネットワーク表示'))
    expect(all('.validator-card.diverged').length).toBeGreaterThan(0)

    await click(buttonByText('解消（次スロットから）'))
    await advance(2)
    expect(all('.validator-card.diverged')).toHaveLength(0)
  })
})

/** The operating-state control (稼働 / 停止 / オフライン) for a validator. */
function opStateButton(name: string, label: string): Element | undefined {
  const group = container.querySelector(`[aria-label="${name} の稼働状態"]`)
  return [...(group?.querySelectorAll('button') ?? [])].find(
    (b) => b.textContent === label,
  )
}

describe('operating states from the UI (T-009 / T-021)', () => {
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

  it('an offline validator freezes and catches up after returning (T-021)', async () => {
    await click(opStateButton('ボブ', 'オフライン'))
    expect(text('.intervention-list')).toContain('オフライン ボブ')
    await advance(3)
    // Slot 1 (ボブ's proposal) is empty; slots 2 and 3 propose.
    expect(all('.tree-block')).toHaveLength(3)

    // ボブ's card is frozen at the anchor while everyone else moved on.
    await click(buttonByText('ネットワーク表示'))
    const diverged = all('.validator-card.diverged')
    expect(diverged).toHaveLength(1)
    expect(diverged[0]?.textContent).toContain('ボブ')
    expect(diverged[0]?.textContent).toContain('B0')

    // Return to 稼働: pent-up messages arrive through normal propagation
    // and the views reconverge.
    await click(opStateButton('ボブ', '稼働'))
    await advance(2)
    expect(all('.validator-card.diverged')).toHaveLength(0)
    await click(buttonByText('チェーン表示'))
    expect(all('.vote-table tbody tr')).toHaveLength(4)
  })
})

describe('fork creation from the UI (T-022)', () => {
  async function designateParent(value: string) {
    const select = container.querySelector(
      'select[aria-label="提案の parent ブロック"]',
    )
    if (!(select instanceof HTMLSelectElement)) throw new Error('select not found')
    await act(async () => {
      select.value = value
      select.dispatchEvent(new Event('change', { bubbles: true }))
    })
    await click(buttonByText('フォークを作成'))
  }

  it('the designated parent forks the tree; unspecified slots follow fork choice', async () => {
    await advance(2)
    await designateParent('1')
    expect(text('.intervention-list')).toContain('フォーク作成 parent B1 @ s3')
    await advance(1)
    // B3 was built on B1, not on the fork-choice head B2: 4 blocks, forked.
    expect(all('.tree-block')).toHaveLength(4)
  })

  it('refuses a fifth simultaneous designation and frees up on deletion', async () => {
    for (let i = 0; i < 4; i++) {
      await designateParent('0')
      await advance(1)
    }
    expect(all('.intervention-list li').length).toBe(4)
    const button = buttonByText('フォークを作成')
    expect((button as HTMLButtonElement).disabled).toBe(true)
    expect(text('.intervention-panel')).toContain('フォーク作成の指定は同時 4 本まで')

    // Deleting one designation makes room again.
    await click(
      all('.intervention-panel .intervention-list li button').find((b) =>
        b.textContent?.includes('削除'),
      ),
    )
    const select = container.querySelector(
      'select[aria-label="提案の parent ブロック"]',
    )
    if (!(select instanceof HTMLSelectElement)) throw new Error('select not found')
    await act(async () => {
      select.value = '0'
      select.dispatchEvent(new Event('change', { bubbles: true }))
    })
    expect((buttonByText('フォークを作成') as HTMLButtonElement).disabled).toBe(false)
  })
})

describe('equivocation from the UI (T-009)', () => {
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

describe('message drop from the UI (T-009)', () => {
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

    // Everyone but the sender (V1) loses B1: the network cards diverge.
    await click(buttonByText('ネットワーク表示'))
    expect(all('.validator-card.diverged').length).toBeGreaterThan(0)

    // Removing the intervention restores the original history.
    await click(buttonByText('削除'))
    expect(all('.validator-card.diverged')).toHaveLength(0)
  })
})

describe('rewind (T-010)', () => {
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
