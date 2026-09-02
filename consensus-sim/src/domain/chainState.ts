// Chain state (チェーン状態) — the per-branch state derived deterministically
// from what the branch's blocks have included (取り込み) plus the initial
// stakes. Reference type from ESSENCE.md:
//   ChainState(block) = {stakes, justified, finalized}
//
// The branch is replayed block by block from the anchor. Each block first
// applies the penalties (罰則) its evidence triggers, then adds its included
// votes, then re-evaluates finality with the stakes as they stand:
//
// - Finality is FFG-lite over included votes: a source→target link is
//   supermajority when the current stake of the distinct validators voting
//   it reaches 2/3 of the branch's current total; justification is the
//   monotone fixpoint from the anchor; a justified source whose direct
//   successor-epoch checkpoint gets justified is finalized. Only checkpoints
//   on the branch count — a vote included here whose checkpoints lie
//   elsewhere is inert for this branch.
// - Slashing (スラッシング, on/off): from the block that includes evidence of
//   an equivocation onward, the equivocator's stake on this branch is 0, so
//   it drops out of every weight and threshold from then on.
// - Inactivity leak (on/off, N, r): once an epoch ends on the branch, if
//   finalized lags that epoch by more than N epochs (Ethereum's finality
//   delay), every validator without a target vote of that epoch included on
//   the branch loses the fraction r of its stake. An epoch is processed at
//   the first block of a later epoch, after that block's inclusions, so the
//   votes of the epoch's last slot (included one block later) count.
// Ethereum's quadratic penalties and rewards are deliberately absent.

import { getBlock, isAncestor, pathToAnchor, type BlockTree } from "./blockTree";
import type { SimulationConfig } from "./config";
import { epochOf } from "./finality";
import {
  ANCHOR_BLOCK_INDEX,
  type Block,
  type BlockIndex,
  type Stake,
  type ValidatorIndex,
} from "./types";

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

interface Link {
  readonly source: BlockIndex;
  readonly target: BlockIndex;
  readonly voters: Set<ValidatorIndex>;
}

/** Replay the branch anchor → … → `tip` and derive its state at the tip. */
function deriveBranch(
  tree: BlockTree,
  branch: readonly Block[],
  config: SimulationConfig,
): BranchState {
  const { slashing, inactivityLeak } = config.params;
  const tip = branch[branch.length - 1]!.index;
  const onBranch = (checkpoint: BlockIndex): boolean =>
    tree.blocks.has(checkpoint) && isAncestor(tree, checkpoint, tip);

  const stakes = new Map<ValidatorIndex, Stake>(
    config.initialStakes.map((s, v) => [v, s]),
  );
  // Distinct voters per source→target link, over the whole branch, so a link
  // spread across several blocks still completes. Only links between
  // checkpoints of this branch are kept.
  const links = new Map<string, Link>();
  // Validators with a target vote of each epoch included on this branch.
  const participation = new Map<number, Set<ValidatorIndex>>();
  const justifiedCheckpoints = new Set<BlockIndex>([ANCHOR_BLOCK_INDEX]);
  let finalized: BlockIndex = ANCHOR_BLOCK_INDEX;
  let processedEpoch = epochOf(branch[0]!.slot) - 1;

  const evaluateFinality = (): void => {
    const total = totalStake(stakes);
    const supermajority = [...links.values()].filter((link) => {
      let weight = 0;
      for (const v of link.voters) weight += stakes.get(v) ?? 0;
      return isSupermajority(weight, total);
    });
    let grew = true;
    while (grew) {
      grew = false;
      for (const { source, target } of supermajority) {
        if (justifiedCheckpoints.has(source) && !justifiedCheckpoints.has(target)) {
          justifiedCheckpoints.add(target);
          grew = true;
        }
      }
    }
    for (const { source, target } of supermajority) {
      if (!justifiedCheckpoints.has(target)) continue;
      const sourceEpoch = epochOf(getBlock(tree, source)!.slot);
      const targetEpoch = epochOf(getBlock(tree, target)!.slot);
      if (targetEpoch === sourceEpoch + 1) {
        finalized = higherCheckpoint(tree, finalized, source);
      }
    }
  };

  const leakEpoch = (epoch: number): void => {
    const finalizedEpoch = epochOf(getBlock(tree, finalized)!.slot);
    if (epoch - finalizedEpoch <= inactivityLeak.delayEpochs) return;
    const active = participation.get(epoch);
    for (const [v, stake] of stakes) {
      if (!active?.has(v)) stakes.set(v, stake * (1 - inactivityLeak.rate));
    }
  };

  for (const block of branch) {
    if (slashing) {
      for (const evidence of block.body.evidence) stakes.set(evidence.validator, 0);
    }
    for (const vote of block.body.votes) {
      if (
        vote.source === vote.target ||
        !onBranch(vote.source) ||
        !onBranch(vote.target) ||
        !isAncestor(tree, vote.source, vote.target)
      ) {
        continue;
      }
      const key = `${vote.source}->${vote.target}`;
      let link = links.get(key);
      if (!link) {
        link = { source: vote.source, target: vote.target, voters: new Set() };
        links.set(key, link);
      }
      link.voters.add(vote.validator);
      const epoch = epochOf(vote.slot);
      let active = participation.get(epoch);
      if (!active) {
        active = new Set();
        participation.set(epoch, active);
      }
      active.add(vote.validator);
    }
    evaluateFinality();
    if (inactivityLeak.enabled) {
      const ended = epochOf(block.slot) - 1;
      for (let epoch = processedEpoch + 1; epoch <= ended; epoch++) leakEpoch(epoch);
      processedEpoch = Math.max(processedEpoch, ended);
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
  config: SimulationConfig,
): Map<BlockIndex, BranchState> {
  const out = new Map<BlockIndex, BranchState>();
  for (const block of tree.blocks.values()) {
    const branch = pathToAnchor(tree, block.index).reverse();
    out.set(block.index, deriveBranch(tree, branch, config));
  }
  return out;
}

/** ChainState(block) for every block of the tree. */
export function chainStatesOf(
  tree: BlockTree,
  config: SimulationConfig,
): ChainStateIndex {
  const out = new Map<BlockIndex, ChainState>();
  for (const [index, { chain }] of deriveAll(tree, config)) {
    out.set(index, chain);
  }
  return out;
}

/** The chain state of one block (its branch's derivation). */
export function chainStateOf(
  tree: BlockTree,
  block: BlockIndex,
  config: SimulationConfig,
): ChainState {
  const branch = pathToAnchor(tree, block).reverse();
  if (branch.length === 0) throw new Error(`block ${block} is not in the tree`);
  return deriveBranch(tree, branch, config).chain;
}

/**
 * Which checkpoints are justified or finalized on some branch of the tree.
 * A finalized checkpoint is also every justified checkpoint at or below a
 * finalized one — finality never regresses along a branch.
 */
export function checkpointStatus(
  tree: BlockTree,
  config: SimulationConfig,
): CheckpointStatus {
  const justified = new Set<BlockIndex>();
  const finalizedFrontier = new Set<BlockIndex>();
  for (const { chain, justifiedCheckpoints } of deriveAll(tree, config).values()) {
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
