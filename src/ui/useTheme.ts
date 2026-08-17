/**
 * Theme selection and the reduced-motion preference.
 *
 * The explicit choice wins over the OS setting in both directions; the OS is
 * only the initial value. `prefers-reduced-motion` is honoured everywhere it can
 * be — the fork tree falls back from a continuous drift to discrete slot steps.
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
  const [mode, setMode] = useState<ThemeMode>(() =>
    systemPrefers('(prefers-color-scheme: dark)') ? 'dark' : 'light',
  )

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
