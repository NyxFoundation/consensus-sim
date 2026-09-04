/**
 * Keyboard shortcuts for the scenario operations (任意: 介入・シナリオ操作の
 * キーボードショートカット): one window-level keydown listener per caller,
 * mapping `KeyboardEvent.key` (letters case-insensitively) to the same
 * actions the slot bar's and the scenario panel's buttons perform. A
 * shortcut never fires while a text entry (input / textarea / select /
 * contenteditable) has the focus, while a modifier key is held (the
 * browser's own shortcuts), or — for Space — while a control that Space
 * activates natively (button, summary, link) has the focus, so a focused
 * button is never triggered twice. The bound buttons announce their key
 * through aria-keyshortcuts and the slot bar's ⓘ lists them.
 */

import { useEffect, useRef } from 'react'

/** Handlers keyed by `KeyboardEvent.key`; single characters lower-case. */
export type ShortcutHandlers = Readonly<Record<string, () => void>>

/** The shortcut list as shown to the user (the slot bar's ⓘ). */
export const SHORTCUT_HINT =
  'キーボード: ← → でカーソルを 1 スロット移動、Home で先頭、End で最新、Space で自動再生の開始・一時停止、N で ＋1 スロット進める、S で現在のシナリオを保存。入力欄にフォーカスがあるときと修飾キー併用時は無効'

function isTextEntry(target: EventTarget | null): boolean {
  return (
    target instanceof HTMLElement &&
    target.matches('input, textarea, select, [contenteditable=""], [contenteditable="true"]')
  )
}

function activatesNatively(target: EventTarget | null): boolean {
  return target instanceof HTMLElement && target.matches('button, summary, a, [role="button"]')
}

/** The handler key for an event: letters lower-cased, named keys as is. */
const keyOf = (e: KeyboardEvent): string => (e.key.length === 1 ? e.key.toLowerCase() : e.key)

/**
 * Bind `handlers` while `enabled`. The latest handlers are read at key time,
 * so callers may pass a fresh object every render without re-subscribing.
 */
export function useShortcuts(handlers: ShortcutHandlers, enabled = true): void {
  const latest = useRef(handlers)
  latest.current = handlers
  useEffect(() => {
    if (!enabled) return
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.defaultPrevented || e.ctrlKey || e.metaKey || e.altKey) return
      if (isTextEntry(e.target)) return
      if (e.key === ' ' && activatesNatively(e.target)) return
      const handler = latest.current[keyOf(e)]
      if (handler === undefined) return
      e.preventDefault()
      handler()
    }
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [enabled])
}
