/**
 * Unified checkbox. Renders one native <input type="checkbox"> (no wrapper,
 * so it stays the immediate child of whatever <label> the caller places
 * around it) styled with appearance: none from styles.css.
 */

import { forwardRef } from 'react'
import type { InputHTMLAttributes } from 'react'

export interface CheckboxProps
  extends Omit<InputHTMLAttributes<HTMLInputElement>, 'type'> {}

export const Checkbox = forwardRef<HTMLInputElement, CheckboxProps>(
  function Checkbox({ className, ...rest }, ref) {
    return (
      <input
        ref={ref}
        type="checkbox"
        data-ui="checkbox"
        className={className}
        {...rest}
      />
    )
  },
)
