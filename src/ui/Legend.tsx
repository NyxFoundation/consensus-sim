/**
 * Legends live in HTML rather than on the canvas: crisper text, selectable, and
 * reachable by a screen reader.
 *
 * Both views have two or more categories, so a legend is always present — and
 * the offline swatch carries a hatch, so no category is identified by colour
 * alone.
 */

import type { CSSProperties } from 'react'

export interface LegendItem {
  readonly label: string
  readonly color?: string
  /** Draws the 45-degree hatch used for non-participating validators. */
  readonly hatch?: boolean
  /** Draws an outline-only swatch, for state carried by a stroke. */
  readonly outline?: boolean
  readonly count?: number
}

function swatchStyle(item: LegendItem): CSSProperties {
  if (item.hatch === true) {
    return {
      backgroundColor: 'var(--gridline)',
      backgroundImage:
        'repeating-linear-gradient(45deg, var(--ink-muted) 0 1.4px, transparent 1.4px 4.2px)',
    }
  }
  if (item.outline === true) {
    return { border: `2px solid ${item.color ?? 'var(--ink-muted)'}`, background: 'transparent' }
  }
  return { backgroundColor: item.color ?? 'var(--neutral-cell)' }
}

export function Legend({ items }: { items: readonly LegendItem[] }) {
  return (
    <ul className="legend">
      {items.map((item) => (
        <li key={item.label}>
          <span className="legend-swatch" style={swatchStyle(item)} aria-hidden="true" />
          <span className="legend-label">{item.label}</span>
          {item.count !== undefined && <span className="legend-count">{item.count}</span>}
        </li>
      ))}
    </ul>
  )
}
