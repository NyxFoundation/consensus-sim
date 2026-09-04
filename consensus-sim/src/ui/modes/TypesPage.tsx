/**
 * Type catalog page (型一覧): the exported types of the domain layer's model
 * module (本質的仕様, src/domain/model — the sim module's constraint types
 * are deliberately absent) as a top-down dependency graph — layer 0 (types
 * depending on no other type) on top, every edge pointing from a type down
 * to the types built on it.
 *
 * The page has its own layout (必須 8): the graph pane takes about four
 * fifths of the width, the focus pane the remaining fifth. One type is
 * always in focus — the first type of the top layer when the page opens —
 * and the focus pane shows its verbatim declaration, doc comment included,
 * plus the types it depends on and the types depending on it; selecting
 * any of those, or a node of the graph, moves the focus.
 */

import { useState } from 'react'
import { Button } from '../components/Button'
import { Hint } from '../components/Hint'
import { DOMAIN_SOURCES } from '../domainSources'
import { extractTypeGraph, layoutTypeGraph } from '../typeGraph'

const NODE_W = 172
const NODE_H = 46
const GAP_X = 22
const GAP_Y = 60
const PAD = 12

const GRAPH = layoutTypeGraph(extractTypeGraph(DOMAIN_SOURCES))

/** The type in focus when the page opens: top layer, first column. */
const INITIAL_FOCUS =
  GRAPH.placed.find((p) => p.layer === 0 && p.col === 0)?.node.name ?? ''

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
  const [focus, setFocus] = useState<string>(INITIAL_FOCUS)
  const detail = GRAPH.placed.find((p) => p.node.name === focus)?.node
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
      <div className="types-graph-pane">
        <div className="types-toolbar">
          <span className="pane-title">本質的仕様の型（src/domain/model）</span>
          <Hint
            className="types-caption"
            text="ドメイン層の本質的仕様モジュール（src/domain/model）の型の依存グラフ。最上段 = 他のどの型にも依存しない型で、辺は型からそれを使う型へ下向き。シミュレーション上の制約モジュール（src/domain/sim）の型は含まない。型を選ぶと右側にその定義（コメント込み）と依存先・依存元が表示される"
          />
        </div>
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
                const active = from === focus || to === focus
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
                node.name === focus ? 'active' : '',
                related(node.name) ? 'related' : '',
              ]
                .filter(Boolean)
                .join(' ')
              return (
                <Button
                  key={node.name}
                  className={classes}
                  style={{ left: pos.x, top: pos.y, width: NODE_W, height: NODE_H }}
                  aria-pressed={node.name === focus}
                  onClick={() => setFocus(node.name)}
                >
                  <span className="type-node-name">{node.name}</span>
                  <span className="type-node-module">{node.module}.ts</span>
                </Button>
              )
            })}
          </div>
        </div>
      </div>

      {detail && (
        <aside className="type-detail" aria-label={`${detail.name} の定義`}>
          <h3>
            {detail.name}
            <span className="type-detail-module">
              {detail.kind === 'interface' ? 'interface' : 'type'} ·{' '}
              {detail.module}.ts
            </span>
          </h3>
          <pre className="type-source">
            <code>{detail.declaration}</code>
          </pre>
          <dl className="type-detail-links">
            <dt>依存する型</dt>
            <dd>
              {detail.dependsOn.length > 0
                ? detail.dependsOn.map((d) => (
                    <Button key={d} className="type-link" onClick={() => setFocus(d)}>
                      {d}
                    </Button>
                  ))
                : 'なし（最上段）'}
            </dd>
            <dt>この型に依存する型</dt>
            <dd>
              {dependents.length > 0
                ? dependents.map((d) => (
                    <Button key={d} className="type-link" onClick={() => setFocus(d)}>
                      {d}
                    </Button>
                  ))
                : 'なし'}
            </dd>
          </dl>
        </aside>
      )}
    </section>
  )
}
