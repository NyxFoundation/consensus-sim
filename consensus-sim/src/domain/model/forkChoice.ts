// Fork choice (GHOST 系) — pure functions over a block tree and votes.
// The rule decides which votes count: LMD-GHOST only each validator's
// latest, GHOST every vote. GHOST descends from a root checkpoint, always
// into the heaviest child subtree. Weights are stakes (from the chain state
// the caller picks per vote) plus, for one slot's proposal, the proposer
// boost; the caller may also restrict which blocks are candidates
// (justified-checkpoint switching by unrealized justification).

import { childrenOf, isAncestor, type BlockTree } from "./blockTree";
import { compareVoteContent } from "./order";
import type { ForkChoiceRule } from "./protocolParams";
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

/** What one fork-choice run takes besides the tree, the votes and the root. */
export interface ForkChoiceOptions {
  readonly weights?: ForkChoiceWeights;
  /** GHOST counts every vote; LMD-GHOST (default) only each validator's latest. */
  readonly rule?: ForkChoiceRule;
  /**
   * When given, only these blocks may be descended into: a child outside the
   * set is skipped with its whole subtree (緩和策: unrealized justification
   * excludes branches that can only realize an older justified checkpoint).
   */
  readonly candidates?: ReadonlySet<BlockIndex> | undefined;
}

/**
 * The latest vote of each validator (LMD). For votes at the same slot by the
 * same validator (equivocation), the winner is the first in the content
 * order of the skeleton (order.ts), so the result never depends on message
 * arrival order (determinism).
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
    if (vote.slot === current.slot && compareVoteContent(vote, current) < 0) {
      latest.set(vote.validator, vote);
    }
  }
  return latest;
}

/**
 * The votes a fork-choice rule counts (必須 27): under LMD-GHOST each
 * validator's latest vote only, under GHOST every vote — so a validator's
 * earlier votes, and both votes of an equivocation, keep their weight.
 */
export function countedVotes(
  votes: readonly Vote[],
  rule: ForkChoiceRule = "LMD-GHOST",
): readonly Vote[] {
  return rule === "GHOST" ? votes : [...latestVotes(votes).values()];
}

/**
 * GHOST subtree weight of `block`: the stake of the counted votes supporting
 * a head inside the subtree rooted at `block`, plus the proposer boost when
 * the boosted block lies in that subtree. Votes whose head is unknown to
 * this tree are ignored (that validator has not shown us its head yet).
 */
export function subtreeWeight(
  tree: BlockTree,
  counted: readonly Vote[],
  block: BlockIndex,
  weights: ForkChoiceWeights = UNIT_WEIGHTS,
): Stake {
  let weight = 0;
  for (const vote of counted) {
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
 * The head block by GHOST from `root` (normally the justified checkpoint's
 * block): descend into the candidate child with the greatest subtree
 * weight; ties break to the preferred child in the block order (order.ts —
 * children come in that order), so the result is deterministic. When no
 * child is a candidate the descent stops there.
 */
export function ghostHead(
  tree: BlockTree,
  votes: readonly Vote[],
  root: BlockIndex,
  options: ForkChoiceOptions = {},
): BlockIndex {
  if (!tree.blocks.has(root)) {
    throw new Error(`fork choice root ${root} is not in the tree`);
  }
  const weights = options.weights ?? UNIT_WEIGHTS;
  const counted = countedVotes(votes, options.rule);
  let head = root;
  for (;;) {
    const children = childrenOf(tree, head).filter(
      (child) => options.candidates?.has(child) ?? true,
    );
    if (children.length === 0) return head;
    let best: BlockIndex | undefined;
    let bestWeight = -1;
    for (const child of children) {
      const weight = subtreeWeight(tree, counted, child, weights);
      if (weight > bestWeight) {
        best = child;
        bestWeight = weight;
      }
    }
    head = best!;
  }
}
