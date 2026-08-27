/**
 * Saved-scenario store on top of localStorage: one key holding a list of
 * serialized scenarios with save metadata. All structural validation lives
 * in the domain codec (`parseScenario`); this module only moves JSON in and
 * out of storage and never throws on a corrupt store — it just drops
 * unreadable entries, so one bad record cannot brick the list.
 */

import { parseScenario, serializeScenario } from '../domain'
import type { SavedRun, Scenario, SerializedScenario } from '../domain'

const STORE_KEY = 'consensus-sim.scenarios'

export interface StoredScenario {
  readonly id: string
  readonly savedAt: string
  readonly data: SerializedScenario
}

function readAll(storage: Storage): StoredScenario[] {
  const raw = storage.getItem(STORE_KEY)
  if (raw === null) return []
  try {
    const list = JSON.parse(raw)
    if (!Array.isArray(list)) return []
    return list.filter((e): e is StoredScenario => {
      try {
        parseScenario(e.data)
        return typeof e.id === 'string' && typeof e.savedAt === 'string'
      } catch {
        return false
      }
    })
  } catch {
    return []
  }
}

function writeAll(storage: Storage, list: readonly StoredScenario[]): void {
  storage.setItem(STORE_KEY, JSON.stringify(list))
}

export function listScenarios(storage: Storage = localStorage): StoredScenario[] {
  return readAll(storage)
}

export function saveScenario(
  scenario: Scenario,
  runSlot: number,
  storage: Storage = localStorage,
): StoredScenario {
  const list = readAll(storage)
  const savedAt = new Date().toISOString()
  const entry: StoredScenario = {
    id: `${savedAt}-${list.length}`,
    savedAt,
    data: serializeScenario(scenario, runSlot),
  }
  writeAll(storage, [entry, ...list])
  return entry
}

export function removeScenario(
  id: string,
  storage: Storage = localStorage,
): void {
  writeAll(
    storage,
    readAll(storage).filter((e) => e.id !== id),
  )
}

/** Parse a stored entry back into a validated run. Throws if invalid. */
export function loadStored(entry: StoredScenario): SavedRun {
  return parseScenario(entry.data)
}
