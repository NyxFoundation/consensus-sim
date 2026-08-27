/**
 * Smoke-drives the built app in a real browser and checks the shell
 * behaviours end to end — slot advancing, the three mode tabs, and the
 * chain mode's local/god perspective toggle.
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

  // Shell: title, slot 0, three mode tabs.
  check('タイトル表示', (await page.textContent('h1')) === 'consensus-sim')
  const slotText = () => page.textContent('.slot-current')
  check('スロット0開始', (await slotText())?.includes('0') === true)
  const tabs = await page.$$eval('.mode-tabs button', (els) => els.map((e) => e.textContent))
  check(
    '3モードタブ',
    JSON.stringify(tabs) ===
      JSON.stringify(['チェーンモード', 'ネットワークモード', '全体モード']),
    String(tabs),
  )

  // Slot 0: anchor block only.
  const blockCount = () => page.$$eval('.tree-block', (els) => els.length)
  check('スロット0はブロック1個(錨)', (await blockCount()) === 1)

  // Advance 4 slots: a block per slot.
  for (let i = 0; i < 4; i++) await page.click('.advance')
  check('スロット4へ前進', (await slotText())?.includes('4') === true)
  check('ブロック5個(錨+4提案)', (await blockCount()) === 5, String(await blockCount()))
  const voteRows = await page.$$eval('.vote-table tbody tr', (els) => els.length)
  check('投票テーブルに全バリデータ', voteRows === 4, String(voteRows))

  // God perspective: heads of all validators shown.
  await page.click('.segmented button:has-text("神視点")')
  const godStatus = await page.textContent('.status-list')
  check('神視点で各headを表示', godStatus?.includes('V0:') === true, godStatus ?? '')

  // Back to local, select validator 2.
  await page.click('.segmented button:has-text("局所視点")')
  await page.click('.segmented button:has-text("V2")')
  const localHeading = await page.textContent('.panel h3')
  check('V2の局所状態表示', localHeading?.includes('V2') === true, localHeading ?? '')

  // Finality after 8+ slots: a finalized checkpoint past the anchor gets its F badge.
  for (let i = 0; i < 5; i++) await page.click('.advance')
  const status = await page.textContent('.status-list')
  check('スロット9でfinalized表示', /finalized/.test(status ?? ''), status ?? '')
  const finalizedBadge = await page.$$eval('.badge-finalized', (els) => els.length)
  check('Fバッジ表示', finalizedBadge === 1, String(finalizedBadge))

  // Network / global modes render their sections.
  await page.click('.mode-tabs button:has-text("ネットワークモード")')
  check(
    'ネットワークモード表示',
    (await page.textContent('.mode-placeholder h2'))?.includes('ネットワーク') === true,
  )
  await page.click('.mode-tabs button:has-text("全体モード")')
  check(
    '全体モード表示',
    (await page.textContent('.mode-placeholder h2'))?.includes('全体') === true,
  )

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
