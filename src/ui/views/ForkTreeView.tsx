/**
 * The fork tree as the observed node sees it.
 *
 * Weight, justification and finality are all read from one node's snapshot
 * rather than from a global truth, so during a partition this view shows what
 * *that* node believes — which is the honest thing to draw when the whole point
 * is that nodes disagree.
 */

import { useCallback } from 'react'
import { CanvasSurface } from '../CanvasSurface'
import type { RenderFn } from '../CanvasSurface'
import { colorForRoot, PALETTE } from '../colors'
import { buildForkLayout } from './forkLayout'
import type { LaidOutBlock, LaidOutEdge } from './forkLayout'
import type { Hash } from '../../core/hash'
import type { Block, GasperSnapshot } from '../../protocol/gasper/types'

const BLOCK_WIDTH = 30
const BLOCK_HEIGHT = 20

interface Props {
  readonly blocks: ReadonlyMap<Hash, Block>
  readonly snapshot: GasperSnapshot
  readonly currentSlot: number
  readonly slotsPerEpoch: number
  readonly visibleSlots: number
}

function roundedRect(
  ctx: CanvasRenderingContext2D,
  x: number,
  y: number,
  width: number,
  height: number,
  radius: number,
): void {
  ctx.beginPath()
  ctx.moveTo(x + radius, y)
  ctx.arcTo(x + width, y, x + width, y + height, radius)
  ctx.arcTo(x + width, y + height, x, y + height, radius)
  ctx.arcTo(x, y + height, x, y, radius)
  ctx.arcTo(x, y, x + width, y, radius)
  ctx.closePath()
}

function drawEpochGrid(
  ctx: CanvasRenderingContext2D,
  height: number,
  minSlot: number,
  maxSlot: number,
  columnWidth: number,
  slotsPerEpoch: number,
): void {
  ctx.save()
  ctx.strokeStyle = PALETTE.grid
  ctx.fillStyle = PALETTE.muted
  ctx.font = '11px ui-monospace, monospace'
  ctx.lineWidth = 1

  for (let slot = minSlot; slot <= maxSlot; slot++) {
    if (slot % slotsPerEpoch !== 0) continue
    const x = 56 + (slot - minSlot) * columnWidth
    ctx.beginPath()
    ctx.moveTo(x, 14)
    ctx.lineTo(x, height - 8)
    ctx.stroke()
    ctx.fillText(`epoch ${slot / slotsPerEpoch}`, x + 4, 12)
  }
  ctx.restore()
}

function drawEdges(ctx: CanvasRenderingContext2D, edges: readonly LaidOutEdge[]): void {
  ctx.save()
  ctx.lineCap = 'round'
  for (const edge of edges) {
    ctx.strokeStyle = edge.canonical ? PALETTE.canonical : PALETTE.orphan
    ctx.lineWidth = edge.canonical ? 2.2 : 1.2
    ctx.beginPath()
    ctx.moveTo(edge.fromX + BLOCK_WIDTH / 2, edge.fromY)
    const midX = (edge.fromX + edge.toX) / 2
    ctx.bezierCurveTo(midX, edge.fromY, midX, edge.toY, edge.toX - BLOCK_WIDTH / 2, edge.toY)
    ctx.stroke()
  }
  ctx.restore()
}

function blockOutline(item: LaidOutBlock, snapshot: GasperSnapshot): string {
  if (item.block.root === snapshot.finalized.root) return PALETTE.finalized
  if (item.block.root === snapshot.justified.root) return PALETTE.justified
  if (item.block.root === snapshot.proposerBoostRoot) return PALETTE.boost
  return item.canonical ? PALETTE.canonical : PALETTE.border
}

function drawBlocks(
  ctx: CanvasRenderingContext2D,
  items: readonly LaidOutBlock[],
  snapshot: GasperSnapshot,
): void {
  const maxWeight = Math.max(1, ...items.map((item) => item.weight))

  ctx.save()
  ctx.font = '10px ui-monospace, monospace'
  ctx.textAlign = 'center'
  ctx.textBaseline = 'middle'

  for (const item of items) {
    const left = item.x - BLOCK_WIDTH / 2
    const top = item.y - BLOCK_HEIGHT / 2

    ctx.globalAlpha = item.canonical ? 1 : 0.55
    ctx.fillStyle = colorForRoot(item.block.root, item.canonical ? 52 : 34)
    roundedRect(ctx, left, top, BLOCK_WIDTH, BLOCK_HEIGHT, 5)
    ctx.fill()

    ctx.strokeStyle = blockOutline(item, snapshot)
    ctx.lineWidth = item.canonical ? 2 : 1
    ctx.stroke()

    ctx.globalAlpha = 1
    ctx.fillStyle = '#0b0e12'
    ctx.fillText(String(item.block.slot), item.x, item.y)

    // Weight bar: how much stake votes anywhere inside this subtree.
    const barWidth = (item.weight / maxWeight) * BLOCK_WIDTH
    ctx.fillStyle = PALETTE.canonical
    ctx.globalAlpha = 0.7
    ctx.fillRect(left, top + BLOCK_HEIGHT + 2, barWidth, 2)
    ctx.globalAlpha = 1
  }
  ctx.restore()
}

export function ForkTreeView({
  blocks,
  snapshot,
  currentSlot,
  slotsPerEpoch,
  visibleSlots,
}: Props) {
  const render = useCallback<RenderFn>(
    (ctx, width, height) => {
      ctx.fillStyle = PALETTE.panel
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

      drawEpochGrid(ctx, height, layout.minSlot, layout.maxSlot, layout.columnWidth, slotsPerEpoch)
      drawEdges(ctx, layout.edges)
      drawBlocks(ctx, layout.blocks, snapshot)
    },
    [blocks, snapshot, currentSlot, slotsPerEpoch, visibleSlots],
  )

  return <CanvasSurface render={render} label="フォーク木" />
}
