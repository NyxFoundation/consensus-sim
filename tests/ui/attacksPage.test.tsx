// @vitest-environment jsdom
/**
 * Attack list page (攻撃一覧), driven through the real DOM (成功条件 16):
 * the page opens with the formal system's definitions (the triple, the
 * capability range, the goal predicates), then the library table whose
 * every row matches the implementation's library entry — name, source id,
 * premise, attacker condition, capabilities, goal stages, strategy summary
 * and default run — and choosing a row proposes that default run as the
 * scenario's initial conditions on the chain display (成功条件 17). The
 * page has its own layout: header bar only.
 */

import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { act } from 'react'
import { createRoot, type Root } from 'react-dom/client'
import { ATTACK_LIBRARY, presetOf, validatorName } from '../../src/domain'
import { App } from '../../src/ui/App'
import {
  capabilityLabel,
  conditionLabel,
  defaultRunLines,
  premiseLabel,
  stageLabel,
} from '../../src/ui/attackFormat'

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

async function openAttacks() {
  await click(buttonByText('攻撃一覧'))
}

function row(id: string): Element {
  const tr = container.querySelector(`.attack-table tr.attack-row[data-attack="${id}"]`)
  if (!tr) throw new Error(`no row for ${id}`)
  return tr
}

describe('attack list page: layout and the formal system', () => {
  it('has its own layout: header bar only, definitions before the library', async () => {
    await openAttacks()
    expect(container.querySelector('.attacks-page')).not.toBeNull()
    expect(container.querySelector('.slot-bar')).toBeNull()
    expect(container.querySelector('.dock')).toBeNull()
    expect(container.querySelector('.field-inline')).toBeNull()
    expect(container.querySelector('.mode-tabs')).not.toBeNull()
    expect(container.querySelector('.theme-toggle')).not.toBeNull()
    const page = container.querySelector('.attacks-page')
    expect(page?.children[0]?.classList.contains('attacks-system')).toBe(true)
    expect(page?.lastElementChild?.classList.contains('attack-table')).toBe(true)
  })

  it('defines the triple, the two bases with the action vocabulary, and the four predicates', async () => {
    await openAttacks()
    const tables = all('.attacks-system table')
    expect(tables.map((t) => t.getAttribute('aria-label'))).toEqual([
      '攻撃の 3 つ組',
      '攻撃者の能力範囲',
      '攻撃目標述語',
    ])
    const terms = (t: Element | undefined) =>
      [...(t?.querySelectorAll('th[scope="row"]') ?? [])].map((th) => th.textContent)
    expect(text('.attacks-system table caption')).toContain('攻撃 = (攻撃者集合の条件, 攻撃目標, 戦略)')
    expect(terms(tables[0])).toEqual(['攻撃者集合の条件', '攻撃目標', '戦略'])
    expect(terms(tables[1])).toEqual(['公開 (i)', '配送 (ii)', '行動語彙（基底の糖衣）'])
    expect(tables[1]?.textContent).toContain('偽造不能')
    expect(tables[1]?.textContent).toContain('最大 d スロット')
    // The vocabulary is every capability the implementation names.
    const vocabulary = [...(tables[1]?.querySelectorAll('.vocabulary-term') ?? [])].map(
      (li) => li.textContent,
    )
    for (const c of ['equivocation', 'withhold', 'partition', 'omit-inclusion'] as const) {
      expect(vocabulary).toContain(capabilityLabel(c))
    }
    expect(vocabulary).toHaveLength(9)
    expect(terms(tables[2])).toEqual([
      '安全性違反',
      '活性停止（L）',
      'リオーグ（k）',
      '攻撃者ステーク比率（θ）',
    ])
    expect(tables[2]?.textContent).toContain('互いに祖先関係にない 2 つのチェックポイント')
    expect(tables[2]?.textContent).toContain('既定 k = 1')
  })
})

describe('attack list page: the library table is derived from the implementation (成功条件 16)', () => {
  it('has the required columns and one row per library attack', async () => {
    await openAttacks()
    expect(all('.attack-table thead th').map((th) => th.textContent)).toEqual([
      '攻撃',
      '出典',
      '前提',
      '攻撃者集合の条件',
      '必要な能力',
      '攻撃目標',
      '戦略の要約',
      '既定実行構成',
    ])
    expect(all('.attack-table tbody tr').map((tr) => tr.getAttribute('data-attack'))).toEqual(
      ATTACK_LIBRARY.map((a) => a.id),
    )
    expect(text('.attacks-page .panel-count')).toBe(`${ATTACK_LIBRARY.length} 件`)
  })

  it('shows every field of every attack as the library defines it', async () => {
    await openAttacks()
    for (const entry of ATTACK_LIBRARY) {
      const cells = [...row(entry.id).querySelectorAll('td')].map((td) => td.textContent ?? '')
      expect(cells).toHaveLength(8)
      const [name, source, premise, condition, capabilities, goal, strategy, run] = cells
      expect(name).toContain(entry.id)
      expect(name).toContain(entry.name)
      // The source carries the report's attack id.
      expect(source).toBe(entry.source)
      expect(source).toContain('essences/deep-research-report.md#')
      expect(premise).toBe(premiseLabel(entry.premise))
      expect(premise).toContain(entry.premise.preset)
      expect(premise).toContain(`d = ${entry.premise.maxDelay}`)
      expect(condition).toBe(conditionLabel(entry.attackers))
      expect(
        [...row(entry.id).querySelectorAll('.attack-capabilities li')].map((li) => li.textContent),
      ).toEqual(entry.capabilities.map(capabilityLabel))
      expect(capabilities).not.toBe('')
      expect([...row(entry.id).querySelectorAll('.attack-goal li')].map((li) => li.textContent)).toEqual(
        entry.goal.map(stageLabel),
      )
      expect(goal).not.toBe('')
      expect(strategy).toBe(entry.strategySummary)
      expect(run).toBe(defaultRunLines(entry).join(''))
      expect(run).toContain(`バリデータ ${entry.defaultRun.validatorCount} 体`)
      for (const v of entry.defaultRun.attackers) expect(run).toContain(validatorName(v))
      expect(run).toContain(`終了スロット s${entry.defaultRun.throughSlot}`)
      expect(run).toContain(`シード ${entry.defaultRun.seed}`)
    }
  })

  it('spells the premise overrides and the two-stage goal out', async () => {
    await openAttacks()
    expect(row('A05').textContent).toContain(
      'merge + 切替窓 off・unrealized off, committee = エポック分割 / d = 5',
    )
    expect(row('A04').textContent).toContain('merge + 割引 off / d = 2')
    expect(row('A07').textContent).toContain('phase0 + forkChoice = GHOST / d = 5')
    expect([...row('A14').querySelectorAll('.attack-goal li')].map((li) => li.textContent)).toEqual([
      '攻撃者ステーク比率（θ = 1/3）',
      '安全性違反',
    ])
    expect(row('A09').textContent).toContain('攻撃者 キャロル・デイブ')
  })
})

describe('choosing a row proposes the default run (成功条件 17)', () => {
  it('returns to the chain display with the initial conditions, attackers, premise and end slot set', async () => {
    await openAttacks()
    await click(container.querySelector('[aria-label="攻撃 A05 を選択"]'))
    const entry = ATTACK_LIBRARY.find((a) => a.id === 'A05')!

    expect(container.querySelector('.attacks-page')).toBeNull()
    expect(container.querySelector('.slot-bar')).not.toBeNull()
    expect(text('.slot-current')).toContain('0')
    expect(text('.attack-panel .panel-count')).toBe('A05')
    const count = container.querySelector('.field-inline select')
    expect((count as HTMLSelectElement).value).toBe(String(entry.defaultRun.validatorCount))
    for (let v = 0; v < entry.defaultRun.validatorCount; v++) {
      const box = container.querySelector(`[aria-label="攻撃者 ${validatorName(v)}"]`)
      expect((box as HTMLInputElement).checked).toBe(entry.defaultRun.attackers.includes(v))
    }
    // The premise's parameters (a preset plus overrides ⇒ カスタム) are in force.
    expect(presetOf).toBeTypeOf('function')
    expect(text('.params-panel .panel-count')).toContain('カスタム')
    expect(text('.attack-panel')).toContain('プロトコルパラメータは前提どおり')
    const through = container.querySelector('[aria-label="終了スロット"]')
    expect((through as HTMLInputElement).value).toBe(String(entry.defaultRun.throughSlot))
    // The auto-play control is offered, nothing has run yet.
    expect(text('.play-toggle')).toBe('実行開始')
    expect(all('.intervention-panel .attacker-action')).toHaveLength(0)
  })

  it('proposes a fresh run even when the same attack is already bound and advanced', async () => {
    await openAttacks()
    await click(container.querySelector('[aria-label="攻撃 A11 を選択"]'))
    await click(buttonByText('＋1 スロット進める'))
    await click(buttonByText('＋1 スロット進める'))
    expect(text('.slot-current')).toContain('2')
    await openAttacks()
    await click(container.querySelector('[aria-label="攻撃 A11 を選択"]'))
    expect(text('.slot-current')).toContain('0')
    expect(text('.attack-panel .panel-count')).toBe('A11')
  })
})
