/**
 * Drives the deployed simulator in a real browser and captures what it looks
 * like while it is running.
 *
 * The point is the running part. Every check up to now read a still page: the
 * automation surface available earlier never ticked requestAnimationFrame, so
 * the clock never advanced and no propagation curve ever climbed. Sizes and
 * colours could be measured; motion could not be seen at all.
 *
 * Usage: node scripts/verify-visual.mjs [url] [outDir]
 */

import { chromium } from 'playwright'
import { mkdir } from 'node:fs/promises'

const url = process.argv[2] ?? 'https://adust09.github.io/consensus-sim/'
const outDir = process.argv[3] ?? '/tmp/consensus-shots'

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

async function readStats(page) {
  return page.$$eval('.stat', (cells) => cells.map((cell) => cell.textContent))
}

async function setSlider(page, labelText, value) {
  await page.evaluate(
    ({ labelText, value }) => {
      const field = [...document.querySelectorAll('.control-panel .field')].find((el) =>
        el.textContent?.includes(labelText),
      )
      const input = field?.querySelector('input[type="range"]')
      if (!input) throw new Error(`slider not found: ${labelText}`)
      const setter = Object.getOwnPropertyDescriptor(
        window.HTMLInputElement.prototype,
        'value',
      ).set
      setter.call(input, String(value))
      input.dispatchEvent(new Event('input', { bubbles: true }))
    },
    { labelText, value },
  )
}

async function main() {
  await mkdir(outDir, { recursive: true })

  const browser = await chromium.launch()
  const page = await browser.newPage({ viewport: { width: 1680, height: 1050 } })
  const errors = []
  page.on('console', (message) => {
    if (message.type() === 'error') errors.push(message.text())
  })
  page.on('pageerror', (error) => errors.push(String(error)))

  await page.goto(url, { waitUntil: 'load' })
  await page.waitForSelector('canvas')

  // Does the clock actually run? Everything below is meaningless if it does not.
  const before = await readStats(page)
  await wait(4000)
  const after = await readStats(page)
  console.log('clock before:', before[0])
  console.log('clock after :', after[0])
  console.log('rAF running :', before[0] !== after[0])

  await page.screenshot({ path: `${outDir}/1-running.png` })

  // Mid-slot, where the propagation curve should be part way up.
  await setSlider(page, '基本遅延', 2000)
  await wait(6000)
  await page.screenshot({ path: `${outDir}/2-high-latency.png` })
  console.log('high latency:', (await readStats(page)).join(' | '))

  // A real fork: two groups, each building its own branch.
  await page.evaluate(() => {
    document.querySelector('.control-panel input[type="checkbox"]').click()
  })
  await setSlider(page, '開始スロット', 2)
  await setSlider(page, '終了スロット', 20)
  await wait(1000)

  for (let slot = 0; slot < 8; slot++) {
    await page.getByRole('button', { name: '1スロット進める' }).click()
    await wait(120)
  }
  await wait(1500)
  await page.screenshot({ path: `${outDir}/3-partitioned.png` })
  console.log('partitioned:', (await readStats(page)).join(' | '))

  // And after healing.
  for (let slot = 0; slot < 16; slot++) {
    await page.getByRole('button', { name: '1スロット進める' }).click()
    await wait(120)
  }
  await wait(1500)
  await page.screenshot({ path: `${outDir}/4-healed.png` })
  console.log('healed     :', (await readStats(page)).join(' | '))

  await page.evaluate(() => document.querySelector('.theme-toggle').click())
  await wait(800)
  await page.screenshot({ path: `${outDir}/5-dark.png` })

  console.log('console errors:', errors.length === 0 ? 'none' : errors)
  await browser.close()
}

main().catch((error) => {
  console.error(error)
  process.exit(1)
})
