/**
 * Canvas colour helpers. All colour comes from the active `Palette`; nothing
 * here generates a hue.
 */

import { AGREE, OTHER } from './headPalette'
import type { CellKind } from './headPalette'
import type { Palette } from './theme'

export function cellColor(kind: CellKind, palette: Palette): string {
  if (kind === AGREE) return palette.neutralCell
  if (kind === OTHER) return palette.otherSeries
  return palette.series[kind - 1] ?? palette.otherSeries
}

/**
 * A 45-degree hatch, used to mark non-participating validators.
 *
 * This is the accessibility channel: offline is already the least saturated
 * cell on screen, so under CVD or in print it could read as just another
 * neutral. The texture carries the distinction without spending a hue on it.
 */
export function diagonalHatch(
  ctx: CanvasRenderingContext2D,
  color: string,
): CanvasPattern | null {
  const tile = document.createElement('canvas')
  tile.width = 6
  tile.height = 6

  const tileCtx = tile.getContext('2d')
  if (tileCtx === null) return null

  tileCtx.strokeStyle = color
  tileCtx.lineWidth = 1.4
  tileCtx.beginPath()
  tileCtx.moveTo(-1, 7)
  tileCtx.lineTo(7, -1)
  tileCtx.moveTo(-1, 13)
  tileCtx.lineTo(13, -1)
  tileCtx.stroke()

  return ctx.createPattern(tile, 'repeat')
}

/** Rounded rectangle path, shared by both canvas views. */
export function roundedRectPath(
  ctx: CanvasRenderingContext2D,
  x: number,
  y: number,
  width: number,
  height: number,
  radius: number,
): void {
  const r = Math.min(radius, width / 2, height / 2)
  ctx.beginPath()
  ctx.moveTo(x + r, y)
  ctx.arcTo(x + width, y, x + width, y + height, r)
  ctx.arcTo(x + width, y + height, x, y + height, r)
  ctx.arcTo(x, y + height, x, y, r)
  ctx.arcTo(x, y, x + width, y, r)
  ctx.closePath()
}
