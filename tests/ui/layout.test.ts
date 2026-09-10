// @vitest-environment node
// @ts-nocheck -- a Node-side source-text check (fs/path over src/ui) like
// designTokens.test.ts; the project has no @types/node.
/**
 * Machine check for the instrument's frame (成功条件 26 (a)): the
 * protagonists — the chain display and the state table — own the majority
 * of a standard PC viewport from the first paint, without scrolling.
 *
 * jsdom performs no layout, so the check reads the layout contract itself:
 * the frame is a header bar of --bar-h, a slot bar of --bar-h, and an
 * operation dock of --dock-w; everything else is the stage, which the chain
 * display fills (min-height: 100%). From those three tokens the stage's
 * share of a viewport follows arithmetically, and this test asserts it
 * exceeds one half at the common PC widths. scripts/verify-ui.mjs measures
 * the same quantity in a real browser for the human review (必須 30).
 */

import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'

const UI_ROOT = join(__dirname, '../../src/ui')
const tokensCss = readFileSync(join(UI_ROOT, 'tokens.css'), 'utf8')
const stylesCss = readFileSync(join(UI_ROOT, 'styles.css'), 'utf8')
const appTsx = readFileSync(join(UI_ROOT, 'App.tsx'), 'utf8')
const chainTsx = readFileSync(join(UI_ROOT, 'modes/ChainMode.tsx'), 'utf8')
const geometryTs = readFileSync(join(UI_ROOT, 'treeGeometry.ts'), 'utf8')

function px(token: string): number {
  const m = new RegExp(`${token}\\s*:\\s*(\\d+)px\\s*;`).exec(tokensCss)
  if (!m) throw new Error(`${token} is not defined as a px value in tokens.css`)
  return Number(m[1])
}

function rule(selector: string): string {
  const stripped = stylesCss.replace(/\/\*[\s\S]*?\*\//g, '')
  const re = new RegExp(`(^|[}\\s])${selector.replace(/[.[\]']/g, '\\$&')}\\s*\\{([^}]*)\\}`, 'm')
  const m = re.exec(stripped)
  if (!m) throw new Error(`no rule for ${selector} in styles.css`)
  return m[2]
}

function constant(name: string): number {
  const m = new RegExp(`export const ${name} = (\\d+)`).exec(geometryTs)
  if (!m) throw new Error(`${name} missing from treeGeometry.ts`)
  return Number(m[1])
}

/** Standard PC viewports (CSS px): the common laptop and desktop sizes. */
const VIEWPORTS = [
  { width: 1280, height: 720 },
  { width: 1440, height: 900 },
  { width: 1920, height: 1080 },
]

describe('frame contract: bars and dock are tokens, the stage is the rest', () => {
  it('the app grid is header bar + body, the body is stage + dock', () => {
    expect(rule('.app')).toMatch(/grid-template-rows:\s*var\(--bar-h\)\s+minmax\(0,\s*1fr\)/)
    expect(rule('.app-body')).toMatch(/grid-template-columns:\s*minmax\(0,\s*1fr\)\s+var\(--dock-w\)/)
    expect(rule('.app-header')).toMatch(/height:\s*var\(--bar-h\)/)
    expect(rule('.slot-bar')).toMatch(/height:\s*var\(--bar-h\)/)
  })

  it('the stage and the dock scroll independently; the frame never moves', () => {
    expect(rule('.stage')).toMatch(/overflow:\s*auto/)
    expect(rule('.dock')).toMatch(/overflow:\s*auto/)
    expect(rule('body')).toMatch(/overflow:\s*hidden/)
  })

  it('every control except the slot bar lives in the dock', () => {
    // The three control panels are rendered inside <aside className="dock">.
    const dock = /<aside className="dock"[\s\S]*?<\/aside>/.exec(appTsx)?.[0] ?? ''
    for (const panel of ['<ParamsPanel', '<InterventionPanel', '<ScenarioPanel']) {
      expect(dock, `${panel} is not inside the dock`).toContain(panel)
    }
    // The stage holds the slot bar and the display, nothing else.
    const stage = /<div className="stage">[\s\S]*?<aside/.exec(appTsx)?.[0] ?? ''
    expect(stage).toContain('className="slot-bar"')
    expect(stage).toContain('className="mode-body"')
    expect(stage).not.toContain('Panel')
  })

  it('the chain display fills the stage: tree region above, state table below', () => {
    expect(rule('.chain-mode')).toMatch(/min-height:\s*100%/)
    expect(rule('.chain-scroll')).toMatch(/flex:\s*1/)
    expect(rule('.tree-region')).toMatch(/flex:\s*1/)
    // Order inside the shared scroll container: tree region, then the table.
    const scroll = /className="chain-scroll"[\s\S]*?<StateTable/.exec(chainTsx)?.[0] ?? ''
    expect(scroll).toContain('className="tree-region"')
  })
})

describe('the protagonists own more than half of a standard PC viewport', () => {
  const barH = px('--bar-h')
  const dockW = px('--dock-w')

  for (const { width, height } of VIEWPORTS) {
    it(`${width}×${height}: stage area > 50 % of the viewport`, () => {
      const stageW = width - dockW
      const stageH = height - barH - barH
      const share = (stageW * stageH) / (width * height)
      expect(share, `stage share ${share.toFixed(3)}`).toBeGreaterThan(0.5)
    })
  }

  it('the dock is narrower than the stage at every width', () => {
    for (const { width } of VIEWPORTS) {
      expect(dockW).toBeLessThan(width - dockW)
    }
  })
})

describe('the type catalog page has its own layout (必須 8)', () => {
  it('is rendered outside the stage/dock body, framed by the header bar only', () => {
    const typesAt = appTsx.indexOf('<TypesPage />')
    const bodyAt = appTsx.indexOf('className="app-body"')
    expect(typesAt).toBeGreaterThan(-1)
    expect(typesAt).toBeLessThan(bodyAt)
    // The validator count is a chain-page control.
    expect(appTsx).toMatch(/page === 'chain' && \(\s*<label className="field-inline">/)
  })

  it('splits its width four fifths graph / one fifth focused type and fills the height', () => {
    expect(rule('.types-page')).toMatch(
      /grid-template-columns:\s*minmax\(0,\s*4fr\)\s+minmax\(0,\s*1fr\)/,
    )
    expect(rule('.types-page')).toMatch(/height:\s*100%/)
    expect(rule('.types-scroll')).toMatch(/overflow:\s*auto/)
    expect(rule('.type-detail')).toMatch(/overflow:\s*auto/)
  })
})

describe('about ten slots fit the stage of a PC width (必須 7)', () => {
  it('label column + 10 slot columns fit the 1440-wide stage', () => {
    const dockW = px('--dock-w')
    const colW = constant('COL_W')
    const labelW = constant('LABEL_W')
    const padX = constant('PAD_X')
    const stageW = 1440 - dockW
    expect(labelW + padX * 2 + 10 * colW).toBeLessThanOrEqual(stageW)
    // …but not many more: the slot width is a readable size, not a squeeze.
    expect(labelW + padX * 2 + 13 * colW).toBeGreaterThan(stageW)
  })

  it('a block is drawn large enough to carry its label, proposer and badges', () => {
    expect(constant('BLOCK_W')).toBeGreaterThanOrEqual(56)
    expect(constant('BLOCK_H')).toBeGreaterThanOrEqual(36)
    expect(constant('ROW_H')).toBeGreaterThan(constant('BLOCK_H') * 2)
  })
})
