/**
 * Type catalog page (型一覧): the exported types of the domain layer's model
 * module (本質的仕様, src/domain/model — the sim module's constraint types
 * are deliberately absent) as a
 * top-down dependency graph — layer 0 (types depending on no other type) on
 * top, every edge pointing from a type down to the types built on it.
 * Selecting a node shows its verbatim source declaration, so what the page
 * states is exactly what the implementation defines.
 */

import { useState } from 'react'
import { DOMAIN_SOURCES } from '../domainSources'
import { extractTypeGraph, layoutTypeGraph } from '../typeGraph'

const NODE_W = 172
const NODE_H = 46
const GAP_X = 22
const GAP_Y = 60
const PAD = 12

const GRAPH = layoutTypeGraph(extractTypeGraph(DOMAIN_SOURCES))

const POSITIONS = new Map(
  GRAPH.placed.map((p) => [
    p.node.name,
    {
      x: PAD + p.col * (NODE_W + GAP_X),
      y: PAD + p.layer * (NODE_H + GAP_Y),
    },
  ]),
)

const EDGES = GRAPH.placed.flatMap((p) =>
  p.node.dependsOn.map((dep) => ({ from: dep, to: p.node.name })),
)

const WIDTH = PAD * 2 + GRAPH.colCount * (NODE_W + GAP_X) - GAP_X
const HEIGHT = PAD * 2 + GRAPH.layerCount * (NODE_H + GAP_Y) - GAP_Y

export function TypesPage() {
  const [selected, setSelected] = useState<string | undefined>(undefined)
  const detail = GRAPH.placed.find((p) => p.node.name === selected)?.node
  const dependents = detail
    ? GRAPH.placed
        .filter((p) => p.node.dependsOn.includes(detail.name))
        .map((p) => p.node.name)
    : []
  const related = (name: string): boolean =>
    detail !== undefined &&
    (detail.dependsOn.includes(name) || dependents.includes(name))

  return (
    <section className="types-page" aria-label="型一覧">
      <p className="types-caption">
        ドメイン層の本質的仕様モジュール（src/domain/model）の型の依存グラフ（最上段 =
        他のどの型にも依存しない型）。シミュレーション上の制約モジュール（src/domain/sim）の
        型は含みません。型を選択すると実装の定義がそのまま表示されます。
      </p>
      <div className="types-scroll">
        <div
          className="type-graph"
          style={{ width: WIDTH, height: HEIGHT }}
          role="group"
          aria-label="型の依存グラフ"
        >
          <svg
            className="type-edges"
            width={WIDTH}
            height={HEIGHT}
            aria-hidden="true"
          >
            {EDGES.map(({ from, to }) => {
              const a = POSITIONS.get(from)
              const b = POSITIONS.get(to)
              if (!a || !b) return null
              const active =
                selected !== undefined && (from === selected || to === selected)
              return (
                <line
                  key={`${from}->${to}`}
                  className={active ? 'type-edge type-edge-active' : 'type-edge'}
                  x1={a.x + NODE_W / 2}
                  y1={a.y + NODE_H}
                  x2={b.x + NODE_W / 2}
                  y2={b.y}
                />
              )
            })}
          </svg>
          {GRAPH.placed.map(({ node }) => {
            const pos = POSITIONS.get(node.name)
            if (!pos) return null
            const classes = [
              'type-node',
              node.name === selected ? 'active' : '',
              related(node.name) ? 'related' : '',
            ]
              .filter(Boolean)
              .join(' ')
            return (
              <button
                type="button"
                key={node.name}
                className={classes}
                style={{ left: pos.x, top: pos.y, width: NODE_W, height: NODE_H }}
                aria-pressed={node.name === selected}
                onClick={() =>
                  setSelected(node.name === selected ? undefined : node.name)
                }
              >
                <span className="type-node-name">{node.name}</span>
                <span className="type-node-module">{node.module}.ts</span>
              </button>
            )
          })}
        </div>
      </div>

      {detail ? (
        <aside className="type-detail" aria-label={`${detail.name} の定義`}>
          <h3>
            {detail.name}
            <span className="type-detail-module">
              {detail.kind === 'interface' ? 'interface' : 'type'} ·{' '}
              {detail.module}.ts
            </span>
          </h3>
          <dl className="type-detail-links">
            <dt>依存する型</dt>
            <dd>
              {detail.dependsOn.length > 0
                ? detail.dependsOn.map((d) => (
                    <button
                      type="button"
                      key={d}
                      className="type-link"
                      onClick={() => setSelected(d)}
                    >
                      {d}
                    </button>
                  ))
                : 'なし（最上段）'}
            </dd>
            <dt>この型に依存する型</dt>
            <dd>
              {dependents.length > 0
                ? dependents.map((d) => (
                    <button
                      type="button"
                      key={d}
                      className="type-link"
                      onClick={() => setSelected(d)}
                    >
                      {d}
                    </button>
                  ))
                : 'なし'}
            </dd>
          </dl>
          <pre className="type-source">
            <code>{detail.declaration}</code>
          </pre>
        </aside>
      ) : (
        <p className="empty-hint">
          グラフ上の型を選択すると、実装ソースの定義と依存関係の詳細が表示されます。
        </p>
      )}
    </section>
  )
}
