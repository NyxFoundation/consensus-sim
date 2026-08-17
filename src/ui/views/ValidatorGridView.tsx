/**
 * One cell per node, coloured by whether that node agrees with the observed one.
 *
 * This is the view that makes individual simulation worth its cost. A single
 * fork tree cannot answer "whose tree is this?", and an aggregate vote count
 * hides disagreement entirely.
 *
 * Agreement is deliberately the quietest thing on screen: when the network is
 * converged the grid is one low-chroma neutral and does not repaint at all.
 * Colour appears only when nodes genuinely disagree, so the amount of movement
 * tracks the amount of information — which is the property the previous
 * identity-coloured version got backwards.
 */

import { useCallback, useMemo, useRef } from 'react'
import { CanvasSurface } from '../CanvasSurface'
import type { RenderFn } from '../CanvasSurface'
import { cellColor, diagonalHatch } from '../colors'
import type { CellKind } from '../headPalette'
import type { Palette } from '../theme'

const PAD = 10

interface Props {
  readonly kinds: readonly CellKind[]
  readonly offline: readonly boolean[]
  readonly observer: number
  /**
   * This slot's attesters. Marking them puts Gasper's one-committee-per-slot
   * structure on screen — the coupling Decoupled Consensus sets out to remove,
   * and otherwise invisible in a view of heads.
   */
  readonly committee: ReadonlySet<number>
  /** Changes once per slot, and the committee is a function of it. */
  readonly slot: number
  readonly palette: Palette
  readonly onSelect: (node: number) => void
}

interface Geometry {
  readonly cols: number
  readonly rows: number
  readonly cell: number
}

function gridGeometry(count: number, width: number, height: number): Geometry {
  const usableWidth = Math.max(1, width - PAD * 2)
  const usableHeight = Math.max(1, height - PAD * 2)
  const cols = Math.max(1, Math.round(Math.sqrt((count * usableWidth) / usableHeight)))
  const rows = Math.ceil(count / cols)
  return { cols, rows, cell: Math.min(usableWidth / cols, usableHeight / rows) }
}

export function ValidatorGridView({
  kinds,
  offline,
  observer,
  committee,
  slot,
  palette,
  onSelect,
}: Props) {
  // The render callback is keyed on a signature rather than on array identity,
  // so a converged network redraws once per slot instead of sixty times a
  // second — and the once-per-slot redraw is the committee rotating, which is
  // motion that means something.
  const signature = useMemo(
    () =>
      `${kinds.join('')}|${offline.map((v) => (v ? 1 : 0)).join('')}|${observer}|${slot}|${palette.surface}`,
    [kinds, offline, observer, slot, palette.surface],
  )

  const dataRef = useRef({ kinds, offline, observer, committee, palette })
  dataRef.current = { kinds, offline, observer, committee, palette }

  const render = useCallback<RenderFn>(
    (ctx, width, height) => {
      const data = dataRef.current
      ctx.fillStyle = data.palette.surface
      ctx.fillRect(0, 0, width, height)

      const geometry = gridGeometry(data.kinds.length, width, height)
      const gap = geometry.cell > 14 ? 2 : 1
      const size = Math.max(1, geometry.cell - gap)
      const hatch = diagonalHatch(ctx, data.palette.inkMuted)

      data.kinds.forEach((kind, index) => {
        const x = PAD + (index % geometry.cols) * geometry.cell
        const y = PAD + Math.floor(index / geometry.cols) * geometry.cell

        if (data.offline[index] === true) {
          ctx.fillStyle = data.palette.gridline
          ctx.fillRect(x, y, size, size)
          if (hatch !== null) {
            ctx.save()
            ctx.globalAlpha = 0.55
            ctx.fillStyle = hatch
            ctx.fillRect(x, y, size, size)
            ctx.restore()
          }
        } else {
          ctx.fillStyle = cellColor(kind, data.palette)
          ctx.fillRect(x, y, size, size)
        }

        if (data.committee.has(index)) {
          ctx.strokeStyle = data.palette.inkSecondary
          ctx.lineWidth = 1
          ctx.strokeRect(x + 0.5, y + 0.5, size - 1, size - 1)
        }

        if (index === data.observer) {
          ctx.strokeStyle = data.palette.inkPrimary
          ctx.lineWidth = 2
          ctx.strokeRect(x - 1, y - 1, size + 2, size + 2)
        }
      })
    },
    [signature],
  )

  const handleClick = useCallback(
    (x: number, y: number, width: number, height: number) => {
      const geometry = gridGeometry(kinds.length, width, height)
      const col = Math.floor((x - PAD) / geometry.cell)
      const row = Math.floor((y - PAD) / geometry.cell)
      const index = row * geometry.cols + col
      if (col < 0 || col >= geometry.cols || index < 0 || index >= kinds.length) return
      onSelect(index)
    },
    [kinds.length, onSelect],
  )

  return <CanvasSurface render={render} label="バリデータ・ビューグリッド" onClick={handleClick} />
}
