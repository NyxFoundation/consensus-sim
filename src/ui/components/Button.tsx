/**
 * Unified button. Renders one native <button> (no wrapper element, so the
 * caller's DOM structure and every forwarded attribute — aria-label,
 * aria-pressed, disabled, title — stay exactly where a test or a label
 * expects them) with data-ui="button" for the token-based reset in
 * styles.css and data-variant / data-size for the look.
 */

import { forwardRef } from 'react'
import type { ButtonHTMLAttributes } from 'react'

export type ButtonVariant = 'default' | 'primary' | 'ghost'
export type ButtonSize = 'sm' | 'md'

export interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  readonly variant?: ButtonVariant
  readonly size?: ButtonSize
}

export const Button = forwardRef<HTMLButtonElement, ButtonProps>(function Button(
  { variant = 'default', size = 'md', type = 'button', className, ...rest },
  ref,
) {
  return (
    <button
      ref={ref}
      type={type}
      data-ui="button"
      data-variant={variant}
      data-size={size}
      className={className}
      {...rest}
    />
  )
})
