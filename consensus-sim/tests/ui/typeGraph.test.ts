// Type catalog (型一覧): the extractor reads the domain layer's real
// source text, so these tests pin both the extractor's mechanics (on a
// synthetic module) and the resulting catalog's fidelity to the shipped
// implementation (on the bundled domain sources).

import { describe, expect, it } from 'vitest'
import { DOMAIN_SOURCES } from '../../src/ui/domainSources'
import { extractTypeGraph, layoutTypeGraph } from '../../src/ui/typeGraph'

describe('extractTypeGraph (synthetic sources)', () => {
  const synthetic = {
    mod: [
      '/** Doc of A. */',
      'export interface A {',
      '  readonly n: number // a C mention in a comment must not count',
      '}',
      '',
      'export type B = A | "C"; // the string literal C must not count either',
      '',
      'export interface C {',
      '  readonly a: A',
      '  readonly b: B',
      '}',
      '',
      'const internal: A = { n: 0 }',
      'export const NOT_A_TYPE = internal',
    ].join('\n'),
  }
  const nodes = extractTypeGraph(synthetic)
  const byName = new Map(nodes.map((n) => [n.name, n]))

  it('extracts exported interfaces and type aliases only', () => {
    expect([...byName.keys()].sort()).toEqual(['A', 'B', 'C'])
  })

  it('keeps the attached doc comment in the declaration text', () => {
    expect(byName.get('A')?.declaration).toBe(
      '/** Doc of A. */\nexport interface A {\n  readonly n: number // a C mention in a comment must not count\n}',
    )
  })

  it('finds dependencies while ignoring comments and string literals', () => {
    expect(byName.get('A')?.dependsOn).toEqual([])
    expect(byName.get('B')?.dependsOn).toEqual(['A'])
    expect(byName.get('C')?.dependsOn).toEqual(['A', 'B'])
  })

  it('lays the graph out top-down with no-dependency types on layer 0', () => {
    const layout = layoutTypeGraph(nodes)
    const layerOf = new Map(layout.placed.map((p) => [p.node.name, p.layer]))
    expect(layerOf.get('A')).toBe(0)
    expect(layerOf.get('B')).toBe(1)
    expect(layerOf.get('C')).toBe(2)
  })
})

describe('domain type catalog (実装との一致)', () => {
  const nodes = extractTypeGraph(DOMAIN_SOURCES)
  const byName = new Map(nodes.map((n) => [n.name, n]))
  const layout = layoutTypeGraph(nodes)
  const layerOf = new Map(layout.placed.map((p) => [p.node.name, p.layer]))

  it('contains the domain vocabulary', () => {
    for (const name of [
      'ValidatorIndex',
      'SlotIndex',
      'BlockIndex',
      'Block',
      'Vote',
      'View',
      'BlockTree',
      'MessageRef',
      'Delivery',
      'Intervention',
      'SimulationConfig',
      'SimulationState',
      'Scenario',
    ]) {
      expect(byName.has(name), `missing type: ${name}`).toBe(true)
    }
  })

  it('every declaration is a verbatim slice of its module source', () => {
    for (const node of nodes) {
      const source = DOMAIN_SOURCES[node.module]
      expect(source, `missing module: ${node.module}`).toBeDefined()
      expect(source ?? '').toContain(node.declaration)
    }
  })

  it('reference types carry their reference-implementation dependencies', () => {
    expect(byName.get('Vote')?.dependsOn).toEqual([
      'BlockIndex',
      'SlotIndex',
      'ValidatorIndex',
    ])
    expect(byName.get('View')?.dependsOn).toEqual(
      expect.arrayContaining(['BlockTree', 'Vote']),
    )
    expect(byName.get('Intervention')?.dependsOn).toEqual(
      expect.arrayContaining(['PartitionIntervention', 'StopIntervention']),
    )
  })

  it('index primitives sit on the top layer', () => {
    expect(layerOf.get('ValidatorIndex')).toBe(0)
    expect(layerOf.get('SlotIndex')).toBe(0)
    expect(layerOf.get('BlockIndex')).toBe(0)
  })

  it('every dependency points to a strictly higher (smaller-index) layer', () => {
    for (const { node } of layout.placed) {
      for (const dep of node.dependsOn) {
        const nodeLayer = layerOf.get(node.name) ?? -1
        const depLayer = layerOf.get(dep) ?? -1
        expect(
          depLayer,
          `${node.name} (layer ${nodeLayer}) depends on ${dep} (layer ${depLayer})`,
        ).toBeLessThan(nodeLayer)
      }
    }
  })
})
