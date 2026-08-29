/**
 * Smoke-drives the built app in a real browser and checks the shell
 * behaviours end to end — slot advancing, the four display tabs, the state
 * table, finality badges, network cards and the type catalog.
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

const browser = await chromium.launch()
try {
  const page = await browser.newPage()
  await page.goto(URL_UNDER_TEST)
  await page.waitForSelector('.app')

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

  // Intervention panel is present and discoverable.
  const panelSummary = await page.textContent('.intervention-panel summary')
  check('介入パネル表示', panelSummary?.includes('介入') === true, panelSummary ?? '')

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
