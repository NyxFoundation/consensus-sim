/**
 * Minimal labelled inputs. Deliberately not a component library — the control
 * panel is the only consumer and every extra abstraction here is weight the
 * simulator does not need.
 */

interface SliderProps {
  readonly label: string
  readonly value: number
  readonly min: number
  readonly max: number
  readonly step: number
  readonly onChange: (value: number) => void
  readonly format?: (value: number) => string
  readonly hint?: string
}

export function SliderField({ label, value, min, max, step, onChange, format, hint }: SliderProps) {
  return (
    <label className="field">
      <span className="field-label">
        {label}
        <span className="field-value">{format ? format(value) : value}</span>
      </span>
      <input
        type="range"
        min={min}
        max={max}
        step={step}
        value={value}
        onChange={(event) => onChange(Number(event.target.value))}
      />
      {hint !== undefined && <span className="field-hint">{hint}</span>}
    </label>
  )
}

interface SelectProps<T extends string> {
  readonly label: string
  readonly value: T
  readonly options: readonly { readonly value: T; readonly label: string }[]
  readonly onChange: (value: T) => void
}

export function SelectField<T extends string>({ label, value, options, onChange }: SelectProps<T>) {
  return (
    <label className="field">
      <span className="field-label">{label}</span>
      <select value={value} onChange={(event) => onChange(event.target.value as T)}>
        {options.map((option) => (
          <option key={option.value} value={option.value}>
            {option.label}
          </option>
        ))}
      </select>
    </label>
  )
}

interface ToggleProps {
  readonly label: string
  readonly checked: boolean
  readonly onChange: (checked: boolean) => void
}

export function ToggleField({ label, checked, onChange }: ToggleProps) {
  return (
    <label className="field field-inline">
      <input
        type="checkbox"
        checked={checked}
        onChange={(event) => onChange(event.target.checked)}
      />
      <span className="field-label">{label}</span>
    </label>
  )
}
