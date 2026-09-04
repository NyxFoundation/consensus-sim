// 簡約プロトコル骨格 — 提案がどう構築されるか
// (parent は fork choice、body は inclusion による)、アテスターがどう投
// 票するか、そしてプロトコルパラメータの下で View がどう head へと解決さ
// れるか。View に対する純粋関数群であり、いつ実行するかはシミュレーショ
// ンドライバが、誰が(proposer、committee)は schedule.ts が決める。
//
// fork choice はメッセージ層(View の votes)を読む。投票が運ぶチェック
// ポイントは チェーン状態層(head の ChainState)を読む。

import { type BlockTree } from "./blockTree";
import {
  chainStatesOf,
  forkChoiceRoot,
  viableBlocks,
  type ChainState,
  type ChainStateIndex,
} from "./chainState";
import type { InitialConditions } from "./initialConditions";
import { checkpointFor, epochOf } from "./finality";
import { ghostHead, type ForkChoiceWeights } from "./forkChoice";
import { buildBody, equivocatingVoters, type Omission } from "./inclusion";
import { compareBlockIndex, compareVoteContent } from "./order";
import { proposerForSlot, type Schedule } from "./schedule";
import {
  type BlockIndex,
  type Checkpoint,
  type ProposedBlock,
  type SlotIndex,
  type Stake,
  type ValidatorIndex,
  type Vote,
} from "./types";
import type { View } from "./view";

/** バリデータがその View から結論するもの: チェーン状態、root、head。 */
export interface Resolution {
  readonly states: ChainStateIndex;
  /** fork choice が開始した justified チェックポイント。 */
  readonly root: Checkpoint;
  readonly head: BlockIndex;
  /** ChainState(head) — この View の justified / finalized / stakes。 */
  readonly chainState: ChainState;
  /** この fork choice が用いた重み(stakes と、あれば proposer boost)。 */
  readonly weights: ForkChoiceWeights;
}

/**
 * `view` に対して `atSlot` で行う fork choice の実行において proposer
 * boost を受け取るブロック: `atSlot` の予定表上のプロポーザーによる提案
 * のうち、その View が保持し、かつ提案されたスロットのうちに受信された
 * もの。後から届く提案(delay)はより前のスロットに属し決して該当しな
 * い。二重提案 の下では、より小さいインデックスの方を先に受信し
 * たものとみなす。
 */
export function boostedBlock(
  view: View,
  atSlot: SlotIndex,
  config: InitialConditions,
): BlockIndex | undefined {
  if (config.params.boost <= 0) return undefined;
  const proposer = proposerForSlot(atSlot, config);
  let boosted: BlockIndex | undefined;
  for (const block of view.blockTree.blocks.values()) {
    if (block.kind !== "proposed" || block.slot !== atSlot || block.proposer !== proposer) {
      continue;
    }
    if (boosted === undefined || compareBlockIndex(block.index, boosted) < 0) {
      boosted = block.index;
    }
  }
  return boosted;
}

/** `stakes` における `slot` の committee の総ステーク。 */
export function committeeWeight(
  slot: SlotIndex,
  schedule: Schedule,
  stakes: ReadonlyMap<ValidatorIndex, Stake>,
): Stake {
  let total = 0;
  for (const v of schedule.committeeOf(slot)) total += stakes.get(v) ?? 0;
  return total;
}

/**
 * View に対して chain-state の導出と fork choice を、`atSlot`(バリデー
 * タが行動するスロット — プロポーザーはそれ以前のスロットについての
 * View 上で自身のスロットで行動する)で計算される fork choice として実
 * 行する。投票は、その投票が支持する head の チェーン状態 における投票者
 * のステークで重み付けされる(ESSENCE 必須 25: バリデータの重みはその
 * head の チェーン状態 における自身のステークである)。したがって、ある
 * 枝に取り込まれた罰則はまさにそこに効く。`atSlot` の timely な提
 * 案には、その committee の重み × boost が上乗せされる。ここで緩和策
 * (必須 27)が適用される: fork-choice ルールが数える投票を選び、
 * equivocation discount はこの View が投票証拠を保持する投票者の重みを
 * ゼロにし、2 つのチェックポイント切替スイッチはそれぞれ独立に root
 * (window)を選び候補を絞り込む(unrealized)。
 */
export function resolveView(
  view: View,
  config: InitialConditions,
  schedule: Schedule,
  atSlot: SlotIndex,
): Resolution {
  const { params } = config;
  const states = chainStatesOf(view.blockTree, config);
  const root = forkChoiceRoot(view.blockTree, states, params.checkpointSwitch, atSlot);
  const discounted = params.equivocationDiscount
    ? equivocatingVoters(view.votes)
    : undefined;
  const weightOf = (vote: Vote): Stake =>
    discounted?.has(vote.validator)
      ? 0
      : (states.get(vote.head)?.stakes.get(vote.validator) ?? 0);
  const boosted = boostedBlock(view, atSlot, config);
  const weights: ForkChoiceWeights = {
    weightOf,
    boost:
      boosted === undefined
        ? undefined
        : {
            block: boosted,
            weight:
              committeeWeight(atSlot, schedule, states.get(boosted)!.stakes) *
              config.params.boost,
          },
  };
  const head = ghostHead(view.blockTree, view.votes, root.block, {
    weights,
    rule: params.forkChoice,
    candidates: params.checkpointSwitch.unrealized
      ? viableBlocks(view.blockTree, states, root)
      : undefined,
  });
  return { states, root, head, chainState: states.get(head)!, weights };
}

/**
 * プロポーザーが `slot` で公開するブロックを構築する: parent = その
 * fork-choice head(またはフォーク作成として指定され可視であれば
 * `parent`)、body = その枝にまだ取り込まれていないすべてから
 * `omit` を除いた、正直な取り込み。`index` は呼び出し側が割り当てる(シ
 * ミュレーションが次の空きインデックスを保持する)。
 */
export function buildProposal(
  view: View,
  resolution: Resolution,
  slot: SlotIndex,
  proposer: ValidatorIndex,
  index: BlockIndex,
  parent: BlockIndex = resolution.head,
  omit: Omission = {},
): ProposedBlock {
  const tree: BlockTree = view.blockTree;
  const chosen = tree.blocks.has(parent) ? parent : resolution.head;
  return {
    kind: "proposed",
    index,
    parent: chosen,
    slot,
    proposer,
    body: buildBody(tree, view.votes, chosen, omit),
  };
}

/**
 * バリデータがすでに `epoch` で投票している場合、その epoch について確定
 * させた FFG 部分: View 内でのその epoch の最初の投票の (source,
 * target)(最も早いスロット。二重投票 の下では内容順序で同点を解消す
 * る)。
 */
function ffgSettledIn(
  view: View,
  validator: ValidatorIndex,
  epoch: number,
): Pick<Vote, "source" | "target"> | undefined {
  let first: Vote | undefined;
  for (const vote of view.votes) {
    if (vote.validator !== validator || epochOf(vote.slot) !== epoch) continue;
    if (
      first === undefined ||
      vote.slot < first.slot ||
      (vote.slot === first.slot && compareVoteContent(vote, first) < 0)
    ) {
      first = vote;
    }
  }
  return first === undefined ? undefined : { source: first.source, target: first.target };
}

/**
 * アテスターがその View から `slot` で投じる投票。head は毎スロット
 * fork choice に従う(LMD 部分)。FFG 部分(source, target)は epoch ご
 * とに 1 回決まる: そのバリデータがそのエポック中に最初に投票するスロッ
 * トで head のチェーンから読み取られる — source = head の チェーン状態
 * の justified チェックポイント、target = head のチェーン上のその epoch
 * のチェックポイント — そして同じ epoch の以後の投票はすべてこれを繰り
 * 返す(正直バリデータは、Ethereum が epoch ごとに 1 回だけ attest する
 * のと同様、自身の FFG 投票と決して矛盾しない)。`override`(投票先指
 * 定)は三者のいずれも置き換えうる: head の指定(View のブロック)は、
 * 新たに決まった FFG 部分をそのチェーン上へ動かす。target の指定は、そ
 * のスロットの epoch のチェックポイントとして立つ View のブロック
 * (epoch はスロットから定まる)。source の指定は View のある枝の
 * チェックポイントである — すでにその epoch で投じたものと異なる FFG
 * 部分の指定は証拠となる。View が保持しない指定は無視される。
 */
export function buildAttestation(
  view: View,
  resolution: Resolution,
  slot: SlotIndex,
  validator: ValidatorIndex,
  override: VoteOverride = {},
): Vote {
  const tree = view.blockTree;
  const known = (b: BlockIndex | undefined): BlockIndex | undefined =>
    b !== undefined && tree.blocks.has(b) ? b : undefined;
  const head = known(override.head) ?? resolution.head;
  const epoch = epochOf(slot);
  const settled = ffgSettledIn(view, validator, epoch);
  const source =
    override.source !== undefined && known(override.source.block) !== undefined
      ? override.source
      : (settled?.source ?? resolution.states.get(head)!.justified);
  const designatedTarget = known(override.target);
  const target =
    designatedTarget !== undefined
      ? { epoch, block: designatedTarget }
      : (settled?.target ?? checkpointFor(tree, head, epoch));
  return { validator, slot, head, source, target };
}

/** 投票先指定: アテスターの投票が誘導される先。いずれも省略可能 — head
 * と target はその View のブロックの中から、source はその View のあるブ
 * ランチのチェックポイントの中から。 */
export interface VoteOverride {
  readonly head?: BlockIndex | undefined;
  readonly source?: Checkpoint | undefined;
  readonly target?: BlockIndex | undefined;
}

/**
 * 二重投票(二重投票)の 2 回目の投票: 主投票と同じバリデータ・同じス
 * ロットで、`head` が指定されていて View に保持され主投票の head と異な
 * ればそれを支持し、そうでなければ主投票の head の parent を支持する —
 * 決定的であり、2 つの head が異なれば真のエクイボケーションとなる。
 * target は代替 head のチェーン上のその epoch のチェックポイント。
 * source は主投票のものを維持する(そのバリデータが投票の起点とする
 * justified チェックポイント)。異なる代替が存在しない場合(主投票の
 * head = 錨ブロックで何も指定されていない)は undefined を返す。
 */
export function buildEquivocalAttestation(
  tree: BlockTree,
  primary: Vote,
  head?: BlockIndex,
): Vote | undefined {
  const headBlock = tree.blocks.get(primary.head);
  if (headBlock === undefined) return undefined;
  const designated =
    head !== undefined && head !== primary.head && tree.blocks.has(head) ? head : undefined;
  if (designated === undefined && headBlock.kind === "anchor") return undefined;
  const altHead = designated ?? (headBlock as ProposedBlock).parent;
  return {
    validator: primary.validator,
    slot: primary.slot,
    head: altHead,
    source: primary.source,
    target: checkpointFor(tree, altHead, epochOf(primary.slot)),
  };
}
