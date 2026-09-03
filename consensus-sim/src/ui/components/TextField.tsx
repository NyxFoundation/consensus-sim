/**
 * Unified text entry: TextField renders one native <input type="text">,
 * TextArea one native <textarea> — no wrapper, so aria-label / placeholder /
 * value stay on the element a query or a label's `for` expects — both with
 * appearance: none and the app's field look from styles.css
 * (data-ui="text"). Used for the scenario name and note.
 */

import { forwardRef } from 'react'
import type { InputHTMLAttributes, TextareaHTMLAttributes } from 'react'

export interface TextFieldProps
  extends Omit<InputHTMLAttributes<HTMLInputElement>, 'type'> {}

export const TextField = forwardRef<HTMLInputElement, TextFieldProps>(
  function TextField({ className, ...rest }, ref) {
    return <input ref={ref} type="text" data-ui="text" className={className} {...rest} />
  },
)

export interface TextAreaProps extends TextareaHTMLAttributes<HTMLTextAreaElement> {}

export const TextArea = forwardRef<HTMLTextAreaElement, TextAreaProps>(
  function TextArea({ className, ...rest }, ref) {
    return <textarea ref={ref} data-ui="text" className={className} {...rest} />
  },
)
