/**
 * Labelled group of exclusive options (mode tabs, on/off pairs, protocol
 * choice buttons, per-validator operating state). One hairline box, the
 * active option filled — the visual language's segmented control, unified
 * so every occurrence shares the same markup, a11y wiring and styling hook.
 */

import { Button } from './Button'
import type { ButtonSize } from './Button'

export interface SegmentedOption<T extends string> {
  readonly key: T
  readonly label: string
}

export interface SegmentedProps<T extends string> {
  readonly label: string
  readonly value: T
  readonly options: readonly SegmentedOption<T>[]
  readonly className?: string
  readonly size?: ButtonSize
  onChange(value: T): void
}

export function Segmented<T extends string>({
  label,
  value,
  options,
  className,
  size = 'md',
  onChange,
}: SegmentedProps<T>) {
  return (
    <div
      className={['segmented', className].filter(Boolean).join(' ')}
      role="group"
      aria-label={label}
      data-ui="segmented"
    >
      {options.map((o) => (
        <Button
          key={o.key}
          size={size}
          className={value === o.key ? 'active' : ''}
          aria-pressed={value === o.key}
          onClick={() => onChange(o.key)}
        >
          {o.label}
        </Button>
      ))}
    </div>
  )
}
