/**
 * Theme selection. Three modes: system (default — follows the OS
 * prefers-color-scheme media query via tokens.css, no data-theme attribute
 * written at all), light and dark (an explicit override, written to
 * data-theme and persisted). The default staying light regardless of the OS
 * setting was a deliberate earlier choice against the eye strain a bright
 * mark on a dark surface can cause; following the OS by default is the more
 * conventional behaviour and the explicit override remains one click (or
 * one more) away for anyone who wants a different one, in either direction.
 */

import { useEffect, useState } from 'react'

export type ThemeMode = 'system' | 'light' | 'dark'
export type ResolvedTheme = 'light' | 'dark'

const STORAGE_KEY = 'consensus-sim.theme'
const CYCLE: readonly ThemeMode[] = ['system', 'light', 'dark']

function isThemeMode(value: unknown): value is ThemeMode {
  return value === 'system' || value === 'light' || value === 'dark'
}

function readStoredMode(): ThemeMode {
  try {
    const stored = window.localStorage?.getItem(STORAGE_KEY)
    return isThemeMode(stored) ? stored : 'system'
  } catch {
    // localStorage unavailable (privacy mode, jsdom without storage) — fall
    // back to the default rather than throwing.
    return 'system'
  }
}

function writeStoredMode(mode: ThemeMode) {
  try {
    window.localStorage?.setItem(STORAGE_KEY, mode)
  } catch {
    // Ignore: persistence is a convenience, not a requirement.
  }
}

function prefersDark(): boolean {
  try {
    return window.matchMedia?.('(prefers-color-scheme: dark)').matches ?? false
  } catch {
    // matchMedia unavailable (jsdom without it configured) — assume light.
    return false
  }
}

export interface ThemeControl {
  readonly mode: ThemeMode
  readonly resolved: ResolvedTheme
  setMode(mode: ThemeMode): void
  cycle(): void
}

export function useThemeMode(): ThemeControl {
  const [mode, setModeState] = useState<ThemeMode>(() => readStoredMode())
  const [systemDark, setSystemDark] = useState<boolean>(() => prefersDark())

  // Track the OS setting so `resolved` stays correct in system mode even if
  // the user never touches the toggle.
  useEffect(() => {
    let mql: MediaQueryList | undefined
    try {
      mql = window.matchMedia?.('(prefers-color-scheme: dark)')
    } catch {
      mql = undefined
    }
    if (!mql) return
    const onChange = () => setSystemDark(mql!.matches)
    mql.addEventListener?.('change', onChange)
    return () => mql?.removeEventListener?.('change', onChange)
  }, [])

  useEffect(() => {
    if (mode === 'system') {
      delete document.documentElement.dataset['theme']
    } else {
      document.documentElement.dataset['theme'] = mode
    }
  }, [mode])

  const setMode = (next: ThemeMode) => {
    setModeState(next)
    writeStoredMode(next)
  }

  const cycle = () => {
    const next = CYCLE[(CYCLE.indexOf(mode) + 1) % CYCLE.length]!
    setMode(next)
  }

  const resolved: ResolvedTheme =
    mode === 'system' ? (systemDark ? 'dark' : 'light') : mode

  return { mode, resolved, setMode, cycle }
}
