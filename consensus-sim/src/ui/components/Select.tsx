/**
 * Unified select. Keeps the real native <select> (so keyboard and a11y
 * behaviour stay exactly the browser's own) but wraps it in a small span
 * that draws the custom chevron and hides the native one, so it never
 * looks like an unstyled browser control.
 */

import { forwardRef } from 'react'
import type { SelectHTMLAttributes } from 'react'

export interface SelectProps extends SelectHTMLAttributes<HTMLSelectElement> {}

export const Select = forwardRef<HTMLSelectElement, SelectProps>(function Select(
  { className, children, ...rest },
  ref,
) {
  return (
    <span className="field-select" data-ui="select">
      <select ref={ref} className={className} {...rest}>
        {children}
      </select>
    </span>
  )
})
