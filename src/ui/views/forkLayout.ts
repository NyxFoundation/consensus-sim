/**
 * Positions the fork tree. Pure geometry — no canvas, no React.
 *
 * Slot is the x axis, so the tree cannot "drift" horizontally as branches come
 * and go; a fork is always a vertical split at the slot where it happened.
 * Within a column the canonical block takes the top lane, which keeps the
 * chain the observed node believes in reading as a straight line.
 */

import type { Hash } from '../../core/hash'
import type { Gwei, Slot } from '../../core/types'
import type { Block } from '../../protocol/gasper/types'

export interface LaidOutBlock {
  readonly block: Block
  readonly x: number
  readonly y: number
  readonly canonical: boolean
  readonly weight: Gwei
}

export interface LaidOutEdge {
  readonly fromX: number
  readonly fromY: number
  readonly toX: number
  readonly toY: number
  readonly canonical: boolean
}

export interface ForkLayout {
  readonly blocks: readonly LaidOutBlock[]
  readonly edges: readonly LaidOutEdge[]
  readonly minSlot: Slot
  readonly maxSlot: Slot
  readonly columnWidth: number
  readonly rowHeight: number
}

export interface ForkLayoutInput {
  readonly blocks: ReadonlyMap<Hash, Block>
  readonly head: Hash
  readonly weights: ReadonlyMap<Hash, Gwei>
  readonly currentSlot: Slot
  readonly visibleSlots: number
  readonly width: number
  readonly height: number
}

const PADDING_X = 56
const PADDING_TOP = 34
const MIN_ROW_HEIGHT = 30
const MAX_ROW_HEIGHT = 62

/** Roots on the path from `head` back to the root of the tree. */
function canonicalRoots(blocks: ReadonlyMap<Hash, Block>, head: Hash): ReadonlySet<Hash> {
  const path = new Set<Hash>()
  let current: Hash | undefined = head

  while (current !== undefined && !path.has(current)) {
    path.add(current)
    current = blocks.get(current)?.parent
  }
  return path
}

/**
 * Assigns a row to every visible block, by *branch* rather than by column.
 *
 * Assigning rows per slot column looks right until the case that matters: a
 * partition where each slot still holds exactly one block, but the blocks build
 * on different parents. Per-column assignment draws that as a straight line and
 * the fork disappears. Following the parent instead keeps a branch on its own
 * row for as long as it lives, so any divergence is visible as a split.
 */
function assignLanes(
  visible: readonly Block[],
  canonical: ReadonlySet<Hash>,
): Map<Hash, number> {
  const lanes = new Map<Hash, number>()
  let nextLane = 1

  const ordered = [...visible].sort((a, b) =>
    a.slot !== b.slot ? a.slot - b.slot : a.root.localeCompare(b.root),
  )

  for (const block of ordered) {
    if (canonical.has(block.root)) {
      lanes.set(block.root, 0)
      continue
    }
    const parentLane = lanes.get(block.parent)
    // Continue the parent's row when the parent is itself off the canonical
    // chain; a block branching off the canonical chain starts a new row.
    lanes.set(block.root, parentLane !== undefined && parentLane > 0 ? parentLane : nextLane++)
  }

  return lanes
}

export function buildForkLayout(input: ForkLayoutInput): ForkLayout {
  const { blocks, head, weights, currentSlot, visibleSlots, width, height } = input

  const minSlot = Math.max(0, currentSlot - visibleSlots + 1)
  const maxSlot = Math.max(currentSlot, minSlot)
  const canonical = canonicalRoots(blocks, head)
  const visible = [...blocks.values()].filter((block) => block.slot >= minSlot)
  const lanes = assignLanes(visible, canonical)

  const laneCount = Math.max(1, ...[...lanes.values()].map((lane) => lane + 1))
  const columnWidth = (width - PADDING_X * 2) / Math.max(1, maxSlot - minSlot + 1)
  const rowHeight = Math.min(
    MAX_ROW_HEIGHT,
    Math.max(MIN_ROW_HEIGHT, (height - PADDING_TOP * 2) / laneCount),
  )

  const positions = new Map<Hash, LaidOutBlock>()
  for (const block of visible) {
    const lane = lanes.get(block.root) ?? 0
    positions.set(block.root, {
      block,
      x: PADDING_X + (block.slot - minSlot) * columnWidth + columnWidth / 2,
      y: PADDING_TOP + lane * rowHeight + rowHeight / 2,
      canonical: canonical.has(block.root),
      weight: weights.get(block.root) ?? 0,
    })
  }

  return {
    blocks: [...positions.values()],
    edges: buildEdges(positions),
    minSlot,
    maxSlot,
    columnWidth,
    rowHeight,
  }
}

function buildEdges(positions: ReadonlyMap<Hash, LaidOutBlock>): LaidOutEdge[] {
  const edges: LaidOutEdge[] = []

  for (const laidOut of positions.values()) {
    const parentPosition = positions.get(laidOut.block.parent)
    // A parent scrolled off the left edge is drawn as a stub so the branch
    // still reads as attached to something rather than floating.
    const fromX = parentPosition?.x ?? laidOut.x - 40
    const fromY = parentPosition?.y ?? laidOut.y
    const parentIsCanonical = parentPosition === undefined || parentPosition.canonical

    edges.push({
      fromX,
      fromY,
      toX: laidOut.x,
      toY: laidOut.y,
      canonical: laidOut.canonical && parentIsCanonical,
    })
  }
  return edges
}
