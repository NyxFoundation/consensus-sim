/**
 * A number input that commits every valid value as it is typed and keeps
 * the raw text while it is invalid (empty, out of range), so a field can be
 * cleared and retyped without snapping back. Shared by the protocol
 * parameter panel and the attack panel; renders the unified NumberField.
 */

import { useEffect, useState } from 'react'
import { NumberField } from './components/NumberField'

export interface CommitNumberFieldProps {
  readonly label: string
  readonly value: number
  readonly min?: number
  readonly max?: number
  readonly step?: number
  readonly integer?: boolean
  readonly className?: string
  onCommit(value: number): void
}

export function CommitNumberField({
  label,
  value,
  min,
  max,
  step,
  integer = false,
  className = 'slot-input',
  onCommit,
}: CommitNumberFieldProps) {
  const parse = (t: string): number | undefined => {
    if (t.trim() === '') return undefined
    const n = Number(t)
    if (!Number.isFinite(n)) return undefined
    if (integer && !Number.isInteger(n)) return undefined
    if (min !== undefined && n < min) return undefined
    if (max !== undefined && n > max) return undefined
    return n
  }
  const [text, setText] = useState(String(value))
  // Follow an external change of the value (preset switch, scenario reload)
  // unless the text already parses to it.
  useEffect(() => {
    setText((t) => (parse(t) === value ? t : String(value)))
  }, [value])
  return (
    <NumberField
      className={className}
      aria-label={label}
      min={min}
      max={max}
      step={step}
      value={text}
      onChange={(e) => {
        setText(e.target.value)
        const n = parse(e.target.value)
        if (n !== undefined && n !== value) onCommit(n)
      }}
    />
  )
}
