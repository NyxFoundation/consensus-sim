/**
 * Theme selection and the reduced-motion preference.
 *
 * Light is the default regardless of the OS setting. That is deliberate rather
 * than an oversight: the dark surface with bright marks is a plausible cause of
 * the eye strain this visual language was rebuilt to fix, so the calmer surface
 * is what a first visit gets. The toggle is one click away for anyone who wants
 * the other one.
 *
 * `prefers-reduced-motion` *is* honoured from the OS — it states a need, not a
 * taste, so there is nothing to override.
 */

import { useEffect, useState } from 'react'
import { paletteFor } from './theme'
import type { Palette, ThemeMode } from './theme'

function systemPrefers(query: string): boolean {
  return typeof window !== 'undefined' && window.matchMedia(query).matches
}

export function useThemeMode(): {
  readonly mode: ThemeMode
  readonly palette: Palette
  toggle(): void
} {
  const [mode, setMode] = useState<ThemeMode>('light')

  useEffect(() => {
    document.documentElement.dataset['theme'] = mode
  }, [mode])

  return {
    mode,
    palette: paletteFor(mode),
    toggle: () => setMode((current) => (current === 'dark' ? 'light' : 'dark')),
  }
}

export function usePrefersReducedMotion(): boolean {
  const [reduced, setReduced] = useState(() =>
    systemPrefers('(prefers-reduced-motion: reduce)'),
  )

  useEffect(() => {
    const media = window.matchMedia('(prefers-reduced-motion: reduce)')
    const listener = (event: MediaQueryListEvent) => setReduced(event.matches)
    media.addEventListener('change', listener)
    return () => media.removeEventListener('change', listener)
  }, [])

  return reduced
}
