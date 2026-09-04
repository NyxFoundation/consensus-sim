/**
 * On-demand hint (ⓘ). Supplementary explanation never sits in a panel as
 * prose: it lives in this element's data-hint attribute (also its
 * accessible name) and is shown only while the glyph is hovered or focused.
 * Because the explanation is an attribute and not a text node at rest, the
 * no-resident-prose check (tests/ui/prose.test.tsx) can tell hints from
 * prose mechanically.
 *
 * The tooltip is rendered through a portal at the document root with a
 * fixed position computed from the glyph's box, so it is never clipped by
 * the scrolling dock or stage it belongs to, and it is clamped to the
 * viewport so it stays readable at the dock's right edge.
 */

import { useState } from 'react'
import type { FocusEvent, KeyboardEvent, MouseEvent } from 'react'
import { createPortal } from 'react-dom'

export interface HintProps {
  readonly text: string
  readonly className?: string
}

/** Tooltip width; the CSS max-width for .hint-tooltip matches it. */
const TOOLTIP_W = 320
const EDGE = 8

interface Anchor {
  readonly top: number
  readonly left: number
}

function anchorFor(el: Element): Anchor {
  const r = el.getBoundingClientRect()
  const width = window.innerWidth || document.documentElement.clientWidth
  return {
    top: r.bottom + 4,
    left: Math.max(EDGE, Math.min(r.left, width - TOOLTIP_W - EDGE)),
  }
}

export function Hint({ text, className }: HintProps) {
  const [anchor, setAnchor] = useState<Anchor | undefined>()
  const show = (e: MouseEvent<HTMLElement> | FocusEvent<HTMLElement>) =>
    setAnchor(anchorFor(e.currentTarget))
  const hide = () => setAnchor(undefined)
  const onKeyDown = (e: KeyboardEvent<HTMLElement>) => {
    if (e.key === 'Escape') hide()
  }
  return (
    <>
      <span
        data-ui="hint"
        className={className}
        role="note"
        tabIndex={0}
        aria-label={text}
        data-hint={text}
        onMouseEnter={show}
        onMouseLeave={hide}
        onFocus={show}
        onBlur={hide}
        onKeyDown={onKeyDown}
      >
        ⓘ
      </span>
      {anchor !== undefined &&
        createPortal(
          <div
            className="hint-tooltip"
            role="tooltip"
            style={{ top: anchor.top, left: anchor.left, width: TOOLTIP_W }}
          >
            {text}
          </div>,
          document.body,
        )}
    </>
  )
}
