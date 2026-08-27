/**
 * SVG rendering of one block tree: columns follow slots, forks branch onto
 * their own rows. State rides on strokes and badges, never on colour alone —
 * finalized/justified checkpoints carry F/J badges, fork-choice heads carry
 * the validator chips that point at them, and each validator's latest vote
 * appears as a chip under the block it supports.
 */

import {
  latestVotes,
  pathToAnchor,
  NO_PROPOSER,
} from '../domain'
import type {
  BlockIndex,
  BlockTree,
  FinalityState,
  ValidatorIndex,
  Vote,
} from '../domain'
import { layoutTree } from './treeLayout'
import { validatorColor } from './validatorColor'

const COL_W = 88
const ROW_H = 78
const BLOCK_W = 56
const BLOCK_H = 34
const PAD_X = 24
const PAD_TOP = 34
const PAD_BOTTOM = 30

export interface BlockTreeViewProps {
  readonly tree: BlockTree
  readonly votes: readonly Vote[]
  /** Fork-choice head per validator (one entry in a local view). */
  readonly heads: ReadonlyMap<ValidatorIndex, BlockIndex>
  readonly finality: FinalityState
  /** Slot columns are drawn through this slot even past the last block. */
  readonly throughSlot: number
}

interface Point {
  readonly x: number
  readonly y: number
}

function center(slot: number, row: number): Point {
  return {
    x: PAD_X + slot * COL_W + BLOCK_W / 2,
    y: PAD_TOP + row * ROW_H + BLOCK_H / 2,
  }
}

export function BlockTreeView({
  tree,
  votes,
  heads,
  finality,
  throughSlot,
}: BlockTreeViewProps) {
  const layout = layoutTree(tree)
  const slotCount = Math.max(layout.maxSlot, throughSlot) + 1
  const width = PAD_X * 2 + slotCount * COL_W
  const height = PAD_TOP + layout.rowCount * ROW_H + PAD_BOTTOM

  const latest = latestVotes(votes)
  const supportersOf = new Map<BlockIndex, ValidatorIndex[]>()
  for (const [validator, vote] of latest) {
    const list = supportersOf.get(vote.head) ?? []
    list.push(validator)
    supportersOf.set(vote.head, list)
  }
  for (const list of supportersOf.values()) list.sort((a, b) => a - b)

  const headsOf = new Map<BlockIndex, ValidatorIndex[]>()
  for (const [validator, head] of heads) {
    const list = headsOf.get(head) ?? []
    list.push(validator)
    headsOf.set(head, list)
  }
  for (const list of headsOf.values()) list.sort((a, b) => a - b)

  // Blocks on the path from any head to the anchor read as the active chain.
  const onHeadPath = new Set<BlockIndex>()
  for (const head of heads.values()) {
    for (const block of pathToAnchor(tree, head)) onHeadPath.add(block.index)
  }

  const blocks = [...tree.blocks.values()].sort((a, b) => a.index - b.index)

  return (
    <svg
      className="block-tree"
      width={width}
      height={height}
      viewBox={`0 0 ${width} ${height}`}
      role="img"
      aria-label="ブロック木"
    >
      {Array.from({ length: slotCount }, (_, slot) => {
        const x = PAD_X + slot * COL_W + BLOCK_W / 2
        return (
          <g key={`slot-${slot}`}>
            <line
              className="slot-gridline"
              x1={x}
              y1={PAD_TOP - 10}
              x2={x}
              y2={height - PAD_BOTTOM + 6}
            />
            <text className="slot-label" x={x} y={PAD_TOP - 16} textAnchor="middle">
              {slot}
            </text>
          </g>
        )
      })}

      {blocks.map((block) => {
        if (block.proposer === NO_PROPOSER) return null
        const parent = tree.blocks.get(block.parent)
        const row = layout.rows.get(block.index)
        const parentRow = parent ? layout.rows.get(parent.index) : undefined
        if (parent === undefined || row === undefined || parentRow === undefined)
          return null
        const from = center(parent.slot, parentRow)
        const to = center(block.slot, row)
        const active = onHeadPath.has(block.index) && onHeadPath.has(parent.index)
        return (
          <line
            key={`edge-${block.index}`}
            className={active ? 'tree-edge tree-edge-active' : 'tree-edge'}
            x1={from.x + BLOCK_W / 2}
            y1={from.y}
            x2={to.x - BLOCK_W / 2}
            y2={to.y}
          />
        )
      })}

      {blocks.map((block) => {
        const row = layout.rows.get(block.index)
        if (row === undefined) return null
        const { x, y } = center(block.slot, row)
        const justified = finality.justified.has(block.index)
        const finalized = finality.finalized === block.index
        const headChips = headsOf.get(block.index) ?? []
        const voteChips = supportersOf.get(block.index) ?? []
        const classes = [
          'tree-block',
          onHeadPath.has(block.index) ? 'tree-block-active' : '',
          justified ? 'tree-block-justified' : '',
          finalized ? 'tree-block-finalized' : '',
        ]
          .filter(Boolean)
          .join(' ')
        return (
          <g key={`block-${block.index}`}>
            <rect
              className={classes}
              x={x - BLOCK_W / 2}
              y={y - BLOCK_H / 2}
              width={BLOCK_W}
              height={BLOCK_H}
              rx={6}
            />
            <text className="block-label" x={x} y={y - 2} textAnchor="middle">
              B{block.index}
            </text>
            <text className="block-sublabel" x={x} y={y + 11} textAnchor="middle">
              {block.proposer === NO_PROPOSER ? '錨' : `提案 V${block.proposer}`}
            </text>

            {(finalized || justified) && (
              <g>
                <rect
                  className={finalized ? 'badge badge-finalized' : 'badge badge-justified'}
                  x={x + BLOCK_W / 2 - 8}
                  y={y - BLOCK_H / 2 - 8}
                  width={16}
                  height={16}
                  rx={8}
                />
                <text
                  className="badge-label"
                  x={x + BLOCK_W / 2}
                  y={y - BLOCK_H / 2 + 4}
                  textAnchor="middle"
                >
                  {finalized ? 'F' : 'J'}
                </text>
              </g>
            )}

            {headChips.map((validator, i) => (
              <g key={`head-${validator}`}>
                <circle
                  className="validator-chip"
                  cx={x - BLOCK_W / 2 + 8 + i * 18}
                  cy={y - BLOCK_H / 2 - 12}
                  r={8}
                  fill={validatorColor(validator)}
                />
                <text
                  className="chip-label"
                  x={x - BLOCK_W / 2 + 8 + i * 18}
                  y={y - BLOCK_H / 2 - 8}
                  textAnchor="middle"
                >
                  {validator}
                </text>
              </g>
            ))}

            {voteChips.map((validator, i) => (
              <g key={`vote-${validator}`}>
                <rect
                  className="vote-chip"
                  x={x - BLOCK_W / 2 + i * 18}
                  y={y + BLOCK_H / 2 + 4}
                  width={16}
                  height={14}
                  rx={3}
                  fill="none"
                  stroke={validatorColor(validator)}
                />
                <text
                  className="chip-label chip-label-vote"
                  x={x - BLOCK_W / 2 + 8 + i * 18}
                  y={y + BLOCK_H / 2 + 15}
                  textAnchor="middle"
                >
                  {validator}
                </text>
              </g>
            ))}
          </g>
        )
      })}
    </svg>
  )
}
