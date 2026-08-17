/**
 * How far this slot's messages have spread, plotted against the slot's clock.
 *
 * The previous version drew propagation as a bar whose *length* was the
 * delivered fraction — laid on an axis whose length was *time*. Two meanings on
 * one axis: at 100% the bar reached the right-hand edge and read as "the
 * proposal lasted the whole slot". Here x is time and nothing else, y is the
 * share of nodes holding the message, and the mark is a curve that climbs.
 *
 * That makes the interesting failure legible rather than inferable: raise the
 * delay and the curve is still climbing when it crosses the voting deadline, so
 * the committee votes on a view that has not finished arriving. Under a
 * partition it goes flat part-way up and only completes when the partition
 * heals.
 *
 * The two curves are told apart by line style and by a direct label, not by
 * hue. Categorical colour is reserved for contested heads.
 */

import { useCallback } from 'react'
import { CanvasSurface } from '../CanvasSurface'
import type { RenderFn } from '../CanvasSurface'
import type { Palette } from '../theme'
import type { Publication } from '../../core/simulation'

const LABEL_WIDTH = 34
const RIGHT_GUTTER = 148
const PLOT_TOP = 30
const PLOT_BOTTOM_PAD = 26
const SAMPLES = 64

export interface SlotTimelineProps {
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

export interface CurveSample {
  /** Milliseconds since the start of the slot. */
  readonly offset: number
  readonly fraction: number
}

/** Share of the audience holding `publication` at time `t`, from its deciles. */
export function fractionAt(publication: Publication, t: number): number {
  let fraction = 0
  for (let step = 0; step < publication.milestones.length; step++) {
    const reached = publication.milestones[step]
    if (reached === undefined || reached === null || reached > t) break
    fraction = step / (publication.milestones.length - 1)
  }
  return fraction
}

/**
 * Mean spread across a set of broadcasts, sampled along the slot.
 *
 * Averaging is the honest summary for the committee's votes: they are separate
 * broadcasts that start at slightly different instants, and one pooled curve
 * says how far "this slot's voting" has got without pretending it was a single
 * message.
 */
export function propagationCurve(
  publications: readonly Publication[],
  slotStartMs: number,
  slotDurationMs: number,
  nowMs: number,
): readonly CurveSample[] {
  const first = publications[0]
  if (first === undefined) return []

  const from = first.time
  const to = Math.min(nowMs, slotStartMs + slotDurationMs)
  if (to < from) return []

  const samples: CurveSample[] = []
  for (let index = 0; index <= SAMPLES; index++) {
    const t = from + ((to - from) * index) / SAMPLES
    const mean =
      publications.reduce((sum, publication) => sum + fractionAt(publication, t), 0) /
      publications.length
    samples.push({ offset: t - slotStartMs, fraction: mean })
  }
  return samples
}

export function blockPublications(props: SlotTimelineProps): readonly Publication[] {
  return props.publications.filter((publication) => publication.kind === 'block')
}

export function votePublications(props: SlotTimelineProps): readonly Publication[] {
  return props.publications.filter((publication) => publication.kind === 'attestation')
}

export function blockLabel(props: SlotTimelineProps): string {
  const blocks = blockPublications(props)
  const first = blocks[0]
  if (first === undefined) {
    const early = props.nowMs < props.slotStartMs + props.attestationOffsetMs
    return early ? `提案待ち #${props.proposer}` : `提案なし #${props.proposer}`
  }
  const delivered = blocks.reduce((sum, publication) => sum + publication.delivered, 0)
  return `提案 #${first.from} → ${delivered}/${props.nodeCount}`
}

export function voteLabel(props: SlotTimelineProps): string {
  const votes = votePublications(props)
  if (votes.length === 0) return `投票待ち（委員会 ${props.committeeSize}人）`

  const delivered = votes.reduce((sum, publication) => sum + publication.delivered, 0)
  const reach = votes.length * props.nodeCount
  return `投票 ${votes.length}/${props.committeeSize}人 → ${Math.round((delivered / reach) * 100)}%`
}

interface Geometry {
  readonly xOf: (offset: number) => number
  readonly yOf: (fraction: number) => number
  readonly plotBottom: number
  readonly plotRight: number
}

function geometryFor(props: SlotTimelineProps, width: number, height: number): Geometry {
  const plotRight = width - RIGHT_GUTTER
  const plotBottom = height - PLOT_BOTTOM_PAD
  const track = plotRight - LABEL_WIDTH
  return {
    xOf: (offset) => LABEL_WIDTH + (offset / props.slotDurationMs) * track,
    yOf: (fraction) => plotBottom - fraction * (plotBottom - PLOT_TOP),
    plotBottom,
    plotRight,
  }
}

function drawFrame(
  ctx: CanvasRenderingContext2D,
  props: SlotTimelineProps,
  geometry: Geometry,
): void {
  const { palette, slotDurationMs, attestationOffsetMs } = props
  ctx.save()
  ctx.font = '10px system-ui, sans-serif'
  ctx.lineWidth = 1

  // 0% and 100% rules give the curve a scale to be read against.
  ctx.strokeStyle = palette.gridline
  ctx.fillStyle = palette.inkMuted
  ctx.textAlign = 'right'
  ctx.textBaseline = 'middle'
  for (const fraction of [0, 1]) {
    const y = geometry.yOf(fraction)
    ctx.beginPath()
    ctx.moveTo(LABEL_WIDTH, y)
    ctx.lineTo(geometry.plotRight, y)
    ctx.stroke()
    ctx.fillText(fraction === 1 ? '100%' : '0%', LABEL_WIDTH - 5, y)
  }

  ctx.textAlign = 'left'
  ctx.textBaseline = 'alphabetic'
  const rules: readonly [number, string][] = [
    [0, '0 提案'],
    [attestationOffsetMs, 'Δ 投票期限'],
    [slotDurationMs, '次スロット'],
  ]
  for (const [offset, label] of rules) {
    const x = geometry.xOf(offset)
    ctx.strokeStyle = palette.gridline
    ctx.beginPath()
    ctx.moveTo(x, PLOT_TOP - 10)
    ctx.lineTo(x, geometry.plotBottom)
    ctx.stroke()
    ctx.fillStyle = palette.inkMuted
    ctx.textAlign = offset === slotDurationMs ? 'right' : 'left'
    ctx.fillText(label, offset === slotDurationMs ? x - 4 : x + 4, PLOT_TOP - 14)
  }
  ctx.restore()
}

function drawCurve(
  ctx: CanvasRenderingContext2D,
  samples: readonly CurveSample[],
  geometry: Geometry,
  palette: Palette,
  dashed: boolean,
): void {
  const start = samples[0]
  if (start === undefined) return

  ctx.save()
  ctx.strokeStyle = dashed ? palette.inkSecondary : palette.inkPrimary
  ctx.lineWidth = dashed ? 1.5 : 2
  ctx.setLineDash(dashed ? [5, 4] : [])
  ctx.lineJoin = 'round'

  ctx.beginPath()
  ctx.moveTo(geometry.xOf(start.offset), geometry.yOf(start.fraction))
  for (const sample of samples) {
    ctx.lineTo(geometry.xOf(sample.offset), geometry.yOf(sample.fraction))
  }
  ctx.stroke()

  const last = samples[samples.length - 1] as CurveSample
  ctx.setLineDash([])
  ctx.fillStyle = dashed ? palette.inkSecondary : palette.inkPrimary
  ctx.beginPath()
  ctx.arc(geometry.xOf(last.offset), geometry.yOf(last.fraction), 3, 0, Math.PI * 2)
  ctx.fill()
  ctx.restore()
}

function drawLabels(
  ctx: CanvasRenderingContext2D,
  props: SlotTimelineProps,
  geometry: Geometry,
): void {
  ctx.save()
  ctx.font = '11px system-ui, sans-serif'
  ctx.textAlign = 'left'
  ctx.textBaseline = 'middle'

  ctx.fillStyle = props.palette.inkPrimary
  ctx.fillText(blockLabel(props), geometry.plotRight + 12, PLOT_TOP + 6)
  ctx.fillStyle = props.palette.inkSecondary
  ctx.fillText(voteLabel(props), geometry.plotRight + 12, PLOT_TOP + 24)

  ctx.font = '10px system-ui, sans-serif'
  ctx.fillStyle = props.palette.inkMuted
  ctx.textBaseline = 'alphabetic'
  ctx.fillText(
    `slot ${props.slot} · 提案者 #${props.proposer}${props.proposerActive ? '' : '（非参加）'}`,
    LABEL_WIDTH,
    geometry.plotBottom + 16,
  )
  ctx.restore()
}

function drawPlayhead(
  ctx: CanvasRenderingContext2D,
  props: SlotTimelineProps,
  geometry: Geometry,
): void {
  const progress = Math.max(
    0,
    Math.min(1, (props.nowMs - props.slotStartMs) / props.slotDurationMs),
  )
  ctx.save()
  ctx.strokeStyle = props.palette.inkPrimary
  ctx.lineWidth = 1.5
  ctx.beginPath()
  ctx.moveTo(geometry.xOf(progress * props.slotDurationMs), PLOT_TOP - 10)
  ctx.lineTo(geometry.xOf(progress * props.slotDurationMs), geometry.plotBottom)
  ctx.stroke()
  ctx.restore()
}

export function SlotTimelineView(props: SlotTimelineProps) {
  const render = useCallback<RenderFn>(
    (ctx, width, height) => {
      ctx.fillStyle = props.palette.surface
      ctx.fillRect(0, 0, width, height)

      const geometry = geometryFor(props, width, height)
      drawFrame(ctx, props, geometry)

      const { slotStartMs, slotDurationMs, nowMs, palette } = props
      drawCurve(
        ctx,
        propagationCurve(blockPublications(props), slotStartMs, slotDurationMs, nowMs),
        geometry,
        palette,
        false,
      )
      drawCurve(
        ctx,
        propagationCurve(votePublications(props), slotStartMs, slotDurationMs, nowMs),
        geometry,
        palette,
        true,
      )

      drawPlayhead(ctx, props, geometry)
      drawLabels(ctx, props, geometry)
    },
    [props],
  )

  return <CanvasSurface render={render} label="スロット内の伝播" />
}
