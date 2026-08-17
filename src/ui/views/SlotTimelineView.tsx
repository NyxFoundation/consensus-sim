/**
 * What is happening *inside* the current slot.
 *
 * The fork tree and the grid both show outcomes: a block exists, a head
 * changed. Between those outcomes the slot looked empty, so the chain read as
 * nothing-then-a-jump. The work is all in between — a proposal goes out, it
 * spreads, the committee votes at the deadline, those votes spread, and only
 * then does the weight move.
 *
 * Propagation is the part of that which is genuinely continuous, so it is what
 * this view animates. It is also where latency and partitions stop being a
 * parameter and become something you can watch: raise the delay and the meter
 * is still filling when the voting deadline arrives.
 *
 * The two meters are told apart by their row label, not by hue. Categorical
 * colour is reserved for contested heads, and spending a slot here would make
 * an unrelated row look like a disputed block.
 */

import { useCallback } from 'react'
import { CanvasSurface } from '../CanvasSurface'
import type { RenderFn } from '../CanvasSurface'
import type { Palette } from '../theme'
import type { Publication } from '../../core/simulation'

const LABEL_WIDTH = 76
const RIGHT_GUTTER = 128
const AXIS_Y = 30
const ROW_HEIGHT = 26
const METER_HEIGHT = 9

interface Props {
  readonly slot: number
  readonly slotStartMs: number
  readonly slotDurationMs: number
  readonly attestationOffsetMs: number
  readonly nowMs: number
  readonly proposer: number
  readonly proposerActive: boolean
  readonly committeeSize: number
  readonly publications: readonly Publication[]
  readonly nodeCount: number
  readonly palette: Palette
}

interface Meter {
  readonly label: string
  /** Simulated time the event fired, or null when it has not fired yet. */
  readonly startedAt: number | null
  readonly fraction: number
  readonly detail: string
}

function blockMeter(props: Props): Meter {
  const blocks = props.publications.filter((p) => p.kind === 'block')
  const first = blocks[0]
  if (first === undefined) {
    const pending = props.nowMs < props.slotStartMs + props.attestationOffsetMs
    return {
      label: '提案',
      startedAt: null,
      fraction: 0,
      detail: pending ? `#${props.proposer} 待機` : `#${props.proposer} 提案なし`,
    }
  }

  const delivered = blocks.reduce((sum, p) => sum + p.delivered, 0)
  return {
    label: '提案',
    startedAt: first.time,
    fraction: delivered / props.nodeCount,
    detail: `#${first.from} → ${delivered}/${props.nodeCount} 受信`,
  }
}

function voteMeter(props: Props): Meter {
  const votes = props.publications.filter((p) => p.kind === 'attestation')
  const first = votes[0]
  if (first === undefined) {
    return { label: '投票', startedAt: null, fraction: 0, detail: `委員会 ${props.committeeSize}人` }
  }

  const delivered = votes.reduce((sum, p) => sum + p.delivered, 0)
  const reach = votes.length * props.nodeCount
  return {
    label: '投票',
    startedAt: first.time,
    fraction: reach === 0 ? 0 : delivered / reach,
    detail: `${votes.length}/${props.committeeSize}人 · 伝播 ${Math.round((delivered / Math.max(1, reach)) * 100)}%`,
  }
}

function drawAxis(ctx: CanvasRenderingContext2D, props: Props, width: number, height: number): void {
  const { palette, slotDurationMs, attestationOffsetMs } = props
  const track = width - LABEL_WIDTH - RIGHT_GUTTER
  const xOf = (offset: number) => LABEL_WIDTH + (offset / slotDurationMs) * track

  ctx.save()
  ctx.strokeStyle = palette.gridline
  ctx.fillStyle = palette.inkMuted
  ctx.font = '10px system-ui, sans-serif'
  ctx.textBaseline = 'alphabetic'
  ctx.lineWidth = 1

  const ticks: readonly [number, string][] = [
    [0, '0 提案'],
    [attestationOffsetMs, 'Δ 投票期限'],
    [slotDurationMs, '次スロット'],
  ]

  for (const [offset, label] of ticks) {
    const x = xOf(offset)
    ctx.beginPath()
    ctx.moveTo(x, AXIS_Y - 8)
    ctx.lineTo(x, height - 10)
    ctx.stroke()
    ctx.textAlign = offset === slotDurationMs ? 'right' : 'left'
    ctx.fillText(label, offset === slotDurationMs ? x - 4 : x + 4, AXIS_Y - 12)
  }
  ctx.restore()
}

function drawMeter(
  ctx: CanvasRenderingContext2D,
  meter: Meter,
  props: Props,
  width: number,
  y: number,
): void {
  const { palette, slotStartMs, slotDurationMs } = props
  const track = width - LABEL_WIDTH - RIGHT_GUTTER
  const startOffset = meter.startedAt === null ? 0 : meter.startedAt - slotStartMs
  const startX = LABEL_WIDTH + (startOffset / slotDurationMs) * track
  const trackWidth = Math.max(0, LABEL_WIDTH + track - startX)

  ctx.save()
  ctx.font = '11px system-ui, sans-serif'
  ctx.textBaseline = 'middle'

  ctx.textAlign = 'right'
  ctx.fillStyle = palette.inkSecondary
  ctx.fillText(meter.label, LABEL_WIDTH - 10, y)

  if (meter.startedAt !== null) {
    ctx.fillStyle = palette.gridline
    ctx.fillRect(startX, y - METER_HEIGHT / 2, trackWidth, METER_HEIGHT)
    ctx.fillStyle = palette.inkSecondary
    ctx.fillRect(startX, y - METER_HEIGHT / 2, trackWidth * meter.fraction, METER_HEIGHT)

    // The event marker: where on the slot's clock this actually fired.
    ctx.fillStyle = palette.inkPrimary
    ctx.beginPath()
    ctx.arc(startX, y, 3, 0, Math.PI * 2)
    ctx.fill()
  }

  ctx.textAlign = 'left'
  ctx.fillStyle = meter.startedAt === null ? palette.inkMuted : palette.inkSecondary
  ctx.fillText(meter.detail, width - RIGHT_GUTTER + 10, y)
  ctx.restore()
}

function drawPlayhead(
  ctx: CanvasRenderingContext2D,
  props: Props,
  width: number,
  height: number,
): void {
  const { palette, slotStartMs, slotDurationMs, nowMs } = props
  const track = width - LABEL_WIDTH - RIGHT_GUTTER
  const progress = Math.max(0, Math.min(1, (nowMs - slotStartMs) / slotDurationMs))
  const x = LABEL_WIDTH + progress * track

  ctx.save()
  ctx.strokeStyle = palette.inkPrimary
  ctx.lineWidth = 1.5
  ctx.beginPath()
  ctx.moveTo(x, AXIS_Y - 8)
  ctx.lineTo(x, height - 10)
  ctx.stroke()
  ctx.restore()
}

export function SlotTimelineView(props: Props) {
  const render = useCallback<RenderFn>(
    (ctx, width, height) => {
      ctx.fillStyle = props.palette.surface
      ctx.fillRect(0, 0, width, height)

      drawAxis(ctx, props, width, height)
      drawMeter(ctx, blockMeter(props), props, width, AXIS_Y + ROW_HEIGHT * 0.6)
      drawMeter(ctx, voteMeter(props), props, width, AXIS_Y + ROW_HEIGHT * 1.6)
      drawPlayhead(ctx, props, width, height)

      ctx.save()
      ctx.font = '10px system-ui, sans-serif'
      ctx.fillStyle = props.palette.inkMuted
      ctx.textAlign = 'left'
      ctx.textBaseline = 'alphabetic'
      ctx.fillText(
        `slot ${props.slot} · 提案者 #${props.proposer}${props.proposerActive ? '' : '（非参加）'}`,
        10,
        height - 10,
      )
      ctx.restore()
    },
    [props],
  )

  return <CanvasSurface render={render} label="スロット内タイムライン" />
}
