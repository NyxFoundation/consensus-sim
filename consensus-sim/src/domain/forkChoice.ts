// Fork choice (GHOST 系) — pure functions over a block tree and votes.
// LMD: only each validator's latest vote counts. GHOST: descend from a root
// checkpoint, always into the heaviest child subtree.

import { childrenOf, isAncestor, type BlockTree } from "./blockTree";
import type { BlockIndex, ValidatorIndex, Vote } from "./types";

/**
 * The latest vote of each validator (LMD). For votes at the same slot by the
 * same validator (equivocation, introduced by interventions later), the
 * winner is chosen by smallest (head, source, target) lexicographically, so
 * the result never depends on message arrival order (determinism).
 */
export function latestVotes(
  votes: readonly Vote[],
): Map<ValidatorIndex, Vote> {
  const latest = new Map<ValidatorIndex, Vote>();
  for (const vote of votes) {
    const current = latest.get(vote.validator);
    if (!current || vote.slot > current.slot) {
      latest.set(vote.validator, vote);
      continue;
    }
    if (vote.slot === current.slot) {
      const a = [vote.head, vote.source, vote.target];
      const b = [current.head, current.source, current.target];
      const aWins =
        a[0]! < b[0]! ||
        (a[0] === b[0] && (a[1]! < b[1]! || (a[1] === b[1] && a[2]! < b[2]!)));
      if (aWins) latest.set(vote.validator, vote);
    }
  }
  return latest;
}

/**
 * GHOST subtree weight of `block`: how many latest votes support a head
 * inside the subtree rooted at `block`. Votes whose head is unknown to this
 * tree are ignored (that validator has not shown us its head yet).
 */
export function subtreeWeight(
  tree: BlockTree,
  latest: ReadonlyMap<ValidatorIndex, Vote>,
  block: BlockIndex,
): number {
  let weight = 0;
  for (const vote of latest.values()) {
    if (tree.blocks.has(vote.head) && isAncestor(tree, block, vote.head)) {
      weight += 1;
    }
  }
  return weight;
}

/**
 * The head block by GHOST from `root` (normally the justified checkpoint):
 * descend into the child with the greatest subtree weight; ties break to the
 * smallest block index, so the result is deterministic.
 */
export function ghostHead(
  tree: BlockTree,
  votes: readonly Vote[],
  root: BlockIndex,
): BlockIndex {
  if (!tree.blocks.has(root)) {
    throw new Error(`fork choice root ${root} is not in the tree`);
  }
  const latest = latestVotes(votes);
  let head = root;
  for (;;) {
    const children = childrenOf(tree, head);
    if (children.length === 0) return head;
    let best: BlockIndex | undefined;
    let bestWeight = -1;
    for (const child of children) {
      const weight = subtreeWeight(tree, latest, child);
      if (weight > bestWeight) {
        best = child;
        bestWeight = weight;
      }
    }
    head = best!;
  }
}
