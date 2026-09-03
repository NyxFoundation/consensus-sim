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

  // Shell: title, slot 0, the three page tabs.
  check('タイトル表示', (await page.textContent('h1')) === 'consensus-sim')
  const slotText = () => page.textContent('.slot-current')
  check('スロット0開始', (await slotText())?.includes('0') === true)
  const tabs = await page.$$eval('.mode-tabs button', (els) => els.map((e) => e.textContent))
  check(
    '3ページタブ',
    JSON.stringify(tabs) === JSON.stringify(['チェーン表示', '攻撃一覧', '型一覧']),
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

  // Type catalog page (必須 8 / 成功条件 2): header bar only — no slot bar,
  // no dock, no validator count; graph pane ≈ 4/5 of the width, focus pane
  // ≈ 1/5; the first type of the top layer is in focus on opening, and
  // selecting a node switches the focus pane to it.
  await page.click('.mode-tabs button:has-text("型一覧")')
  const barH = await page.$eval('.app-header', (el) => el.getBoundingClientRect().height)
  const typeNodes = await page.$$eval('.type-node', (els) => els.length)
  check('型一覧にノード表示', typeNodes > 0, String(typeNodes))
  check('型一覧にスロットバー無し', (await page.$('.slot-bar')) === null)
  check('型一覧に操作盤無し', (await page.$('.dock')) === null)
  check('型一覧にバリデータ数設定無し', (await page.$('.field-inline select')) === null)
  const split = await page.evaluate(() => {
    const pageEl = document.querySelector('.types-page')
    const graph = document.querySelector('.types-graph-pane')
    const focus = document.querySelector('.type-detail')
    if (!pageEl || !graph || !focus) return null
    const w = pageEl.getBoundingClientRect().width
    return {
      graph: graph.getBoundingClientRect().width / w,
      focus: focus.getBoundingClientRect().width / w,
      pageH: pageEl.getBoundingClientRect().height,
      viewH: window.innerHeight,
    }
  })
  check(
    '型一覧は幅の約8割がグラフ・約2割がフォーカス中の型',
    split !== null && split.graph > 0.75 && split.graph < 0.85 && split.focus > 0.15 && split.focus < 0.25,
    JSON.stringify(split),
  )
  check(
    '型一覧はヘッダーバーの下を埋める',
    split !== null && Math.abs(split.viewH - split.pageH - barH) <= 2,
    JSON.stringify(split),
  )
  const initialFocus = await page.evaluate(() => {
    const nodes = [...document.querySelectorAll('.type-node')]
    const minTop = Math.min(...nodes.map((n) => parseInt(n.style.top, 10)))
    const first = nodes
      .filter((n) => parseInt(n.style.top, 10) === minTop)
      .sort((a, b) => parseInt(a.style.left, 10) - parseInt(b.style.left, 10))[0]
    const active = document.querySelector('.type-node.active .type-node-name')
    const heading = document.querySelector('.type-detail h3')
    return {
      first: first?.querySelector('.type-node-name')?.textContent ?? null,
      active: active?.textContent ?? null,
      heading: heading?.textContent ?? null,
    }
  })
  check(
    '開いた直後は最上段の先頭の型がフォーカス',
    initialFocus.first !== null &&
      initialFocus.first === initialFocus.active &&
      (initialFocus.heading ?? '').includes(initialFocus.first),
    JSON.stringify(initialFocus),
  )
  await page.click('.type-node:has-text("Vote")')
  const focusedHeading = await page.textContent('.type-detail h3')
  check('型を選ぶと右側がその型に切り替わる', focusedHeading?.includes('Vote') === true, focusedHeading ?? '')
  const focusedSource = await page.textContent('.type-source')
  check('宣言はコメント込みで表示', focusedSource?.trimStart().startsWith('/**') === true)

  // Attack list page (必須 22 / 成功条件 16・17): header bar only, the
  // formal system's three definition tables before the library table of 12
  // rows; choosing a row returns to the chain display with the default run
  // proposed. Auto-play (必須 31 / 成功条件 28): 実行開始 is the only input —
  // slots advance on the timer and stop at the achievement slot (A11: 4).
  await page.click('.mode-tabs button:has-text("攻撃一覧")')
  check('攻撃一覧にスロットバー無し', (await page.$('.slot-bar')) === null)
  check('攻撃一覧に操作盤無し', (await page.$('.dock')) === null)
  const systemTables = await page.$$eval('.attacks-system table', (els) => els.length)
  check('攻撃一覧の冒頭に形式体系の定義 3 表', systemTables === 3, String(systemTables))
  const attackRows = await page.$$eval('.attack-table tbody tr', (els) => els.length)
  check('攻撃一覧に 12 攻撃の表', attackRows === 12, String(attackRows))
  await page.click('[aria-label="攻撃 A11 を選択"]')
  check(
    '行選択でチェーン表示へ戻り既定実行構成を提案',
    (await page.textContent('.attack-panel .panel-count')) === 'A11' &&
      (await slotText())?.includes('0') === true &&
      (await page.textContent('.play-toggle')) === '実行開始',
  )
  await page.click('.play-toggle')
  await page.waitForFunction(
    () => document.querySelector('.play-toggle')?.textContent === '再開',
    null,
    { timeout: 15_000 },
  )
  const stoppedAt = await page.textContent('.slot-current strong')
  check('実行開始だけで自動再生し達成スロット 4 で停止', stoppedAt === '4', String(stoppedAt))
  check(
    '停止時に判定推移が達成 @s4',
    (await page.textContent('.goal-table th'))?.includes('達成 @s4') === true,
  )
  await page.waitForTimeout(1500)
  check('停止後は進まない', (await page.textContent('.slot-current strong')) === '4')

  // Back on the chain page, a validator count change resets to slot 0.
  await page.click('.mode-tabs button:has-text("チェーン表示")')
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
