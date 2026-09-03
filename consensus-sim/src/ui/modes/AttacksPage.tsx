/**
 * Attack list page (攻撃一覧, 必須 22): the formal system's definitions
 * first — the attack triple, the attacker's capability range (the two
 * bases and the action vocabulary over them) and the goal predicates — as
 * tables, then every attack of the library as one table whose every cell
 * is derived from the implementation (src/domain/sim/attackLibrary.ts):
 * name, source id in the review report, premise (preset + overrides, d),
 * attacker condition, required capabilities, goal stages, strategy summary
 * and default run. Choosing a row proposes that attack's default run as
 * the scenario's initial conditions and returns to the chain display,
 * where 実行開始 starts the auto-play.
 *
 * The page has its own layout: only the header bar frames it — no slot
 * bar, no dock, no validator count.
 */

import type { ReactNode } from 'react'
import { ATTACK_LIBRARY } from '../../domain'
import type { AttackGoal, LibraryAttack } from '../../domain'
import {
  CAPABILITIES,
  capabilityLabel,
  conditionLabel,
  defaultRunLines,
  premiseLabel,
  stageLabel,
} from '../attackFormat'
import { Button } from '../components/Button'
import { Hint } from '../components/Hint'

export interface AttacksPageProps {
  /** A row was chosen: propose its default run and show the chain display. */
  onSelect(entry: LibraryAttack): void
}

interface Definition {
  readonly term: string
  readonly meaning: string
}

/** 攻撃 = (攻撃者集合の条件, 攻撃目標, 戦略) — 必須 17. */
const TRIPLE: readonly Definition[] = [
  {
    term: '攻撃者集合の条件',
    meaning:
      '攻撃者として振る舞うバリデータの空でない部分集合が満たすべき条件 — 人数の下限（人数 ≥ n）または初期ステーク比率の下限（比率 ≥ θ）— 条件を満たす具体的な集合を束ねたものが攻撃の実行',
  },
  {
    term: '攻撃目標',
    meaning:
      '神視点で毎スロット境界に評価する観測可能な述語の非空な列 — 先頭から順に達成を判定し、末尾まで達成した時点で攻撃目標の達成',
  },
  {
    term: '戦略',
    meaning:
      '各スロット境界で攻撃者の観測状態（全攻撃者の View の合併 — 攻撃者同士は即時・完全に情報共有 — と予定表）を、能力範囲内のその境界での行動へ写す純粋な規則 — 固定の介入列はその特殊ケース',
  },
]

/** 攻撃者の能力範囲の 2 基底 — 必須 18. */
const BASES: readonly Definition[] = [
  {
    term: '公開 (i)',
    meaning:
      '自分名義のメッセージを、任意の内容（ブロックの parent・body と投票の head / source / target は自分の観測状態にあるものからのみ — 偽造不能）で、任意の時機に、任意の受信者集合へ公開 — 保留・選択配送・沈黙を含む',
  },
  {
    term: '配送 (ii)',
    meaning:
      '正直者のメッセージの到達を受信者ごとに遅らせる（公開から最大 d スロット — d は攻撃が前提として宣言する遅延上限）か、欠落させる — 分断はこの対称な集合',
  },
]

/** 攻撃目標述語 — 必須 19. One row per predicate kind. */
const PREDICATES: readonly (Definition & { readonly kind: AttackGoal['kind'] })[] = [
  {
    kind: 'safety-violation',
    term: '安全性違反',
    meaning:
      '公開済みブロック木上に、互いに祖先関係にない 2 つのチェックポイントが存在し、それぞれが自分の枝のチェーン状態で finalized',
  },
  {
    kind: 'liveness-stall',
    term: '活性停止（L）',
    meaning: '公開済みブロック木のどの枝でも、finalized が直近 L スロットの間に進んでいない',
  },
  {
    kind: 'reorg',
    term: 'リオーグ（k）',
    meaning:
      'ある正直バリデータの head が直前スロットの head の子孫でないブロックに移る事象を 1 回と数え、いずれかの正直バリデータで累計 k 回以上（既定 k = 1）',
  },
  {
    kind: 'attacker-stake-ratio',
    term: '攻撃者ステーク比率（θ）',
    meaning:
      'いずれかの正直バリデータの head 枝のチェーン状態で、攻撃者集合の合計ステーク ÷ 全バリデータの合計ステークが θ 以上',
  },
]

const COLUMNS = [
  '攻撃',
  '出典',
  '前提',
  '攻撃者集合の条件',
  '必要な能力',
  '攻撃目標',
  '戦略の要約',
  '既定実行構成',
] as const

function DefinitionTable({
  label,
  caption,
  rows,
  children,
}: {
  readonly label: string
  readonly caption: string
  readonly rows: readonly Definition[]
  readonly children?: ReactNode
}) {
  return (
    <table className="system-table" aria-label={label}>
      <caption>{caption}</caption>
      <tbody>
        {rows.map((row) => (
          <tr key={row.term}>
            <th scope="row">{row.term}</th>
            <td>{row.meaning}</td>
          </tr>
        ))}
        {children}
      </tbody>
    </table>
  )
}

export function AttacksPage({ onSelect }: AttacksPageProps) {
  return (
    <section className="attacks-page" aria-label="攻撃一覧">
      <div className="attacks-system" aria-label="攻撃の形式体系">
        <DefinitionTable
          label="攻撃の 3 つ組"
          caption="攻撃 = (攻撃者集合の条件, 攻撃目標, 戦略)"
          rows={TRIPLE}
        />
        <DefinitionTable label="攻撃者の能力範囲" caption="攻撃者の能力範囲 = 2 つの基底" rows={BASES}>
          <tr>
            <th scope="row">行動語彙（基底の糖衣）</th>
            <td>
              <ul className="vocabulary">
                {CAPABILITIES.map((c) => (
                  <li key={c} className="vocabulary-term">
                    {capabilityLabel(c)}
                  </li>
                ))}
              </ul>
            </td>
          </tr>
        </DefinitionTable>
        <DefinitionTable
          label="攻撃目標述語"
          caption="攻撃目標述語 — 神視点で毎スロット境界に評価"
          rows={PREDICATES}
        />
      </div>

      <h2 className="pane-title">
        攻撃ライブラリ
        <span className="panel-count">{ATTACK_LIBRARY.length} 件</span>
        <Hint text="攻撃ライブラリの全攻撃を実装（src/domain/sim/attackLibrary.ts）から導出して表示。攻撃名を選ぶと、その既定実行構成（バリデータ数・初期ステーク・攻撃者集合・前提・攻撃パラメータ・終了スロット）がシナリオの初期条件として提案されチェーン表示に切り替わる — 変更は任意で、スロットバーの実行開始だけで自動再生が始まる。出典の攻撃 ID は essences/deep-research-report.md のもの" />
      </h2>
      <table className="attack-table" aria-label="攻撃ライブラリ">
        <thead>
          <tr>
            {COLUMNS.map((column) => (
              <th key={column} scope="col">
                {column}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {ATTACK_LIBRARY.map((entry) => (
            <tr key={entry.id} className="attack-row" data-attack={entry.id}>
              <td className="attack-name">
                <Button
                  className="attack-select"
                  aria-label={`攻撃 ${entry.id} を選択`}
                  onClick={() => onSelect(entry)}
                >
                  <span className="attack-id">{entry.id}</span> {entry.name}
                </Button>
              </td>
              <td className="attack-source-cell">{entry.source}</td>
              <td className="attack-premise">{premiseLabel(entry.premise)}</td>
              <td>{conditionLabel(entry.attackers)}</td>
              <td>
                <ul className="attack-capabilities">
                  {entry.capabilities.map((c) => (
                    <li key={c}>{capabilityLabel(c)}</li>
                  ))}
                </ul>
              </td>
              <td>
                <ol className="attack-goal">
                  {entry.goal.map((stage, i) => (
                    <li key={i}>{stageLabel(stage)}</li>
                  ))}
                </ol>
              </td>
              <td className="attack-strategy" data-quoted="library">
                {entry.strategySummary}
              </td>
              <td className="attack-run">
                {defaultRunLines(entry).map((line) => (
                  <div key={line}>{line}</div>
                ))}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  )
}
