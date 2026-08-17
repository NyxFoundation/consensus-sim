/**
 * Whether the network is actually forked, as opposed to merely spread out.
 *
 * Counting distinct head hashes does not answer this, and the earlier version
 * that did was wrong in a way that made the display useless. When a block is
 * proposed the observed node adopts it at once while everyone else is still
 * waiting for it to arrive; those nodes hold the *previous* head. Their head
 * differs, but they are on the same chain, one block behind. That is
 * propagation, already shown by the propagation curve, and it is not a fork.
 *
 * A fork is heads that sit on branches neither of which contains the other. So
 * the test is ancestry, not equality: a head on the observed node's chain —
 * ahead of it or behind it — belongs to the same camp.
 */

import type { Hash } from '../core/hash'
import type { Block } from '../protocol/gasper/types'

export interface Camp {
  /** Deepest head seen on this branch; represents the camp. */
  readonly head: Hash
  readonly count: number
}

export interface Divergence {
  /** Nodes on the observed node's chain, whether behind it, level, or ahead. */
  readonly onChain: number
  /** Branches that conflict with it, largest first. Empty when not forked. */
  readonly camps: readonly Camp[]
}

/** Whether `ancestor` lies on the path from `descendant` back to the root. */
export function isAncestorOrSelf(
  blocks: ReadonlyMap<Hash, Block>,
  ancestor: Hash,
  descendant: Hash,
): boolean {
  const target = blocks.get(ancestor)
  const seen = new Set<Hash>()
  let current = descendant

  while (!seen.has(current)) {
    if (current === ancestor) return true
    seen.add(current)

    const block = blocks.get(current)
    if (block === undefined) return false
    // Walking past the candidate's own slot means it was never on this path.
    if (target !== undefined && block.slot <= target.slot) return false
    current = block.parent
  }
  return false
}

function sameChain(
  blocks: ReadonlyMap<Hash, Block>,
  head: Hash,
  reference: Hash,
): boolean {
  return (
    head === reference ||
    isAncestorOrSelf(blocks, head, reference) ||
    isAncestorOrSelf(blocks, reference, head)
  )
}

export function computeDivergence(
  blocks: ReadonlyMap<Hash, Block>,
  heads: readonly Hash[],
  observerHead: Hash,
): Divergence {
  const counts = new Map<Hash, number>()
  for (const head of heads) counts.set(head, (counts.get(head) ?? 0) + 1)

  let onChain = 0
  const conflicting: Camp[] = []
  for (const [head, count] of counts) {
    if (sameChain(blocks, head, observerHead)) onChain += count
    else conflicting.push({ head, count })
  }

  // Deepest tip first, so a lagging node on a conflicting branch folds into the
  // camp led by that branch's tip rather than starting a camp of its own.
  const byDepth = [...conflicting].sort(
    (a, b) => (blocks.get(b.head)?.slot ?? 0) - (blocks.get(a.head)?.slot ?? 0),
  )

  const camps: { head: Hash; count: number }[] = []
  for (const entry of byDepth) {
    const existing = camps.find((camp) => isAncestorOrSelf(blocks, entry.head, camp.head))
    if (existing === undefined) camps.push({ head: entry.head, count: entry.count })
    else existing.count += entry.count
  }

  return { onChain, camps: camps.sort((a, b) => b.count - a.count) }
}
