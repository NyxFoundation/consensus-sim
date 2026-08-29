/**
 * Type catalog (型一覧) extraction and layout. The domain layer's exported
 * type declarations are read from the actual source text (bundled verbatim
 * via domainSources), so the displayed catalog cannot drift from the
 * implementation: it IS the implementation, re-presented as a top-down
 * dependency graph — types depending on no other type sit on layer 0.
 *
 * The extractor is deliberately small: it understands exactly the
 * declaration shapes the domain layer uses (`export interface X {...}` and
 * `export type X = ...;`), which the tests pin against the real sources.
 */

export interface TypeNode {
  readonly name: string
  readonly kind: 'interface' | 'type'
  /** Domain module (file base name) the declaration lives in. */
  readonly module: string
  /** The declaration's verbatim source text, doc comment included. */
  readonly declaration: string
  /** Names of other extracted types this declaration references. */
  readonly dependsOn: readonly string[]
}

export interface PlacedTypeNode {
  readonly node: TypeNode
  /** 0 = depends on no other type (top row). */
  readonly layer: number
  readonly col: number
}

export interface TypeGraphLayout {
  readonly placed: readonly PlacedTypeNode[]
  readonly layerCount: number
  /** Widest layer's node count. */
  readonly colCount: number
}

/**
 * Replace comments and string literals with spaces of equal length so
 * structural scans (brace matching, identifier search) cannot be fooled by
 * braces or type names inside them, while every index still maps onto the
 * original source.
 */
function shadow(source: string): string {
  const out = source.split('')
  let i = 0
  const blank = (from: number, to: number) => {
    for (let k = from; k < to; k++) {
      if (out[k] !== '\n') out[k] = ' '
    }
  }
  while (i < source.length) {
    const two = source.slice(i, i + 2)
    if (two === '//') {
      const end = source.indexOf('\n', i)
      const stop = end === -1 ? source.length : end
      blank(i, stop)
      i = stop
    } else if (two === '/*') {
      const end = source.indexOf('*/', i + 2)
      const stop = end === -1 ? source.length : end + 2
      blank(i, stop)
      i = stop
    } else if (source[i] === '"' || source[i] === "'" || source[i] === '`') {
      const quote = source[i]
      let k = i + 1
      while (k < source.length && source[k] !== quote) {
        if (source[k] === '\\') k++
        k++
      }
      blank(i + 1, Math.min(k, source.length))
      i = Math.min(k + 1, source.length)
    } else {
      i++
    }
  }
  return out.join('')
}

/** Index of the `}` closing the `{` at `open` (shadowed text), or -1. */
function matchBrace(shadowed: string, open: number): number {
  let depth = 0
  for (let i = open; i < shadowed.length; i++) {
    if (shadowed[i] === '{') depth++
    else if (shadowed[i] === '}' && --depth === 0) return i
  }
  return -1
}

/** Index of the `;` terminating a type alias started at `from`, or -1. */
function aliasEnd(shadowed: string, from: number): number {
  let depth = 0
  for (let i = from; i < shadowed.length; i++) {
    const c = shadowed[i]
    if (c === '{' || c === '(' || c === '[') depth++
    else if (c === '}' || c === ')' || c === ']') depth--
    else if (c === ';' && depth === 0) return i
  }
  return -1
}

/** Extend `start` backwards over a directly attached leading doc comment. */
function includeDocComment(source: string, start: number): number {
  const before = source.slice(0, start)
  const trimmed = before.trimEnd()
  if (!trimmed.endsWith('*/')) return start
  const open = trimmed.lastIndexOf('/*')
  if (open === -1) return start
  // Attached means nothing but whitespace between the comment and the decl.
  return before.slice(trimmed.length).trim() === '' ? open : start
}

const DECL_RE = /^export (interface|type) ([A-Za-z_$][A-Za-z0-9_$]*)/gm

export function extractTypeGraph(
  sources: Readonly<Record<string, string>>,
): TypeNode[] {
  interface Draft {
    name: string
    kind: 'interface' | 'type'
    module: string
    declaration: string
    body: string
  }
  const drafts: Draft[] = []

  for (const [module, source] of Object.entries(sources)) {
    const shadowed = shadow(source)
    for (const m of shadowed.matchAll(DECL_RE)) {
      const kind = m[1] === 'interface' ? 'interface' : 'type'
      const name = m[2]
      const at = m.index
      if (name === undefined || at === undefined) continue
      let end: number
      if (kind === 'interface') {
        const open = shadowed.indexOf('{', at)
        end = open === -1 ? -1 : matchBrace(shadowed, open)
        if (end !== -1) end += 1
      } else {
        end = aliasEnd(shadowed, at)
        if (end !== -1) end += 1
      }
      if (end === -1) continue
      const start = includeDocComment(source, at)
      drafts.push({
        name,
        kind,
        module,
        declaration: source.slice(start, end).trim(),
        body: shadowed.slice(at, end),
      })
    }
  }

  const names = new Set(drafts.map((d) => d.name))
  return drafts.map(({ body, ...draft }) => {
    const deps = new Set<string>()
    for (const id of body.matchAll(/[A-Za-z_$][A-Za-z0-9_$]*/g)) {
      const word = id[0]
      if (word !== draft.name && names.has(word)) deps.add(word)
    }
    return { ...draft, dependsOn: [...deps].sort() }
  })
}

/**
 * Assign layers top-down: layer 0 = no dependencies, otherwise
 * 1 + max(dependency layers). Within a layer, columns order by the mean
 * column of the dependencies (then by name) to keep edges short. The domain
 * type graph is acyclic; a cycle, should one ever appear, is broken by
 * ignoring the back edge rather than looping.
 */
export function layoutTypeGraph(nodes: readonly TypeNode[]): TypeGraphLayout {
  const byName = new Map(nodes.map((n) => [n.name, n]))
  const layers = new Map<string, number>()
  const visiting = new Set<string>()

  const layerOf = (name: string): number => {
    const known = layers.get(name)
    if (known !== undefined) return known
    if (visiting.has(name)) return 0
    visiting.add(name)
    const node = byName.get(name)
    const deps = node?.dependsOn ?? []
    const layer =
      deps.length === 0
        ? 0
        : 1 + Math.max(...deps.map((d) => layerOf(d)))
    visiting.delete(name)
    layers.set(name, layer)
    return layer
  }
  for (const n of nodes) layerOf(n.name)

  const rows = new Map<number, TypeNode[]>()
  for (const n of nodes) {
    const layer = layers.get(n.name) ?? 0
    const row = rows.get(layer) ?? []
    row.push(n)
    rows.set(layer, row)
  }

  const cols = new Map<string, number>()
  const placed: PlacedTypeNode[] = []
  const layerCount = rows.size === 0 ? 0 : Math.max(...rows.keys()) + 1
  let colCount = 0
  for (let layer = 0; layer < layerCount; layer++) {
    const row = rows.get(layer) ?? []
    const key = (n: TypeNode): number => {
      const depCols = n.dependsOn
        .map((d) => cols.get(d))
        .filter((c): c is number => c !== undefined)
      return depCols.length === 0
        ? Number.MAX_SAFE_INTEGER
        : depCols.reduce((a, b) => a + b, 0) / depCols.length
    }
    row.sort((a, b) => key(a) - key(b) || a.name.localeCompare(b.name, 'en'))
    row.forEach((n, col) => {
      cols.set(n.name, col)
      placed.push({ node: n, layer, col })
    })
    colCount = Math.max(colCount, row.length)
  }
  return { placed, layerCount, colCount }
}
