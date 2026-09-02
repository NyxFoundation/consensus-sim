/** Display name of a block: the anchor is B0, proposals count up from B1. */
export function blockName(index: number): string {
  return `B${index}`
}

/** A stake for display: whole numbers as they are, leaked fractions to two
 * decimals — so a penalised validator reads as 24 → 18 → 13.5 → 10.13. */
export function stakeLabel(stake: number): string {
  return Number.isInteger(stake) ? String(stake) : stake.toFixed(2)
}
