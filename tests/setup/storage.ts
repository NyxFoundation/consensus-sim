/**
 * Web storage shim for the jsdom test environment.
 *
 * Recent Node runtimes define a `localStorage` global of their own, inert
 * unless the process was started with `--localstorage-file`. The jsdom
 * environment only copies a window key onto the global object when the key
 * is not there already, so that inert global wins and the browser storage
 * never reaches the tests — every mount that reads a saved scenario throws.
 * Install a minimal in-memory Storage in its place, and only when the global
 * one cannot actually be written to, so a real browser-like storage (in a
 * runtime without the Node global) is left untouched.
 */

function createMemoryStorage(): Storage {
  const entries = new Map<string, string>()
  const storage: Storage = {
    get length() {
      return entries.size
    },
    clear() {
      entries.clear()
    },
    getItem(key: string) {
      return entries.get(String(key)) ?? null
    },
    key(index: number) {
      return [...entries.keys()][index] ?? null
    },
    removeItem(key: string) {
      entries.delete(String(key))
    },
    setItem(key: string, value: string) {
      entries.set(String(key), String(value))
    },
  }
  return storage
}

/** Whether a value behaves as a Storage that actually holds what it is given. */
function isUsableStorage(candidate: unknown): boolean {
  const probe = '__storage_probe__'
  try {
    const storage = candidate as Storage
    storage.setItem(probe, '1')
    const held = storage.getItem(probe) === '1'
    storage.removeItem(probe)
    return held
  } catch {
    return false
  }
}

// Node-environment test files (source-text checks) have no DOM and no use for
// storage; leave their global untouched.
if (typeof document !== 'undefined' && !isUsableStorage(globalThis.localStorage)) {
  Object.defineProperty(globalThis, 'localStorage', {
    value: createMemoryStorage(),
    configurable: true,
    writable: true,
  })
}
