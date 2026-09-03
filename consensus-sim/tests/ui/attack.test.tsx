// @vitest-environment jsdom
/**
 * Attack UI (攻撃 UI), driven through the real DOM: choosing a library
 * attack proposes its default run as the scenario's initial conditions
 * (成功条件 17), the strategy's actions appear in the intervention list
 * with the attackers' mark, the attackers are identified in the state
 * table and the block tree, the goal's verdicts and grounds run along the
 * slot axis stage by stage (成功条件 18, 24), an unmet attacker condition
 * is shown while the attack stays runnable, a manual intervention wins a
 * conflict and the discarded action stays listed, and a saved scenario
 * with an attack and a manual intervention replays to the same generated
 * actions and the same verdicts (成功条件 20).
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
    await click(buttonByText('＋1 スロット進める') ?? buttonByText('ここから進める'))
  }
}

async function selectAttack(id: string) {
  const select = container.querySelector('[aria-label="攻撃を選択"]')
  if (!(select instanceof HTMLSelectElement)) throw new Error('attack select not found')
  await act(async () => {
    select.value = id
    select.dispatchEvent(new Event('change', { bubbles: true }))
  })
}

function attackerCheckbox(validator: number): HTMLInputElement {
  const box = container.querySelector(`[aria-label="攻撃者 ${validatorName(validator)}"]`)
  if (!(box instanceof HTMLInputElement)) throw new Error('attacker checkbox not found')
  return box
}

/** Click the operating-state button (稼働 / 停止 / オフライン) for a validator. */
async function setOpState(validator: number, label: string) {
  const group = container.querySelector(
    `[aria-label="${validatorName(validator)} の稼働状態"]`,
  )
  const btn = [...(group?.querySelectorAll('button') ?? [])].find(
    (b) => b.textContent === label,
  )
  await click(btn)
}

function goalRows(): Element[] {
  return all('.goal-table .goal-row')
}

function goalCell(row: number, slot: number): Element | undefined {
  return goalRows()[row]?.querySelectorAll('td')[slot]
}

describe('choosing an attack proposes its default run (成功条件 17)', () => {
  it('sets the initial conditions, the attacker set and the premise, and runs the strategy', async () => {
    await selectAttack('A11')

    // The default run: 4 validators, merge, attackers V0 V1 V2, slot 0.
    const count = container.querySelector('.field-inline select')
    expect((count as HTMLSelectElement).value).toBe('4')
    expect(text('.params-panel .panel-count')).toContain('merge')
    expect(text('.attack-panel .panel-count')).toBe('A11')
    expect(text('.slot-current')).toContain('0')
    for (const v of [0, 1, 2]) expect(attackerCheckbox(v).checked).toBe(true)
    expect(attackerCheckbox(3).checked).toBe(false)
    expect(text('.attack-panel')).toContain('前提 merge / d = 2')
    expect(text('.attack-panel')).toContain('プロトコルパラメータは前提どおり')
    expect(text('.attack-panel')).toContain('条件 初期ステーク比率 ≥ 1/2')
    expect(text('.attack-panel')).not.toContain('条件未満')
    // The end slot of the default run is proposed.
    const through = container.querySelector('[aria-label="終了スロット"]')
    expect((through as HTMLInputElement).value).toBe('8')

    await advance(4)

    // The strategy's actions are listed with the attackers' mark, none
    // discarded, and the generated count is read out.
    const generated = all('.intervention-panel .attacker-action')
    expect(generated.length).toBeGreaterThan(0)
    for (const li of generated) expect(li.textContent).toContain('攻撃者')
    expect(all('.intervention-panel .attacker-action.discarded')).toHaveLength(0)
    expect(text('.intervention-panel .intervention-list')).toContain('フォーク作成 parent B0 @ s4')
    expect(text('.intervention-panel summary')).toContain('生成 7 件')

    // Attackers are identified in the state table rows …
    const rows = all('.state-table tbody tr')
    for (const v of [0, 1, 2]) {
      expect(rows[v]?.className).toContain('attacker-row')
      expect(rows[v]?.querySelector('th')?.textContent).toContain('攻撃者')
    }
    expect(rows[3]?.className).not.toContain('attacker-row')
    expect(rows[3]?.querySelector('th')?.textContent).not.toContain('攻撃者')
    // … and in the block tree: the blocks they proposed carry the mark.
    expect(all('.tree-block-attacker').length).toBeGreaterThanOrEqual(3)
    const sublabels = all('.block-sublabel').map((t) => t.textContent)
    expect(sublabels).toContain(`攻 ${validatorName(1)}`)
    expect(sublabels).toContain(validatorName(3))
    expect(all('.chip-attacker').length).toBeGreaterThan(0)
  })

  it('marks an unmet attacker condition as 条件未満 and still runs', async () => {
    await selectAttack('A11')
    // The last attacker cannot be unchecked; dropping to V0 alone (1/4 < 1/2)
    // leaves the condition unmet.
    await click(attackerCheckbox(2))
    expect(text('.attack-panel')).not.toContain('条件未満')
    await click(attackerCheckbox(1))
    expect(attackerCheckbox(0).disabled).toBe(true)
    expect(text('.attack-panel')).toContain('条件未満')
    expect(text('.attack-panel')).toContain('現在 1 名・比率 25%')

    await advance(3)
    expect(text('.slot-current')).toContain('3')
    expect(all('.state-table tbody tr.attacker-row')).toHaveLength(1)
    expect(text('.attack-panel')).toContain('条件未満')
  })

  it('reads out a departure from the premise and offers the way back', async () => {
    await selectAttack('A11')
    const boost = container.querySelector('[aria-label="proposer boost"]')
    if (!(boost instanceof HTMLInputElement)) throw new Error('boost field not found')
    // Through the native value setter so React's controlled input sees the change.
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set
    await act(async () => {
      setter?.call(boost, '0')
      boost.dispatchEvent(new Event('input', { bubbles: true }))
    })
    expect(text('.attack-panel')).toContain('前提と異なる（現在 カスタム）')
    await click(buttonByText('前提に戻す'))
    expect(text('.attack-panel')).toContain('プロトコルパラメータは前提どおり')
    expect(text('.params-panel .panel-count')).toContain('merge')
  })

  it('removes the attack and its generated actions', async () => {
    await selectAttack('A11')
    await advance(2)
    expect(all('.intervention-panel .attacker-action').length).toBeGreaterThan(0)
    await click(buttonByText('攻撃を外す'))
    expect(all('.intervention-panel .attacker-action')).toHaveLength(0)
    expect(container.querySelector('.goal-table')).toBeNull()
    expect(all('.state-table tbody tr.attacker-row')).toHaveLength(0)
    expect(text('.slot-current')).toContain('2')
  })
})

describe('the goal trace runs along the slot axis (成功条件 18)', () => {
  it('shows the verdict, its grounds and the achieved slot per stage', async () => {
    await selectAttack('A11')
    await advance(3)
    // One stage, judged from slot 0, not yet holding.
    expect(goalRows()).toHaveLength(1)
    expect(goalRows()[0]?.querySelector('th')?.textContent).toContain('第 1 段 リオーグ（k = 1）')
    expect(goalRows()[0]?.querySelector('th')?.textContent).toContain('判定中')
    expect(goalRows()[0]?.querySelectorAll('td')).toHaveLength(4)
    expect(goalCell(0, 3)?.textContent).toBe('0 回')
    expect(goalCell(0, 3)?.className).not.toContain('goal-holds')
    expect(text('.attack-panel .goal-stages')).toContain('判定中')

    await advance(1)
    const achieved = goalCell(0, 4)
    expect(achieved?.textContent).toBe('達成 1 回')
    expect(achieved?.className).toContain('goal-achieved-at')
    expect(achieved?.className).toContain('goal-holds')
    expect(achieved?.getAttribute('title')).toContain('リオーグ累計 1 回')
    expect(achieved?.getAttribute('title')).toContain(`${validatorName(3)} s4 B3 → B4`)
    expect(goalRows()[0]?.querySelector('th')?.textContent).toContain('達成 @s4')
    expect(text('.attack-panel .goal-stages')).toContain('達成 @s4')

    await advance(2)
    expect(goalCell(0, 6)?.textContent).toBe('1 回')
    expect(goalCell(0, 6)?.className).toContain('goal-holds')
    expect(goalCell(0, 6)?.className).not.toContain('goal-achieved-at')

    // Rewinding shows the trace through the displayed slot only.
    await click(container.querySelector('[aria-label="1 スロット戻る"]'))
    await click(container.querySelector('[aria-label="1 スロット戻る"]'))
    await click(container.querySelector('[aria-label="1 スロット戻る"]'))
    expect(text('.slot-current')).toContain('3')
    expect(goalRows()[0]?.querySelectorAll('td')).toHaveLength(4)
    expect(goalRows()[0]?.querySelector('th')?.textContent).toContain('判定中')
  })
})

describe('a two-stage goal (A14, 成功条件 24)', () => {
  it('shows the ratio reaching θ, its slot, and the second stage judged after it', async () => {
    await selectAttack('A14')
    await advance(40)
    expect(goalRows()).toHaveLength(2)
    const [ratio, safety] = goalRows()
    expect(ratio?.querySelector('th')?.textContent).toContain('攻撃者ステーク比率（θ = 1/3）')
    expect(ratio?.querySelector('th')?.textContent).toContain('達成 @s32')
    expect(safety?.querySelector('th')?.textContent).toContain('第 2 段 安全性違反')
    expect(safety?.querySelector('th')?.textContent).toContain('達成 @s40')

    // Stage 1: the ratio climbs and crosses the threshold at slot 32.
    expect(goalCell(0, 0)?.textContent).toBe('25%')
    expect(goalCell(0, 31)?.className).not.toContain('goal-holds')
    expect(goalCell(0, 32)?.textContent).toBe('達成 35.2%')
    expect(goalCell(0, 32)?.className).toContain('goal-achieved-at')
    expect(goalCell(0, 32)?.getAttribute('title')).toContain('攻撃者ステーク比率 35.2%')
    // Stage 2 waits until stage 1 is achieved, then is judged.
    expect(goalCell(1, 31)?.className).toContain('goal-pending')
    expect(goalCell(1, 33)?.className).toContain('goal-active')
    expect(goalCell(1, 40)?.textContent).toMatch(/^達成 違反 B\d+\/B\d+$/)
    expect(goalCell(1, 40)?.className).toContain('goal-achieved-at')
    expect(text('.attack-panel .goal-stages')).toContain('達成 @s32')
    expect(text('.attack-panel .goal-stages')).toContain('達成 @s40')
  }, 60_000)
})

describe('attack with manual interventions (成功条件 20)', () => {
  it('lets the manual intervention win, keeps the discarded action listed, and replays a saved scenario identically', async () => {
    await selectAttack('A09')
    // A09's strategy silences the attackers (V2, V3) from slot 1; a manual
    // stop of V2 from slot 1 contradicts it, so the action is discarded.
    await setOpState(2, '停止')
    await advance(6)

    const discarded = all('.intervention-panel .attacker-action.discarded')
    expect(discarded).toHaveLength(1)
    expect(discarded[0]?.textContent).toContain('破棄: 手動介入と矛盾')
    expect(discarded[0]?.textContent).toContain('攻撃者')
    expect(text('.intervention-panel summary')).toContain('生成 1 件（破棄 1）')
    expect(text('.intervention-panel .intervention-list')).toContain(`停止 ${validatorName(2)} s1〜`)

    const listBefore = text('.intervention-panel .intervention-list')
    const traceBefore = text('.goal-table')
    const tableBefore = text('.state-table')

    await click(buttonByText('現在のシナリオを保存'))
    expect(text('.scenario-panel .intervention-list')).toContain('攻撃 A09')

    // Mutate the live scenario: drop the attack and the manual stop, advance.
    await click(buttonByText('攻撃を外す'))
    await click(
      all('.intervention-panel .intervention-list li button').find((b) =>
        b.textContent?.includes('削除'),
      ),
    )
    await advance(2)
    expect(text('.slot-current')).toContain('8')
    expect(container.querySelector('.goal-table')).toBeNull()

    // Reload: the same generated actions, the same verdicts, the same states.
    await click(buttonByText('読込・再実行'))
    expect(text('.slot-current')).toContain('6')
    expect(text('.attack-panel .panel-count')).toBe('A09')
    expect(text('.intervention-panel .intervention-list')).toBe(listBefore)
    expect(text('.goal-table')).toBe(traceBefore)
    expect(text('.state-table')).toBe(tableBefore)
  })
})
