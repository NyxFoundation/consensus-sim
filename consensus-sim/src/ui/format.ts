import type { Checkpoint } from '../domain'

/** Display name of a block: the anchor is B0, proposals count up from B1. */
export function blockName(index: number): string {
  return `B${index}`
}

/** Display name of a checkpoint {epoch, block}: the block it stands on and
 * the epoch it stands for, e.g. B4@e1 — the same block can be the
 * checkpoint of consecutive epochs, so the epoch is part of the identity. */
export function checkpointName(checkpoint: Checkpoint): string {
  return `${blockName(checkpoint.block)}@e${checkpoint.epoch}`
}

/** A stake for display: whole numbers as they are, leaked fractions to two
 * decimals — so a penalised validator reads as 24 → 18 → 13.5 → 10.13. */
export function stakeLabel(stake: number): string {
  return Number.isInteger(stake) ? String(stake) : stake.toFixed(2)
}
