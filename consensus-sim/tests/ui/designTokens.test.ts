// @vitest-environment node
// @ts-nocheck -- this file is a Node-side source-text check (fs/path over
// src/ui), not application code; the project has no @types/node (adding a
// dependency is out of scope for a design-token change) so the Node built-ins
// below are untyped here. vitest runs it directly regardless of tsc, and its
// assertions are exercised by `npx vitest run` like every other test.
/**
 * Machine check for the design-token foundation (no jsdom, no render — this
 * reads the source files themselves): styles.css spends no colour, length
 * or font literal of its own, tokens.css is the single place any such
 * custom property is defined, every native form control outside the
 * components directory goes through the unified components, and no inline
 * style block smuggles a colour or a font declaration back in. Each
 * assertion names the offending file and line so a regression is easy to
 * place.
 */

import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, relative } from 'node:path'
import { describe, expect, it } from 'vitest'

const UI_ROOT = join(__dirname, '../../src/ui')

function walk(dir: string, predicate: (path: string) => boolean): string[] {
  const out: string[] = []
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry)
    const st = statSync(full)
    if (st.isDirectory()) {
      out.push(...walk(full, predicate))
    } else if (predicate(full)) {
      out.push(full)
    }
  }
  return out
}

function lineOf(text: string, index: number): number {
  return text.slice(0, index).split('\n').length
}

/** Every non-comment `property: value;` declaration in a CSS source, with
 * its 1-based line number. Strips /* *\/ comments first so example text
 * inside a doc comment never counts as a real declaration. */
function declarations(css: string): { property: string; value: string; line: number }[] {
  const stripped = css.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, ' '))
  const out: { property: string; value: string; line: number }[] = []
  const re = /([a-zA-Z-]+)\s*:\s*([^;{}]+);/g
  let m: RegExpExecArray | null
  while ((m = re.exec(stripped))) {
    out.push({ property: m[1]!.trim(), value: m[2]!.trim(), line: lineOf(css, m.index) })
  }
  return out
}

const stylesPath = join(UI_ROOT, 'styles.css')
const tokensPath = join(UI_ROOT, 'tokens.css')
const stylesCss = readFileSync(stylesPath, 'utf8')
const tokensCss = readFileSync(tokensPath, 'utf8')

describe('styles.css: colour, length and font-family are tokens only', () => {
  it('has no colour literal (#hex / rgb( / hsl()', () => {
    const stripped = stylesCss.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, ' '))
    const offences: string[] = []
    const hexRe = /#[0-9a-fA-F]{3,8}\b/g
    let m: RegExpExecArray | null
    while ((m = hexRe.exec(stripped))) {
      offences.push(`line ${lineOf(stylesCss, m.index)}: ${m[0]}`)
    }
    for (const fn of ['rgb(', 'hsl('] as const) {
      let from = 0
      let idx: number
      while ((idx = stripped.indexOf(fn, from)) !== -1) {
        offences.push(`line ${lineOf(stylesCss, idx)}: ${fn}`)
        from = idx + fn.length
      }
    }
    expect(offences, `colour literal(s) in styles.css:\n${offences.join('\n')}`).toEqual([])
  })

  it('declares font-family only as a single var(--font-…) reference', () => {
    const offences: string[] = []
    for (const d of declarations(stylesCss)) {
      if (d.property !== 'font-family') continue
      if (!/^var\(--font-[a-z-]+\)$/.test(d.value)) {
        offences.push(`line ${d.line}: font-family: ${d.value};`)
      }
    }
    expect(offences, `non-token font-family in styles.css:\n${offences.join('\n')}`).toEqual([])
  })

  it('uses only var(--…) for px lengths in margin/padding/gap/font-size/border-radius', () => {
    const restricted = new Set([
      'margin',
      'padding',
      'gap',
      'row-gap',
      'column-gap',
      'font-size',
      'border-radius',
    ])
    const offences: string[] = []
    for (const d of declarations(stylesCss)) {
      const base = d.property.replace(/-(top|right|bottom|left|inline|block)$/, '')
      if (!restricted.has(d.property) && !restricted.has(base)) continue
      if (/\d+px/.test(d.value)) {
        offences.push(`line ${d.line}: ${d.property}: ${d.value};`)
      }
    }
    expect(offences, `raw px in a spacing/type declaration:\n${offences.join('\n')}`).toEqual([])
  })
})

describe('tokens.css is the single source of design tokens', () => {
  it('is the only CSS file defining a colour/space/text/font custom property', () => {
    const cssFiles = walk(UI_ROOT, (p) => p.endsWith('.css') && p !== tokensPath)
    const offences: string[] = []
    const customPropRe = /(^|[^-\w])--(color|surface|plane|ink|gridline|baseline|neutral|accent|status|control|block-fill|validator|space|text|leading|font|radius|border)[a-zA-Z0-9-]*\s*:/g
    for (const file of cssFiles) {
      const content = readFileSync(file, 'utf8')
      let m: RegExpExecArray | null
      while ((m = customPropRe.exec(content))) {
        offences.push(`${relative(UI_ROOT, file)}:${lineOf(content, m.index)}`)
      }
    }
    expect(
      offences,
      `a design-token custom property was defined outside tokens.css:\n${offences.join('\n')}`,
    ).toEqual([])
  })

  it('defines the three typeface tokens', () => {
    for (const token of ['--font-en', '--font-ja', '--font-mono']) {
      expect(tokensCss, `${token} missing from tokens.css`).toContain(`${token}:`)
    }
  })
})

describe('every native form control outside components/ is a unified component', () => {
  it('has no bare <select, <input, <button, <details or <textarea', () => {
    const tsxFiles = walk(UI_ROOT, (p) => p.endsWith('.tsx')).filter(
      (p) => !relative(UI_ROOT, p).replace(/\\/g, '/').startsWith('components/'),
    )
    const offences: string[] = []
    const bareRe = /<(select|input|button|details|textarea)(\s|>)/g
    for (const file of tsxFiles) {
      const content = readFileSync(file, 'utf8')
      let m: RegExpExecArray | null
      while ((m = bareRe.exec(content))) {
        offences.push(`${relative(UI_ROOT, file)}:${lineOf(content, m.index)}: <${m[1]}`)
      }
    }
    expect(offences, `bare native control(s) outside components/:\n${offences.join('\n')}`).toEqual(
      [],
    )
  })
})

describe('inline style={{…}} carries no colour or font declaration', () => {
  it('has no colour literal and no fontFamily/fontSize key (geometry keys are allowed)', () => {
    const tsxFiles = walk(UI_ROOT, (p) => p.endsWith('.tsx'))
    const offences: string[] = []
    const styleBlockRe = /style=\{\{([^}]*)\}\}/g
    for (const file of tsxFiles) {
      const content = readFileSync(file, 'utf8')
      let m: RegExpExecArray | null
      while ((m = styleBlockRe.exec(content))) {
        const block = m[1]!
        const line = lineOf(content, m.index)
        if (/#[0-9a-fA-F]{3,8}\b|rgb\(|hsl\(/.test(block)) {
          offences.push(`${relative(UI_ROOT, file)}:${line}: colour literal in style={{ ${block.trim()} }}`)
        }
        if (/\bfontFamily\s*:/.test(block) || /\bfontSize\s*:/.test(block)) {
          offences.push(`${relative(UI_ROOT, file)}:${line}: fontFamily/fontSize in style={{ ${block.trim()} }}`)
        }
      }
    }
    expect(offences, `inline style violation(s):\n${offences.join('\n')}`).toEqual([])
  })
})

describe('mono / text-face application', () => {
  it('applies --font-mono to slot/number/id-shaped selectors', () => {
    const monoSelectors = [
      '.slot-label',
      '.block-label',
      '.state-cell',
      '.slot-input',
      '.type-node-name',
    ]
    for (const selector of monoSelectors) {
      const re = new RegExp(
        `${selector.replace(/[.[\]']/g, '\\$&')}\\s*\\{[^}]*font-family:\\s*var\\(--font-mono\\)`,
      )
      expect(re.test(stylesCss), `${selector} does not apply var(--font-mono)`).toBe(true)
    }
  })

  it('applies --font-text to body', () => {
    expect(/\bbody\s*\{[^}]*font-family:\s*var\(--font-text\)/.test(stylesCss)).toBe(true)
  })
})
