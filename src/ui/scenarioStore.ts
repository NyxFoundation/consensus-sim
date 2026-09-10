/**
 * Saved-scenario store on top of localStorage: one key holding a list of
 * serialized scenarios with save metadata — the save time and, optionally,
 * a name and a note (命名・メモ: what the experiment was meant to confirm).
 * All structural validation of the scenario itself lives in the domain
 * codec (`parseScenario`, resolving a saved attack through the attack
 * library); this module only moves JSON in and out of storage and never
 * throws on a corrupt store — it drops unreadable entries and ignores a
 * malformed name or note, so one bad record cannot brick the list.
 */

import { ATTACK_REGISTRY, parseScenario, serializeScenario } from '../domain'
import type { SavedRun, Scenario, SerializedScenario } from '../domain'

const STORE_KEY = 'consensus-sim.scenarios'

/** The human-authored labels of a saved scenario; absent when blank. */
export interface ScenarioMeta {
  readonly name?: string
  readonly note?: string
}

export interface StoredScenario extends ScenarioMeta {
  readonly id: string
  readonly savedAt: string
  readonly data: SerializedScenario
}

/** Trim both labels and keep only the non-blank ones. */
function normalizeMeta(meta: ScenarioMeta): ScenarioMeta {
  const name = meta.name?.trim() ?? ''
  const note = meta.note?.trim() ?? ''
  return { ...(name === '' ? {} : { name }), ...(note === '' ? {} : { note }) }
}

/** The labels a stored record carries, ignoring anything that is not a string. */
function metaOf(raw: Record<string, unknown>): ScenarioMeta {
  return normalizeMeta({
    ...(typeof raw.name === 'string' ? { name: raw.name } : {}),
    ...(typeof raw.note === 'string' ? { note: raw.note } : {}),
  })
}

function readAll(storage: Storage): StoredScenario[] {
  const raw = storage.getItem(STORE_KEY)
  if (raw === null) return []
  try {
    const list = JSON.parse(raw)
    if (!Array.isArray(list)) return []
    const out: StoredScenario[] = []
    for (const e of list) {
      if (typeof e !== 'object' || e === null) continue
      const record = e as Record<string, unknown>
      if (typeof record.id !== 'string' || typeof record.savedAt !== 'string') continue
      try {
        parseScenario(record.data, ATTACK_REGISTRY)
      } catch {
        continue
      }
      out.push({
        id: record.id,
        savedAt: record.savedAt,
        data: record.data as SerializedScenario,
        ...metaOf(record),
      })
    }
    return out
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
  meta: ScenarioMeta = {},
  storage: Storage = localStorage,
): StoredScenario {
  const list = readAll(storage)
  const savedAt = new Date().toISOString()
  const entry: StoredScenario = {
    id: `${savedAt}-${list.length}`,
    savedAt,
    data: serializeScenario(scenario, runSlot),
    ...normalizeMeta(meta),
  }
  writeAll(storage, [entry, ...list])
  return entry
}

/** Replace the name and note of a saved scenario; the run itself is untouched. */
export function updateScenarioMeta(
  id: string,
  meta: ScenarioMeta,
  storage: Storage = localStorage,
): void {
  writeAll(
    storage,
    readAll(storage).map((e) =>
      e.id === id ? { id: e.id, savedAt: e.savedAt, data: e.data, ...normalizeMeta(meta) } : e,
    ),
  )
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
  return parseScenario(entry.data, ATTACK_REGISTRY)
}
