/**
 * Unified disclosure. Wraps the native <details>/<summary> — every panel
 * (攻撃 / プロトコルパラメータ / 介入 / シナリオ) opens by default and stays a
 * plain, keyboard-operable disclosure; this only supplies the app's summary
 * styling and the data-ui hook.
 */

import type { ReactNode } from 'react'

export interface DisclosureProps {
  readonly summary: ReactNode
  readonly children: ReactNode
  readonly defaultOpen?: boolean
  readonly className?: string
  readonly summaryClassName?: string
}

export function Disclosure({
  summary,
  children,
  defaultOpen = true,
  className,
  summaryClassName,
}: DisclosureProps) {
  return (
    <details open={defaultOpen} data-ui="disclosure" className={className}>
      <summary className={['panel-summary', summaryClassName].filter(Boolean).join(' ')}>
        {summary}
      </summary>
      {children}
    </details>
  )
}
