/**
 * LMD-GHOST, filtered by the justified checkpoint.
 *
 * The descent starts at the node's justified root rather than at genesis. That
 * filter is the coupling between Gasper's two halves: FFG decides where the
 * fork choice is even allowed to look, and LMD-GHOST picks the heaviest path
 * from there. Reproducing it matters, because a layered protocol replaces this
 * one hard-wired filter with an explicit composition of layers.
 */

import type { Hash } from '../../core/hash'
import type { Gwei } from '../../core/types'
import type { GasperStore } from './store'

export interface ForkChoiceResult {
  readonly head: Hash
  readonly weights: ReadonlyMap<Hash, Gwei>
}

/** Ties break toward the lexicographically larger root, as the spec does. */
function bestChild(children: readonly Hash[], weights: ReadonlyMap<Hash, Gwei>): Hash {
  let best = children[0] as Hash
  let bestWeight = weights.get(best) ?? 0

  for (let i = 1; i < children.length; i++) {
    const candidate = children[i] as Hash
    const weight = weights.get(candidate) ?? 0
    if (weight > bestWeight || (weight === bestWeight && candidate > best)) {
      best = candidate
      bestWeight = weight
    }
  }

  return best
}

export function computeForkChoice(store: GasperStore): ForkChoiceResult {
  const weights = store.computeWeights()
  const visited = new Set<Hash>()
  let current = store.justified.root

  for (;;) {
    // A malformed parent link could otherwise spin here forever.
    if (visited.has(current)) return { head: current, weights }
    visited.add(current)

    const children = store.childrenOf(current)
    if (children.length === 0) return { head: current, weights }
    current = bestChild(children, weights)
  }
}

/**
 * Memoises the fork choice against the store's revision counter.
 *
 * A node calls the fork choice at most twice per slot but receives O(N)
 * messages in between; without this the head computation would dominate.
 */
export class ForkChoice {
  private cached: ForkChoiceResult | null = null
  private cachedVersion = -1

  constructor(private readonly store: GasperStore) {}

  get(): ForkChoiceResult {
    if (this.cached !== null && this.cachedVersion === this.store.version) {
      return this.cached
    }
    const result = computeForkChoice(this.store)
    this.cached = result
    this.cachedVersion = this.store.version
    return result
  }

  head(): Hash {
    return this.get().head
  }
}
