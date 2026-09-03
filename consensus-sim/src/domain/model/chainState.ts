// Chain state (チェーン状態) — the per-branch state derived deterministically
// from what the branch's blocks have included (取り込み) plus the initial
// stakes. Reference type from ESSENCE.md:
//   ChainState(block) = {stakes, justified, finalized}
//
// The branch is replayed block by block from the anchor. Each block first
// applies the penalties (罰則) its evidence triggers, then adds its included
// votes, then re-evaluates finality with the stakes as they stand:
//
// - Finality is FFG over included votes. A vote counts as a link of this
//   branch only when its source and target are the branch's own checkpoints
//   of their epochs (取り込み妥当性; the same block standing for consecutive
//   epochs is a valid link too). A link is supermajority when the current
//   stake of the distinct validators voting it reaches 2/3 of the branch's
//   current total; justification is the monotone fixpoint from the anchor;
//   a justified source whose target of the very next epoch (by epoch
//   number) gets justified is finalized.
// - Slashing (スラッシング, on/off): from the block that includes evidence of
//   an equivocation (any of its three forms) onward, the equivocator's stake
//   on this branch is 0, so it drops out of every weight and threshold from
//   then on.
// - Inactivity leak ({N, r} | off): once an epoch ends on the branch, if
//   finalized lags that epoch by more than N epochs (Ethereum's finality
//   delay), every validator without a target vote of that epoch included on
//   the branch loses the fraction r of its stake. An epoch is processed at
//   the first block of a later epoch, after that block's inclusions, so the
//   votes of the epoch's last slot (included one block later) count.
// Ethereum's quadratic penalties and rewards are deliberately absent.

import {
  childrenOf,
  getBlock,
  isAncestor,
  leavesUnder,
  pathToAnchor,
  type BlockTree,
} from "./blockTree";
import type { InitialConditions } from "./initialConditions";
import {
  JUSTIFIED_SWITCH_WINDOW_SLOTS,
  checkpointFor,
  epochBoundarySlot,
  epochOf,
  inJustifiedSwitchWindow,
} from "./finality";
import { equivocatorOf } from "./inclusion";
import { checkpointKey, higherCheckpoint } from "./order";
import type { CheckpointSwitch } from "./protocolParams";
import {
  ANCHOR_CHECKPOINT,
  bodyOf,
  type Block,
  type BlockIndex,
  type Checkpoint,
  type EpochIndex,
  type SlotIndex,
  type Stake,
  type ValidatorIndex,
} from "./types";

export interface ChainState {
  readonly stakes: ReadonlyMap<ValidatorIndex, Stake>;
  /** The highest justified checkpoint on this branch. */
  readonly justified: Checkpoint;
  /** The highest finalized checkpoint on this branch. */
  readonly finalized: Checkpoint;
}

/** Chain state of every block of a tree, keyed by block index. */
export type ChainStateIndex = ReadonlyMap<BlockIndex, ChainState>;

/** Blocks standing as a justified / finalized checkpoint on some branch of
 * a tree (what the J / F badges mark). */
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

interface BranchState {
  readonly chain: ChainState;
  readonly justifiedCheckpoints: ReadonlyMap<string, Checkpoint>;
}

interface Link {
  readonly source: Checkpoint;
  readonly target: Checkpoint;
  readonly voters: Set<ValidatorIndex>;
}

/** Replay the branch anchor → … → `tip` and derive its state at the tip. */
function deriveBranch(
  tree: BlockTree,
  branch: readonly Block[],
  config: InitialConditions,
): BranchState {
  const { slashing, inactivityLeak } = config.params;
  const tip = branch[branch.length - 1]!.index;
  // The branch's own checkpoint of each epoch, memoized per epoch.
  const checkpoints = new Map<EpochIndex, BlockIndex>();
  const isOwnCheckpoint = (c: Checkpoint): boolean => {
    let block = checkpoints.get(c.epoch);
    if (block === undefined) {
      block = checkpointFor(tree, tip, c.epoch).block;
      checkpoints.set(c.epoch, block);
    }
    return block === c.block;
  };

  const stakes = new Map<ValidatorIndex, Stake>(
    config.initialStakes.map((s, v) => [v, s]),
  );
  // Distinct voters per source→target link, over the whole branch, so a link
  // spread across several blocks still completes. Only links between
  // checkpoints of this branch are kept.
  const links = new Map<string, Link>();
  // Validators with a target vote of each epoch included on this branch.
  const participation = new Map<EpochIndex, Set<ValidatorIndex>>();
  const justifiedCheckpoints = new Map<string, Checkpoint>([
    [checkpointKey(ANCHOR_CHECKPOINT), ANCHOR_CHECKPOINT],
  ]);
  let finalized: Checkpoint = ANCHOR_CHECKPOINT;
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
        const targetKey = checkpointKey(target);
        if (justifiedCheckpoints.has(checkpointKey(source)) && !justifiedCheckpoints.has(targetKey)) {
          justifiedCheckpoints.set(targetKey, target);
          grew = true;
        }
      }
    }
    for (const { source, target } of supermajority) {
      if (!justifiedCheckpoints.has(checkpointKey(target))) continue;
      if (target.epoch === source.epoch + 1) {
        finalized = higherCheckpoint(finalized, source);
      }
    }
  };

  const leakEpoch = (epoch: EpochIndex): void => {
    if (inactivityLeak === "off" || epoch - finalized.epoch <= inactivityLeak.delayEpochs) return;
    const active = participation.get(epoch);
    for (const [v, stake] of stakes) {
      if (!active?.has(v)) stakes.set(v, stake * (1 - inactivityLeak.rate));
    }
  };

  for (const block of branch) {
    const body = bodyOf(block);
    if (slashing) {
      for (const evidence of body.evidence) stakes.set(equivocatorOf(evidence), 0);
    }
    for (const vote of body.votes) {
      if (
        vote.source.epoch >= vote.target.epoch ||
        !isOwnCheckpoint(vote.source) ||
        !isOwnCheckpoint(vote.target)
      ) {
        continue;
      }
      const key = `${checkpointKey(vote.source)}->${checkpointKey(vote.target)}`;
      let link = links.get(key);
      if (!link) {
        link = { source: vote.source, target: vote.target, voters: new Set() };
        links.set(key, link);
      }
      link.voters.add(vote.validator);
      const epoch = vote.target.epoch;
      let active = participation.get(epoch);
      if (!active) {
        active = new Set();
        participation.set(epoch, active);
      }
      active.add(vote.validator);
    }
    evaluateFinality();
    if (inactivityLeak !== "off") {
      const ended = epochOf(block.slot) - 1;
      for (let epoch = processedEpoch + 1; epoch <= ended; epoch++) leakEpoch(epoch);
      processedEpoch = Math.max(processedEpoch, ended);
    }
  }

  let justified: Checkpoint = ANCHOR_CHECKPOINT;
  for (const checkpoint of justifiedCheckpoints.values()) {
    justified = higherCheckpoint(justified, checkpoint);
  }
  return { chain: { stakes, justified, finalized }, justifiedCheckpoints };
}

function deriveAll(
  tree: BlockTree,
  config: InitialConditions,
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
  config: InitialConditions,
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
  config: InitialConditions,
): ChainState {
  const branch = pathToAnchor(tree, block).reverse();
  if (branch.length === 0) throw new Error(`block ${block} is not in the tree`);
  return deriveBranch(tree, branch, config).chain;
}

/**
 * Which blocks stand as a justified or finalized checkpoint on some branch
 * of the tree. A finalized block is also every justified checkpoint's block
 * at or below a finalized one — finality never regresses along a branch.
 */
export function checkpointStatus(
  tree: BlockTree,
  config: InitialConditions,
): CheckpointStatus {
  const justified = new Set<BlockIndex>();
  const finalizedFrontier = new Set<BlockIndex>();
  for (const { chain, justifiedCheckpoints } of deriveAll(tree, config).values()) {
    for (const c of justifiedCheckpoints.values()) justified.add(c.block);
    finalizedFrontier.add(chain.finalized.block);
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

/** The latest finalized checkpoint of the god view (最新の finalized):
 * the highest finalized checkpoint among the chain states of every block. */
export function latestFinalized(states: ChainStateIndex): Checkpoint {
  let latest: Checkpoint = ANCHOR_CHECKPOINT;
  for (const state of states.values()) {
    latest = higherCheckpoint(latest, state.finalized);
  }
  return latest;
}

/**
 * Fork count (フォーク数, 必須 10) of the god-view tree: the number of
 * leaves of the subtree rooted at the latest finalized block — 1 when that
 * block is itself a leaf. Finality advancing past a fork removes it from
 * the count; the tree itself only ever grows.
 */
export function forkCount(tree: BlockTree, states: ChainStateIndex): number {
  return forkCountAfter(tree, states, []);
}

/**
 * The fork count once proposals are built on `parents` (the parents of
 * pending fork designations, 未実行のフォーク作成指定, plus the one under
 * consideration). A proposal adds a fork only when its parent already has a
 * child — in the tree or from an earlier entry of `parents`; building on a
 * leaf merely extends it. Parents outside the finalized subtree, or not in
 * the tree yet, are outside the definition and add nothing.
 */
export function forkCountAfter(
  tree: BlockTree,
  states: ChainStateIndex,
  parents: readonly BlockIndex[],
): number {
  const root = latestFinalized(states).block;
  const leaves = new Set(leavesUnder(tree, root));
  const extended = new Set<BlockIndex>();
  let count = leaves.size;
  for (const parent of parents) {
    if (!getBlock(tree, parent) || !isAncestor(tree, root, parent)) continue;
    if (leaves.has(parent) && !extended.has(parent)) extended.add(parent);
    else count += 1;
  }
  return count;
}

/** The highest justified checkpoint among the given chain states. */
function highestJustified(states: Iterable<ChainState>): Checkpoint {
  let root: Checkpoint = ANCHOR_CHECKPOINT;
  for (const state of states) {
    root = higherCheckpoint(root, state.justified);
  }
  return root;
}

/** Both switches off: the root is always the highest justified checkpoint
 * known and every block is a candidate. */
export const NO_SWITCHING: CheckpointSwitch = { window: false, unrealized: false };

/**
 * The justified checkpoint a validator starts fork choice from, under the
 * window switch of justified-checkpoint switching (justified チェック
 * ポイント切替, 必須 27) as a fork choice computed at `atSlot`:
 *
 * - window off: the highest justified checkpoint among the chain states of
 *   every block it knows (the unrealized switch does not move the root; it
 *   filters the candidates instead, see `viableBlocks`).
 * - window on: the same inside the head section of the epoch; outside it the
 *   root switches only along its own chain. A block's slot stands for its
 *   arrival, so "the root as of the window" is the highest justified among
 *   blocks proposed before the window closed, and a newer justified
 *   checkpoint is adopted only when it descends from that root (Ethereum's
 *   should_update_justified_checkpoint, simplified to a pure function of the
 *   view: a conflicting justification realized mid-epoch waits for the next
 *   epoch's window).
 */
export function forkChoiceRoot(
  tree: BlockTree,
  states: ChainStateIndex,
  switching: CheckpointSwitch = NO_SWITCHING,
  atSlot: SlotIndex = 0,
): Checkpoint {
  const free = highestJustified(states.values());
  if (!switching.window || inJustifiedSwitchWindow(atSlot)) return free;
  const windowEnd =
    epochBoundarySlot(epochOf(atSlot)) + JUSTIFIED_SWITCH_WINDOW_SLOTS;
  const settled = highestJustified(
    [...states].filter(([b]) => getBlock(tree, b)!.slot < windowEnd).map(([, s]) => s),
  );
  return highestJustified(
    [...states.values()].filter((s) => isAncestor(tree, settled.block, s.justified.block)),
  );
}

/**
 * The blocks fork choice may descend into under the unrealized switch: the
 * leaves whose chain state realizes a justified checkpoint of an epoch as
 * recent as `root`'s, together with their ancestors. A branch whose
 * included votes can only justify something older is excluded even when it
 * carries more votes. In this model every block's chain state already
 * counts its included votes without waiting for the epoch's end, so a
 * branch's unrealized justified checkpoint is its tip's
 * `ChainState.justified`.
 */
export function viableBlocks(
  tree: BlockTree,
  states: ChainStateIndex,
  root: Checkpoint,
): ReadonlySet<BlockIndex> {
  const viable = new Set<BlockIndex>();
  for (const block of tree.blocks.values()) {
    if (childrenOf(tree, block.index).length > 0) continue;
    if (states.get(block.index)!.justified.epoch < root.epoch) continue;
    for (const ancestor of pathToAnchor(tree, block.index)) viable.add(ancestor.index);
  }
  return viable;
}
