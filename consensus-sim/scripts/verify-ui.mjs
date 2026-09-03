/**
 * Smoke-drives the built app in a real browser and checks the shell
 * behaviours end to end — slot advancing, the four display tabs, the state
 * table, finality badges, network cards and the type catalog — and measures
 * the instrument's frame at standard PC viewports: the chain display and
 * the state table own more than half of the first paint without scrolling,
 * no form control keeps the browser's default look, no panel carries
 * resident prose, the theme follows the OS and a manual choice overrides
 * it, and the three typeface roles are applied.
 *
 * The build uses `base: './'`, so dist/index.html loads directly from a
 * file:// URL; no web server is needed (the app is a static SPA by design).
 *
 * Usage: npm run build && node scripts/verify-ui.mjs
 * Exit 0 iff every check passes.
 */

import { fileURLToPath } from 'node:url'
import { chromium } from 'playwright'

const distIndex = fileURLToPath(new URL('../dist/index.html', import.meta.url))
const URL_UNDER_TEST = `file://${distIndex}`

const failures = []
function check(name, ok, detail = '') {
  const mark = ok ? 'ok' : 'FAIL'
  console.log(`[${mark}] ${name}${detail ? ` — ${detail}` : ''}`)
  if (!ok) failures.push(name)
}

/** Area of the element's box clipped to the viewport, as a share of it. */
const viewportShare = (page, selector) =>
  page.$eval(selector, (el) => {
    const r = el.getBoundingClientRect()
    const w = Math.max(0, Math.min(r.right, innerWidth) - Math.max(r.left, 0))
    const h = Math.max(0, Math.min(r.bottom, innerHeight) - Math.max(r.top, 0))
    return (w * h) / (innerWidth * innerHeight)
  })

const browser = await chromium.launch()
try {
  // ---- the frame at standard PC viewports (成功条件 26 (a)) ----
  for (const viewport of [
    { width: 1280, height: 720 },
    { width: 1440, height: 900 },
    { width: 1920, height: 1080 },
  ]) {
    const framed = await browser.newPage({ viewport })
    await framed.goto(URL_UNDER_TEST)
    await framed.waitForSelector('.chain-mode')
    const tag = `${viewport.width}×${viewport.height}`
    const share = await viewportShare(framed, '.chain-mode .chain-scroll')
    check(`${tag}: 初期表示でチェーン表示+状態表が画面の過半`, share > 0.5, share.toFixed(3))
    const tableVisible = await framed.$eval(
      '.state-table',
      (el) => el.getBoundingClientRect().bottom <= innerHeight,
    )
    check(`${tag}: 状態表がスクロールなしに見える`, tableVisible)
    const dockShare = await viewportShare(framed, '.dock')
    check(`${tag}: 操作盤は主役より小さい`, dockShare < share, dockShare.toFixed(3))
    const noScroll = await framed.evaluate(
      () => scrollY === 0 && document.documentElement.scrollHeight <= innerHeight,
    )
    check(`${tag}: ページ自体はスクロールしない`, noScroll)
    // Ten slot columns fit the stage width (必須 7).
    for (let i = 0; i < 9; i++) await framed.click('.advance')
    const tenFit = await framed.$eval('.chain-scroll', (el) => el.scrollWidth <= el.clientWidth)
    check(`${tag}: 10 スロット分の列が横スクロールなしに収まる`, tenFit)
    await framed.close()
  }

  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } })
  await page.goto(URL_UNDER_TEST)
  await page.waitForSelector('.app')

  // ---- (b) no browser-default form control ----
  const bare = await page.$$eval('select, input, button, details', (els) =>
    els
      .filter((el) => el.tagName !== 'DETAILS' && getComputedStyle(el).appearance !== 'none')
      .map((el) => `${el.tagName.toLowerCase()}${el.className ? `.${el.className}` : ''}`),
  )
  check('ブラウザ既定の見た目のフォーム部品がない', bare.length === 0, bare.join(', '))

  // ---- (c) no resident prose: no sentence text node, hints in attributes ----
  const sentences = await page.evaluate(() => {
    const out = []
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT)
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
      if ((n.textContent ?? '').includes('。')) out.push(n.textContent.trim())
    }
    return out
  })
  check('パネル常駐の説明文がない', sentences.length === 0, sentences.join(' / '))
  check('ⓘ の説明はホバー前は非表示', (await page.$('.hint-tooltip')) === null)
  const dockHints = await page.$$('.dock [data-ui="hint"]')
  await dockHints[dockHints.length - 1].hover()
  const tooltip = await page.$eval('.hint-tooltip', (el) => {
    const r = el.getBoundingClientRect()
    return {
      text: el.textContent ?? '',
      inViewport: r.left >= 0 && r.right <= innerWidth && r.top >= 0,
    }
  })
  check('ⓘ にホバーすると説明を表示', tooltip.text.length > 0)
  check('ⓘ の説明は画面内に収まる（操作盤に切り取られない）', tooltip.inViewport)
  await page.mouse.move(0, 0)
  check('ホバーを外すと説明が消える', (await page.$('.hint-tooltip')) === null)

  // ---- (e) theme: OS preference by default, manual override ----
  const bg = () => page.evaluate(() => getComputedStyle(document.body).backgroundColor)
  await page.emulateMedia({ colorScheme: 'light' })
  const lightBg = await bg()
  await page.emulateMedia({ colorScheme: 'dark' })
  const darkBg = await bg()
  check('テーマは OS 設定に追従（自動）', lightBg !== darkBg, `${lightBg} / ${darkBg}`)
  await page.click('.theme-toggle button:has-text("ライト")')
  check('手動切替（ライト）が OS 設定を上書き', (await bg()) === lightBg)
  await page.click('.theme-toggle button:has-text("自動")')
  await page.emulateMedia({ colorScheme: 'light' })

  // ---- (f) three typeface roles applied ----
  const fonts = await page.evaluate(() => ({
    body: getComputedStyle(document.body).fontFamily,
    mono: getComputedStyle(document.querySelector('.slot-current strong')).fontFamily,
    tokens: {
      text: getComputedStyle(document.documentElement).getPropertyValue('--font-text').trim(),
      mono: getComputedStyle(document.documentElement).getPropertyValue('--font-mono').trim(),
    },
  }))
  check('本文に --font-text', fonts.body.length > 0 && fonts.body !== fonts.mono, fonts.body)
  check('数値・ID に --font-mono', /mono|Menlo|Consolas/i.test(fonts.mono), fonts.mono)

  // Shell: title, slot 0, the four display tabs.
  check('タイトル表示', (await page.textContent('h1')) === 'consensus-sim')
  const slotText = () => page.textContent('.slot-current')
  check('スロット0開始', (await slotText())?.includes('0') === true)
  const tabs = await page.$$eval('.mode-tabs button', (els) => els.map((e) => e.textContent))
  check(
    '4表示タブ',
    JSON.stringify(tabs) ===
      JSON.stringify(['チェーン表示', 'ネットワーク表示', '全体表示', '型一覧']),
    String(tabs),
  )

  // Slot 0: anchor block only.
  const blockCount = () => page.$$eval('.tree-block', (els) => els.length)
  check('スロット0はブロック1個(錨)', (await blockCount()) === 1)

  // Advance 4 slots: a block per slot, every validator voting.
  for (let i = 0; i < 4; i++) await page.click('.advance')
  check('スロット4へ前進', (await slotText())?.includes('4') === true)
  check('ブロック5個(錨+4提案)', (await blockCount()) === 5, String(await blockCount()))
  const voteRows = await page.$$eval('.vote-table tbody tr', (els) => els.length)
  check('投票テーブルに全バリデータ', voteRows === 4, String(voteRows))

  // The chain display always overlays every validator; katakana names, no
  // perspective toggle.
  const headsStatus = await page.textContent('.status-list')
  check('全バリデータのheadを重ね表示', headsStatus?.includes('アリス') === true, headsStatus ?? '')

  // State table: one row per validator, slot columns aligned under the tree.
  const tableRows = await page.$$eval('.state-table tbody tr', (els) => els.length)
  check('状態表に全バリデータ行', tableRows === 4, String(tableRows))

  // Finality after 8+ slots: every finalized checkpoint carries F (anchor
  // plus the finalized epoch checkpoint), never just the latest one.
  for (let i = 0; i < 5; i++) await page.click('.advance')
  const finalizedBadges = await page.$$eval('.badge-finalized', (els) => els.length)
  check('スロット9でFバッジ2個(錨+確定CP)', finalizedBadges === 2, String(finalizedBadges))

  // The operation dock holds the three control panels, each summarized.
  const panelSummary = await page.textContent('.dock .intervention-panel summary')
  check('操作盤に介入パネル', panelSummary?.includes('介入') === true, panelSummary ?? '')
  const dockSections = await page.$$eval('.dock .dock-section', (els) => els.length)
  check('操作盤は 3 区画', dockSections === 3, String(dockSections))

  // Network display: one card per validator; hovering opens the local view.
  await page.click('.mode-tabs button:has-text("ネットワーク表示")')
  const cards = await page.$$eval('.validator-card', (els) => els.length)
  check('ネットワーク表示にカード4枚', cards === 4, String(cards))
  await page.hover('.validator-card')
  check('カードhoverで局所ビュー表示', (await page.$('.network-detail')) !== null)

  // Global display: chain pane and network pane side by side.
  await page.click('.mode-tabs button:has-text("全体表示")')
  check('全体表示は2ペイン', (await page.$$eval('.global-pane', (els) => els.length)) === 2)

  // Type catalog: the dependency graph renders nodes.
  await page.click('.mode-tabs button:has-text("型一覧")')
  const typeNodes = await page.$$eval('.type-node', (els) => els.length)
  check('型一覧にノード表示', typeNodes > 0, String(typeNodes))

  // Validator count change resets to slot 0.
  await page.selectOption('.field-inline select', '7')
  check('7体設定でスロット0へ', (await slotText())?.includes('0') === true)
} finally {
  await browser.close()
}

if (failures.length > 0) {
  console.error(`\n${failures.length} check(s) failed`)
  process.exit(1)
}
console.log('\nall checks passed')
