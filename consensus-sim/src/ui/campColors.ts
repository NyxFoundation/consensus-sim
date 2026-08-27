/**
 * Stable categorical colour for each conflicting branch.
 *
 * The predecessor assigned a slot to every head that differed from the observed
 * node's, which meant the lagging head of each passing slot consumed one. Three
 * slots of simulation exhausted the palette and everything after that fell into
 * "other" — the display went colourful for three slots and then grey forever.
 *
 * Slots now go only to camps, which exist solely during a genuine fork, so they
 * are neither numerous nor short-lived. A camp keeps its colour for as long as
 * it exists: colour follows the branch, never its rank, so a minority becoming
 * the majority does not repaint anything.
 */

import { useRef } from 'react'
import type { Hash } from '../core/hash'
import type { Simulation } from '../core/simulation'
import type { Camp } from './divergence'

export type CampSlot = 1 | 2 | 3 | 4
/** Beyond the three validated slots, camps share one muted colour. */
export const OTHER: CampSlot = 4

const MAX_NAMED_CAMPS = 3

export interface CampRegistry {
  slots: Map<Hash, CampSlot>
  next: number
}

export function createRegistry(): CampRegistry {
  return { slots: new Map(), next: 0 }
}

export function assignCampSlots(
  registry: CampRegistry,
  camps: readonly Camp[],
): Map<Hash, CampSlot> {
  const assigned = new Map<Hash, CampSlot>()

  for (const camp of camps) {
    const existing = registry.slots.get(camp.head)
    if (existing !== undefined) {
      assigned.set(camp.head, existing)
      continue
    }
    if (registry.next >= MAX_NAMED_CAMPS) {
      assigned.set(camp.head, OTHER)
      continue
    }
    registry.next += 1
    const slot = registry.next as CampSlot
    registry.slots.set(camp.head, slot)
    assigned.set(camp.head, slot)
  }

  return assigned
}

/** Keyed to the `Simulation`, so a reset starts colour assignment over. */
export function useCampColors(sim: Simulation, camps: readonly Camp[]): Map<Hash, CampSlot> {
  const ref = useRef<{ sim: Simulation | null; registry: CampRegistry }>({
    sim: null,
    registry: createRegistry(),
  })
  if (ref.current.sim !== sim) {
    ref.current = { sim, registry: createRegistry() }
  }
  return assignCampSlots(ref.current.registry, camps)
}
