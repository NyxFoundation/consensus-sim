/**
 * Theme selection. Light is the default regardless of the OS setting. That
 * is deliberate rather than an oversight: the dark surface with bright marks
 * is a plausible cause of the eye strain this visual language was rebuilt to
 * fix, so the calmer surface is what a first visit gets. The toggle is one
 * click away for anyone who wants the other one.
 */

import { useEffect, useState } from 'react'

export type ThemeMode = 'light' | 'dark'

export function useThemeMode(): {
  readonly mode: ThemeMode
  toggle(): void
} {
  const [mode, setMode] = useState<ThemeMode>('light')

  useEffect(() => {
    document.documentElement.dataset['theme'] = mode
  }, [mode])

  return {
    mode,
    toggle: () => setMode((current) => (current === 'dark' ? 'light' : 'dark')),
  }
}
