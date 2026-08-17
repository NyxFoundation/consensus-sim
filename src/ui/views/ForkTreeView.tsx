/**
 * The fork tree as the observed node sees it.
 *
 * Colour carries *state* — finalized, justified, canonical, orphaned — not block
 * identity. Identity is already on the block: the slot number is written inside
 * it. Spending a hue per block produced a rainbow that competed with the state
 * signal and left the real information on a hairline outline.
 *
 * The one exception is a head that nodes actually disagree about: that block
 * takes the same categorical slot its cells take in the validator grid, so the
 * two panels name the same contested block with the same colour.
 */

import { useCallback } from 'react'
import { CanvasSurface } from '../CanvasSurface'
import type { RenderFn } from '../CanvasSurface'
import { roundedRectPath } from '../colors'
import { buildForkLayout } from './forkLayout'
import type { LaidOutBlock, LaidOutEdge } from './forkLayout'
import type { CellKind } from '../headPalette'
import type { Palette } from '../theme'
import type { Hash } from '../../core/hash'
import type { Block, GasperSnapshot } from '../../protocol/gasper/types'

const BLOCK_WIDTH = 32
const BLOCK_HEIGHT = 21
const PADDING_X = 56

interface Props {
  readonly blocks: ReadonlyMap<Hash, Block>
  readonly snapshot: GasperSnapshot
  readonly currentSlot: number
  readonly slotsPerEpoch: number
  readonly visibleSlots: number
  readonly palette: Palette
  /** Contested heads and the categorical slot each was given. */
  readonly contested: ReadonlyMap<Hash, CellKind>
}

/**
 * Stroke priority. A contested head outranks its own state, because "nodes
 * disagree here" is the live event and finality is not going anywhere.
 */
function strokeFor(item: LaidOutBlock, props: Props): string {
  const { palette, snapshot, contested } = props
  const kind = contested.get(item.block.root)
  if (kind !== undefined && kind > 0) return palette.series[kind - 1] ?? palette.otherSeries
  if (item.block.root === snapshot.finalized.root) return palette.statusGood
  if (item.block.root === snapshot.justified.root) return palette.statusWarning
  return item.canonical ? palette.inkPrimary : palette.inkMuted
}

function drawEpochRules(
  ctx: CanvasRenderingContext2D,
  height: number,
  layout: ReturnType<typeof buildForkLayout>,
  slotsPerEpoch: number,
  palette: Palette,
): void {
  ctx.save()
  ctx.strokeStyle = palette.gridline
  ctx.fillStyle = palette.inkMuted
  ctx.font = '11px system-ui, sans-serif'
  ctx.lineWidth = 1

  const first = Math.ceil(layout.minSlot / slotsPerEpoch) * slotsPerEpoch
  for (let slot = first; slot <= layout.maxSlot; slot += slotsPerEpoch) {
    const x = layout.xOfSlot(slot)
    if (x < PADDING_X - 8) continue
    ctx.beginPath()
    ctx.moveTo(x, 16)
    ctx.lineTo(x, height - 8)
    ctx.stroke()
    ctx.fillText(`epoch ${slot / slotsPerEpoch}`, x + 5, 12)
  }
  ctx.restore()
}

function drawEdges(
  ctx: CanvasRenderingContext2D,
  edges: readonly LaidOutEdge[],
  palette: Palette,
): void {
  ctx.save()
  ctx.lineCap = 'round'
  for (const edge of edges) {
    ctx.globalAlpha = edge.opacity
    ctx.strokeStyle = edge.canonical ? palette.baseline : palette.gridline
    ctx.lineWidth = edge.canonical ? 2 : 1.25
    ctx.beginPath()
    ctx.moveTo(edge.fromX + BLOCK_WIDTH / 2, edge.fromY)
    const midX = (edge.fromX + edge.toX) / 2
    ctx.bezierCurveTo(midX, edge.fromY, midX, edge.toY, edge.toX - BLOCK_WIDTH / 2, edge.toY)
    ctx.stroke()
  }
  ctx.restore()
}

function drawBlock(
  ctx: CanvasRenderingContext2D,
  item: LaidOutBlock,
  props: Props,
  maxWeight: number,
): void {
  const { palette, snapshot } = props
  const left = item.x - BLOCK_WIDTH / 2
  const top = item.y - BLOCK_HEIGHT / 2

  ctx.globalAlpha = item.opacity * (item.canonical ? 1 : 0.62)
  ctx.fillStyle = palette.blockFill
  roundedRectPath(ctx, left, top, BLOCK_WIDTH, BLOCK_HEIGHT, 5)
  ctx.fill()

  ctx.strokeStyle = strokeFor(item, props)
  ctx.lineWidth = item.canonical ? 1.75 : 1
  ctx.stroke()

  // Labels wear ink, never the mark's colour.
  ctx.fillStyle = item.canonical ? palette.inkPrimary : palette.inkSecondary
  ctx.fillText(String(item.block.slot), item.x, item.y)

  // Subtree weight, kept recessive: it is context, not the headline.
  ctx.globalAlpha = item.opacity * 0.4
  ctx.fillStyle = palette.baseline
  ctx.fillRect(left, top + BLOCK_HEIGHT + 3, (item.weight / maxWeight) * BLOCK_WIDTH, 1.5)

  if (item.block.root === snapshot.proposerBoostRoot) {
    ctx.globalAlpha = item.opacity
    ctx.fillStyle = palette.inkSecondary
    ctx.fillText('+', item.x, top - 6)
  }
  ctx.globalAlpha = 1
}

export function ForkTreeView(props: Props) {
  const { blocks, snapshot, currentSlot, slotsPerEpoch, visibleSlots, palette } = props

  // The tree redraws every frame by design: it drifts continuously, so there is
  // no steady state to hold. The grid, which does have one, is gated instead.
  const render = useCallback<RenderFn>(
    (ctx, width, height) => {
      ctx.fillStyle = palette.surface
      ctx.fillRect(0, 0, width, height)

      const layout = buildForkLayout({
        blocks,
        head: snapshot.head,
        weights: snapshot.weights,
        currentSlot,
        visibleSlots,
        width,
        height,
      })

      drawEpochRules(ctx, height, layout, slotsPerEpoch, palette)
      drawEdges(ctx, layout.edges, palette)

      const maxWeight = Math.max(1, ...layout.blocks.map((item) => item.weight))
      ctx.font = '10px system-ui, sans-serif'
      ctx.textAlign = 'center'
      ctx.textBaseline = 'middle'
      for (const item of layout.blocks) {
        drawBlock(ctx, item, props, maxWeight)
      }
    },
    [blocks, snapshot, currentSlot, slotsPerEpoch, visibleSlots, palette, props],
  )

  return <CanvasSurface render={render} label="フォーク木" />
}
