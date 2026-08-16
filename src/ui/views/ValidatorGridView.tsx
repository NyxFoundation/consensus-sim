/**
 * One cell per node, coloured by the head that node currently believes in.
 *
 * This is the view that makes individual simulation worth its cost. A single
 * fork tree cannot answer "whose tree is this?", and an aggregate vote count
 * hides disagreement entirely. Here a partition splits the grid into blocks of
 * colour, and a protocol that re-converges quickly is visibly one that goes
 * back to a single colour sooner.
 */

import { useCallback } from 'react'
import { CanvasSurface } from '../CanvasSurface'
import type { RenderFn } from '../CanvasSurface'
import { colorForRoot, PALETTE } from '../colors'
import { shortHash } from '../../core/hash'
import type { NodeRole } from '../../core/types'

const LEGEND_HEIGHT = 44
const PAD = 10
const MAX_LEGEND_ENTRIES = 6

interface Props {
  readonly heads: readonly string[]
  readonly roles: readonly NodeRole[]
  readonly observer: number
  readonly onSelect: (node: number) => void
}

interface Geometry {
  readonly cols: number
  readonly rows: number
  readonly cell: number
}

function gridGeometry(count: number, width: number, height: number): Geometry {
  const usableWidth = Math.max(1, width - PAD * 2)
  const usableHeight = Math.max(1, height - PAD * 2 - LEGEND_HEIGHT)
  const cols = Math.max(1, Math.round(Math.sqrt((count * usableWidth) / usableHeight)))
  const rows = Math.ceil(count / cols)
  return { cols, rows, cell: Math.min(usableWidth / cols, usableHeight / rows) }
}

function tally(heads: readonly string[]): [string, number][] {
  const counts = new Map<string, number>()
  for (const head of heads) counts.set(head, (counts.get(head) ?? 0) + 1)
  return [...counts.entries()].sort((a, b) => b[1] - a[1])
}

function drawCells(
  ctx: CanvasRenderingContext2D,
  props: Props,
  geometry: Geometry,
): void {
  const { heads, roles, observer } = props
  const gap = geometry.cell > 14 ? 2 : 1
  const size = geometry.cell - gap

  heads.forEach((head, index) => {
    const x = PAD + (index % geometry.cols) * geometry.cell
    const y = PAD + Math.floor(index / geometry.cols) * geometry.cell
    const offline = roles[index] === 'offline'

    ctx.fillStyle = offline ? PALETTE.orphan : colorForRoot(head)
    ctx.globalAlpha = offline ? 0.35 : 1
    ctx.fillRect(x, y, size, size)
    ctx.globalAlpha = 1

    if (index === observer) {
      ctx.strokeStyle = PALETTE.text
      ctx.lineWidth = 2
      ctx.strokeRect(x - 1, y - 1, size + 2, size + 2)
    }
  })
}

function drawLegend(
  ctx: CanvasRenderingContext2D,
  heads: readonly string[],
  width: number,
  height: number,
): void {
  const entries = tally(heads)
  const baseY = height - LEGEND_HEIGHT + 14

  ctx.save()
  ctx.font = '11px ui-monospace, monospace'
  ctx.textBaseline = 'middle'
  ctx.fillStyle = PALETTE.muted
  ctx.fillText(`異なる head: ${entries.length}`, PAD, baseY)

  let x = PAD
  const swatchY = baseY + 18
  for (const [head, count] of entries.slice(0, MAX_LEGEND_ENTRIES)) {
    if (x > width - 90) break
    ctx.fillStyle = colorForRoot(head)
    ctx.fillRect(x, swatchY - 5, 10, 10)
    ctx.fillStyle = PALETTE.text
    ctx.fillText(`${shortHash(head)} ×${count}`, x + 14, swatchY)
    x += 14 + ctx.measureText(`${shortHash(head)} ×${count}`).width + 14
  }
  ctx.restore()
}

export function ValidatorGridView(props: Props) {
  const { heads, onSelect } = props

  const render = useCallback<RenderFn>(
    (ctx, width, height) => {
      ctx.fillStyle = PALETTE.panel
      ctx.fillRect(0, 0, width, height)

      const geometry = gridGeometry(heads.length, width, height)
      drawCells(ctx, props, geometry)
      drawLegend(ctx, heads, width, height)
    },
    [props, heads],
  )

  const handleClick = useCallback(
    (x: number, y: number, width: number, height: number) => {
      const geometry = gridGeometry(heads.length, width, height)
      const col = Math.floor((x - PAD) / geometry.cell)
      const row = Math.floor((y - PAD) / geometry.cell)
      const index = row * geometry.cols + col
      if (col < 0 || col >= geometry.cols || index < 0 || index >= heads.length) return
      onSelect(index)
    },
    [heads.length, onSelect],
  )

  return (
    <CanvasSurface render={render} label="バリデータ・ビューグリッド" onClick={handleClick} />
  )
}
