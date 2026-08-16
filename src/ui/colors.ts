/**
 * One palette for both views.
 *
 * `colorForRoot` is deliberately shared between the fork tree and the validator
 * grid: a cell in the grid and a block in the tree carry the same hue, so
 * "which block does this half of the network believe in" is answered by
 * matching colours rather than by reading hex digits.
 */

export const PALETTE = {
  background: '#0e1116',
  panel: '#161b22',
  panelAlt: '#1c2430',
  border: '#2b3440',
  grid: '#21272f',
  text: '#e6edf3',
  muted: '#8b949e',
  canonical: '#58a6ff',
  finalized: '#3fb950',
  justified: '#d29922',
  orphan: '#4a525c',
  boost: '#f778ba',
  danger: '#f85149',
} as const

/** Stable hue per block root, so the same block looks the same everywhere. */
export function colorForRoot(root: string, lightness = 55): string {
  const hue = Number.parseInt(root.slice(0, 4), 16) % 360
  const saturation = 62 + (Number.parseInt(root.slice(4, 6), 16) % 20)
  return `hsl(${hue} ${saturation}% ${lightness}%)`
}

export function withAlpha(hslColor: string, alpha: number): string {
  return hslColor.replace(')', ` / ${alpha})`)
}
