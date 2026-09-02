// Fork choice (GHOST 系) — pure functions over a block tree and votes.
// LMD: only each validator's latest vote counts. GHOST: descend from a root
// checkpoint, always into the heaviest child subtree. Weights are stakes
// (from the chain state the caller picks per vote) plus, for one slot's
// proposal, the proposer boost.

import { childrenOf, isAncestor, type BlockTree } from "./blockTree";
import type { BlockIndex, Stake, ValidatorIndex, Vote } from "./types";

/**
 * How votes and the proposer boost weigh in one fork-choice computation.
 * `weightOf` is the stake a vote carries — the caller decides which chain
 * state it reads it from; `boost` adds `weight` to the subtree of `block`
 * (the current slot's timely proposal, ESSENCE 必須 3) for this computation
 * only.
 */
export interface ForkChoiceWeights {
  readonly weightOf: (vote: Vote) => Stake;
  readonly boost?:
    | { readonly block: BlockIndex; readonly weight: Stake }
    | undefined;
}

/** Every vote weighs 1 and nothing is boosted — the bare GHOST count. */
export const UNIT_WEIGHTS: ForkChoiceWeights = { weightOf: () => 1 };

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
 * GHOST subtree weight of `block`: the stake of the latest votes supporting
 * a head inside the subtree rooted at `block`, plus the proposer boost when
 * the boosted block lies in that subtree. Votes whose head is unknown to
 * this tree are ignored (that validator has not shown us its head yet).
 */
export function subtreeWeight(
  tree: BlockTree,
  latest: ReadonlyMap<ValidatorIndex, Vote>,
  block: BlockIndex,
  weights: ForkChoiceWeights = UNIT_WEIGHTS,
): Stake {
  let weight = 0;
  for (const vote of latest.values()) {
    if (tree.blocks.has(vote.head) && isAncestor(tree, block, vote.head)) {
      weight += weights.weightOf(vote);
    }
  }
  const boost = weights.boost;
  if (
    boost !== undefined &&
    tree.blocks.has(boost.block) &&
    isAncestor(tree, block, boost.block)
  ) {
    weight += boost.weight;
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
  weights: ForkChoiceWeights = UNIT_WEIGHTS,
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
      const weight = subtreeWeight(tree, latest, child, weights);
      if (weight > bestWeight) {
        best = child;
        bestWeight = weight;
      }
    }
    head = best!;
  }
}
