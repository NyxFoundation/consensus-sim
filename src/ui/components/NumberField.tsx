/**
 * Unified numeric input. Renders one native <input type="number"> (no
 * wrapper — aria-label / id / name stay on the element a query or a label's
 * `for` expects) with appearance: none and the app's stepper look from
 * styles.css; the controlled parse/commit/retain-invalid-text behaviour
 * belongs to each caller (see ParamsPanel's CommitNumberField), not to this
 * presentational wrapper.
 */

import { forwardRef } from 'react'
import type { InputHTMLAttributes } from 'react'

export interface NumberFieldProps
  extends Omit<InputHTMLAttributes<HTMLInputElement>, 'type'> {}

export const NumberField = forwardRef<HTMLInputElement, NumberFieldProps>(
  function NumberField({ className, ...rest }, ref) {
    return (
      <input
        ref={ref}
        type="number"
        data-ui="number"
        className={className}
        {...rest}
      />
    )
  },
)
