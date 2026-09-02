// Chain state (チェーン状態) — the per-branch state derived deterministically
// from what the branch's blocks have included (取り込み) plus the initial
// stakes. Reference type from ESSENCE.md:
//   ChainState(block) = {stakes, justified, finalized}
//
// Finality is FFG-lite over included votes only: a source→target link is
// supermajority when the stake of the distinct validators voting it reaches
// 2/3 of the branch's total stake; justification is the fixpoint from the
// anchor; a justified source whose direct successor-epoch checkpoint gets
// justified is finalized. Only checkpoints on the branch count — a vote
// included here whose checkpoints lie elsewhere is inert for this branch.
// Penalties (罰則) alter stakes along the branch; until they are modelled,
// stakes stay at their initial values.

import { getBlock, isAncestor, pathToAnchor, type BlockTree } from "./blockTree";
import { epochOf } from "./finality";
import {
  ANCHOR_BLOCK_INDEX,
  type Block,
  type BlockIndex,
  type Stake,
  type ValidatorIndex,
} from "./types";
import { validatorIndices } from "./validatorSet";

export interface ChainState {
  readonly stakes: ReadonlyMap<ValidatorIndex, Stake>;
  /** The highest justified checkpoint on this branch. */
  readonly justified: BlockIndex;
  /** The highest finalized checkpoint on this branch. */
  readonly finalized: BlockIndex;
}

/** Chain state of every block of a tree, keyed by block index. */
export type ChainStateIndex = ReadonlyMap<BlockIndex, ChainState>;

/** Checkpoints justified / finalized on some branch of a tree. */
export interface CheckpointStatus {
  readonly justified: ReadonlySet<BlockIndex>;
  readonly finalized: ReadonlySet<BlockIndex>;
}

/** Initial stake per validator; the default is equal stake for everyone. */
export const DEFAULT_STAKE: Stake = 32;

export function equalStakes(validatorCount: number): ReadonlyMap<ValidatorIndex, Stake> {
  return new Map(validatorIndices(validatorCount).map((v) => [v, DEFAULT_STAKE]));
}

export function totalStake(stakes: ReadonlyMap<ValidatorIndex, Stake>): Stake {
  let total = 0;
  for (const s of stakes.values()) total += s;
  return total;
}

/** Whether `weight` reaches the 2/3 supermajority of `total`. */
export function isSupermajority(weight: Stake, total: Stake): boolean {
  return total > 0 && weight * 3 >= total * 2;
}

/** The higher of two checkpoints: later slot, then smaller index. */
export function higherCheckpoint(
  tree: BlockTree,
  a: BlockIndex,
  b: BlockIndex,
): BlockIndex {
  const blockA = getBlock(tree, a);
  const blockB = getBlock(tree, b);
  if (!blockA) return b;
  if (!blockB) return a;
  if (blockA.slot !== blockB.slot) return blockA.slot > blockB.slot ? a : b;
  return Math.min(a, b);
}

interface BranchState {
  readonly chain: ChainState;
  readonly justifiedCheckpoints: ReadonlySet<BlockIndex>;
}

/**
 * Derive the state at the end of the branch anchor → … → `tip` from the
 * bodies along it. Distinct voters per link are accumulated over the whole
 * branch, so a link spread across several blocks still completes.
 */
function deriveBranch(
  tree: BlockTree,
  branch: readonly Block[],
  initialStakes: ReadonlyMap<ValidatorIndex, Stake>,
): BranchState {
  const tip = branch[branch.length - 1]!.index;
  const stakes = initialStakes;
  const total = totalStake(stakes);
  const onBranch = (checkpoint: BlockIndex): boolean =>
    tree.blocks.has(checkpoint) && isAncestor(tree, checkpoint, tip);

  const linkWeight = new Map<string, Stake>();
  const linkVoters = new Map<string, Set<ValidatorIndex>>();
  for (const block of branch) {
    for (const vote of block.body.votes) {
      const key = `${vote.source}->${vote.target}`;
      let voters = linkVoters.get(key);
      if (!voters) {
        voters = new Set();
        linkVoters.set(key, voters);
      }
      if (voters.has(vote.validator)) continue;
      voters.add(vote.validator);
      linkWeight.set(
        key,
        (linkWeight.get(key) ?? 0) + (stakes.get(vote.validator) ?? 0),
      );
    }
  }
  const links: Array<{ source: BlockIndex; target: BlockIndex }> = [];
  for (const [key, weight] of linkWeight) {
    if (!isSupermajority(weight, total)) continue;
    const [source, target] = key.split("->").map(Number) as [number, number];
    if (source === target || !onBranch(source) || !onBranch(target)) continue;
    if (!isAncestor(tree, source, target)) continue;
    links.push({ source, target });
  }

  const justifiedCheckpoints = new Set<BlockIndex>([ANCHOR_BLOCK_INDEX]);
  let grew = true;
  while (grew) {
    grew = false;
    for (const { source, target } of links) {
      if (justifiedCheckpoints.has(source) && !justifiedCheckpoints.has(target)) {
        justifiedCheckpoints.add(target);
        grew = true;
      }
    }
  }

  let finalized: BlockIndex = ANCHOR_BLOCK_INDEX;
  for (const { source, target } of links) {
    if (!justifiedCheckpoints.has(target)) continue;
    const sourceBlock = getBlock(tree, source)!;
    const targetBlock = getBlock(tree, target)!;
    if (epochOf(targetBlock.slot) === epochOf(sourceBlock.slot) + 1) {
      finalized = higherCheckpoint(tree, finalized, source);
    }
  }

  let justified: BlockIndex = ANCHOR_BLOCK_INDEX;
  for (const checkpoint of justifiedCheckpoints) {
    justified = higherCheckpoint(tree, justified, checkpoint);
  }

  return { chain: { stakes, justified, finalized }, justifiedCheckpoints };
}

function deriveAll(
  tree: BlockTree,
  initialStakes: ReadonlyMap<ValidatorIndex, Stake>,
): Map<BlockIndex, BranchState> {
  const out = new Map<BlockIndex, BranchState>();
  for (const block of tree.blocks.values()) {
    const branch = pathToAnchor(tree, block.index).reverse();
    out.set(block.index, deriveBranch(tree, branch, initialStakes));
  }
  return out;
}

/** ChainState(block) for every block of the tree. */
export function chainStatesOf(
  tree: BlockTree,
  initialStakes: ReadonlyMap<ValidatorIndex, Stake>,
): ChainStateIndex {
  const out = new Map<BlockIndex, ChainState>();
  for (const [index, { chain }] of deriveAll(tree, initialStakes)) {
    out.set(index, chain);
  }
  return out;
}

/** The chain state of one block (its branch's derivation). */
export function chainStateOf(
  tree: BlockTree,
  block: BlockIndex,
  initialStakes: ReadonlyMap<ValidatorIndex, Stake>,
): ChainState {
  const branch = pathToAnchor(tree, block).reverse();
  if (branch.length === 0) throw new Error(`block ${block} is not in the tree`);
  return deriveBranch(tree, branch, initialStakes).chain;
}

/**
 * Which checkpoints are justified or finalized on some branch of the tree.
 * A finalized checkpoint is also every justified checkpoint at or below a
 * finalized one — finality never regresses along a branch.
 */
export function checkpointStatus(
  tree: BlockTree,
  initialStakes: ReadonlyMap<ValidatorIndex, Stake>,
): CheckpointStatus {
  const justified = new Set<BlockIndex>();
  const finalizedFrontier = new Set<BlockIndex>();
  for (const { chain, justifiedCheckpoints } of deriveAll(tree, initialStakes).values()) {
    for (const c of justifiedCheckpoints) justified.add(c);
    finalizedFrontier.add(chain.finalized);
  }
  const finalized = new Set<BlockIndex>();
  for (const c of justified) {
    for (const f of finalizedFrontier) {
      if (isAncestor(tree, c, f)) {
        finalized.add(c);
        break;
      }
    }
  }
  return { justified, finalized };
}

/**
 * The justified checkpoint a validator starts fork choice from: the highest
 * justified checkpoint among the chain states of every block it knows. The
 * justified-checkpoint switching rule (緩和策) refines this later.
 */
export function forkChoiceRoot(
  tree: BlockTree,
  states: ChainStateIndex,
): BlockIndex {
  let root: BlockIndex = ANCHOR_BLOCK_INDEX;
  for (const state of states.values()) {
    root = higherCheckpoint(tree, root, state.justified);
  }
  return root;
}
