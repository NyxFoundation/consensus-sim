// チェーン状態 — 枝のブロックが取り込んだもの(取り
// 込み)と初期ステークから決定的に導かれる、枝ごとの状態。
// ESSENCE.md の参照型:
//   ChainState(block) = {stakes, justified, finalized}
//
// 枝は錨ブロックからブロックごとに再生される。各ブロックはまずその証
// 拠が引き起こす罰則を適用し、次に取り込んだ投票を加え、その時点のステー
// クで finality を再評価する:
//
// - finality は取り込まれた投票に対する FFG である。投票がこの枝の
//   リンクとして数えられるのは、その source と target が、それぞれの
//   epoch についてこの枝自身のチェックポイントであるときのみ(取り
//   込み妥当性; 同じブロックが連続する 2 つの epoch を代表する場合も有効
//   なリンクとなる)。リンクは、それに投票する相異なるバリデータの現在の
//   ステークが枝の現在の総量の 2/3 に達したとき supermajority とな
//   る。justification は錨ブロックからの単調な不動点であり、justified な
//   source のうち、その真次の epoch(epoch 番号による)の target が
//   justified になったものが finalized となる。
// - スラッシング(on / off): エクイボケーション(その 3 つの形式のいずれ
//   か)の証拠を取り込んだブロック以降、この枝上でエクイボケータの
//   ステークは 0 になり、以後すべての重みと閾値から外れる。
// - inactivity leak({N, r} | off): 枝上であるエポックが終わった時
//   点で、finalized がそのエポックより N エポック(Ethereum の finality
//   delay)以上遅れているなら、そのエポックの target 投票が枝に取
//   り込まれていないすべてのバリデータは、そのステークの割合 r を失う。
//   エポックは、より後のエポックの最初のブロックにおいて、そのブロック
//   の取り込み処理の後で処理される。そのため、そのエポックの最後のスロ
//   ットの投票(1 ブロック後に取り込まれる)も数えられる。
// Ethereum の quadratic penalties と rewards は意図的に含まれていない。

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

/** ChainState(block) = {stakes, justified, finalized}: ある枝のチェ
 * ーン状態。 */
export interface ChainState {
  readonly stakes: ReadonlyMap<ValidatorIndex, Stake>;
  /** この枝における最も高い justified チェックポイント。 */
  readonly justified: Checkpoint;
  /** この枝における最も高い finalized チェックポイント。 */
  readonly finalized: Checkpoint;
}

/** tree のすべてのブロックの チェーン状態 を、ブロックインデックスをキー
 * として持つもの。 */
export type ChainStateIndex = ReadonlyMap<BlockIndex, ChainState>;

/** tree のいずれかの枝において justified / finalized チェックポイ
 * ントとして立っているブロック(J / F バッジが示すもの)。 */
export interface CheckpointStatus {
  readonly justified: ReadonlySet<BlockIndex>;
  readonly finalized: ReadonlySet<BlockIndex>;
}

export function totalStake(stakes: ReadonlyMap<ValidatorIndex, Stake>): Stake {
  let total = 0;
  for (const s of stakes.values()) total += s;
  return total;
}

/** `weight` が `total` の 2/3 の超過半数に達しているかどうか。 */
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

/** 枝 錨ブロック → … → `tip` を再生し、tip における状態を導出する。 */
function deriveBranch(
  tree: BlockTree,
  branch: readonly Block[],
  config: InitialConditions,
): BranchState {
  const { slashing, inactivityLeak } = config.params;
  const tip = branch[branch.length - 1]!.index;
  // 各 epoch についてのこの枝自身のチェックポイント。epoch ごとに
  // メモ化する。
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
  // 枝全体にわたる source→target リンクごとの相異なる投票者。これ
  // により、複数のブロックにまたがるリンクでも完成する。この枝の
  // チェックポイント間のリンクのみを保持する。
  const links = new Map<string, Link>();
  // 各 epoch について、target 投票がこの枝に取り込まれているバリ
  // データ。
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

/** tree のすべてのブロックについての ChainState(block)。 */
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

/** 1 つのブロックの チェーン状態(その枝の導出結果)。 */
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
 * tree のいずれかの枝において justified または finalized チェック
 * ポイントとして立っているブロック。finalized なブロックは、あるブロッ
 * クが finalized な位置以下にあるすべての justified チェックポイントの
 * ブロックでもある — finality は枝に沿って決して後退しない。
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

/** 神視点 における最新の finalized チェックポイント: すべてのブロック
 * の チェーン状態 の中で最も高い finalized チェックポイント。 */
export function latestFinalized(states: ChainStateIndex): Checkpoint {
  let latest: Checkpoint = ANCHOR_CHECKPOINT;
  for (const state of states.values()) {
    latest = higherCheckpoint(latest, state.finalized);
  }
  return latest;
}

/**
 * 神視点の木 のフォーク数(必須 10): 最新の finalized ブロックを根と
 * する部分木の葉の数 — そのブロック自身が葉ならば 1。finality があるフ
 * ォークを越えて進むとそのフォークはカウントから外れる。tree 自体は増え
 * ていく一方である。
 */
export function forkCount(tree: BlockTree, states: ChainStateIndex): number {
  return forkCountAfter(tree, states, []);
}

/**
 * `parents`(未実行のフォーク作成指定の parent 群に、検討中の 1 つを加え
 * たもの)の上に提案が構築されたとした場合のフォーク数。提案がフォーク
 * を増やすのは、その parent がすでに子を持つ場合(tree の中で、または
 * `parents` のより前のエントリにより)のみ。葉の上に構築する場合は単に
 * それを延長するだけである。finalized 部分木の外にある parent や、まだ
 * tree に無い parent は定義の対象外であり、何も加えない。
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

/** 与えられた チェーン状態 の中で最も高い justified チェックポイント。 */
function highestJustified(states: Iterable<ChainState>): Checkpoint {
  let root: Checkpoint = ANCHOR_CHECKPOINT;
  for (const state of states) {
    root = higherCheckpoint(root, state.justified);
  }
  return root;
}

/** 両方のスイッチが off: root は常に既知の最も高い justified チェックポ
 * イントであり、すべてのブロックが候補となる。 */
export const NO_SWITCHING: CheckpointSwitch = { window: false, unrealized: false };

/**
 * `atSlot` で計算される fork choice として、justified チェックポイント切
 * 替(必須 27)の window スイッチの下で、バリデータが fork choice を開始
 * する justified チェックポイント:
 *
 * - window off: 既知のすべてのブロックの チェーン状態 の中で最も高い
 *   justified チェックポイント(unrealized スイッチは root を動かさな
 *   い。代わりに候補を絞り込む。`viableBlocks` を参照)。
 * - window on: epoch の head セクションの内側では同じ。外側では root は
 *   自身のチェーンに沿ってのみ切り替わる。ブロックのスロットはその到着
 *   を表すので、「window 時点の root」は window が閉じる前に提案された
 *   ブロックの中で最も高い justified チェックポイントであり、より新しい
 *   justified チェックポイントは、その root の子孫であるときにのみ採用
 *   される(Ethereum の should_update_justified_checkpoint を、View の純
 *   粋関数へ単純化したもの: epoch の途中で実現した矛盾する justification
 *   は次の epoch の window を待つ)。
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
 * unrealized スイッチの下で fork choice が降下してよいブロック: その
 * チェーン状態 が `root` の epoch 以上に新しい epoch の justified チェッ
 * クポイントを実現している葉と、その祖先。取り込んだ投票がそれより古い
 * ものしか justify できない枝は、より多くの投票を運んでいても除外
 * される。このモデルでは、各ブロックの チェーン状態 はすでに epoch の終
 * わりを待たずに取り込んだ投票を数えるので、ある枝の unrealized
 * justified チェックポイントはその tip の `ChainState.justified` であ
 * る。
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
