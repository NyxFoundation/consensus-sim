/**
 * Assigns colour to *disagreement*, not to block identity.
 *
 * The previous design hashed each block root into a hue. Blocks are an unbounded
 * stream, so that generated a new fully-saturated colour every slot and repainted
 * the whole validator grid with it — a large-area colour change several times a
 * second that carried no information, because everyone still agreed.
 *
 * Here the reference frame is the observed node's head. Nodes that share it are
 * neutral, so the steady state is motionless, and only genuinely contested heads
 * take a categorical slot. Slots are handed out in first-seen order and kept for
 * the run: colour follows the block, never its rank, so the majority and a
 * minority swapping places does not repaint the survivors.
 */

import { useRef } from 'react'
import type { Hash } from '../core/hash'
import type { Simulation } from '../core/simulation'

/** Cell kinds, in the order the legend lists them. */
export const AGREE = 0
export const OTHER = 4
export type CellKind = 0 | 1 | 2 | 3 | 4

const MAX_NAMED_DISSENT = 3

export interface HeadAssignment {
  /** One kind per node, index-aligned with the heads array. */
  readonly kinds: readonly CellKind[]
  /** Contested heads that earned a named slot, with how many nodes hold them. */
  readonly dissent: readonly { readonly head: Hash; readonly kind: CellKind; readonly count: number }[]
  readonly agreeCount: number
  readonly otherCount: number
}

export interface HeadRegistry {
  slots: Map<Hash, CellKind>
  next: number
}

export function createRegistry(): HeadRegistry {
  return { slots: new Map(), next: 0 }
}

function assignSlot(registry: HeadRegistry, head: Hash): CellKind {
  const existing = registry.slots.get(head)
  if (existing !== undefined) return existing

  if (registry.next >= MAX_NAMED_DISSENT) return OTHER
  registry.next += 1
  const slot = registry.next as CellKind
  registry.slots.set(head, slot)
  return slot
}

/**
 * Derives per-node cell kinds against a reference head, mutating `registry` to
 * remember any newly contested head's slot.
 */
export function assignKinds(
  registry: HeadRegistry,
  heads: readonly Hash[],
  referenceHead: Hash,
): HeadAssignment {
  const counts = new Map<Hash, number>()
  const kinds: CellKind[] = []
  let agreeCount = 0
  let otherCount = 0

  for (const head of heads) {
    if (head === referenceHead) {
      kinds.push(AGREE)
      agreeCount += 1
      continue
    }
    const kind = assignSlot(registry, head)
    kinds.push(kind)
    if (kind === OTHER) otherCount += 1
    else counts.set(head, (counts.get(head) ?? 0) + 1)
  }

  const dissent = [...counts.entries()]
    .map(([head, count]) => ({ head, kind: registry.slots.get(head) ?? OTHER, count }))
    .sort((a, b) => a.kind - b.kind)

  return { kinds, dissent, agreeCount, otherCount }
}

/**
 * React binding. The registry is keyed to the `Simulation` instance, so a reset
 * starts colour assignment over rather than carrying stale slots into a new
 * experiment — while within one run a block keeps its colour for life.
 */
export function useHeadAssignment(
  sim: Simulation,
  heads: readonly Hash[],
  referenceHead: Hash,
): HeadAssignment {
  const ref = useRef<{ sim: Simulation | null; registry: HeadRegistry }>({
    sim: null,
    registry: createRegistry(),
  })
  if (ref.current.sim !== sim) {
    ref.current = { sim, registry: createRegistry() }
  }
  return assignKinds(ref.current.registry, heads, referenceHead)
}
