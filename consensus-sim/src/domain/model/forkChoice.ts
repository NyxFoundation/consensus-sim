// fork choice(GHOST 系) — block tree と投票に対する純粋関数群。
// ルールがどの投票を数えるかを決める: LMD-GHOST は各バリデータの最新の
// 投票のみ、GHOST はすべての投票。GHOST は root チェックポイントから、常
// に最も重い子部分木へと降りていく。重みはステーク(呼び出し側が投票ご
// とに選ぶ チェーン状態 から得る)に加え、1 スロットの提案については
// proposer boost を足したもの。呼び出し側はどのブロックが候補となるかを
// 制限することもできる(unrealized justification による justified チェ
// ックポイント切替)。

import { childrenOf, isAncestor, type BlockTree } from "./blockTree";
import { compareVoteContent } from "./order";
import type { ForkChoiceRule } from "./protocolParams";
import type { BlockIndex, Stake, ValidatorIndex, Vote } from "./types";

/**
 * 1 回の fork choice 計算において、投票と proposer boost がどう重み付け
 * されるか。`weightOf` は投票が運ぶステーク — どの チェーン状態 から読み
 * 取るかは呼び出し側が決める。`boost` はこの計算限りで、`block`(現在の
 * スロットの timely な提案、ESSENCE 必須 3)の部分木に `weight` を加算す
 * る。
 */
export interface ForkChoiceWeights {
  readonly weightOf: (vote: Vote) => Stake;
  readonly boost?:
    | { readonly block: BlockIndex; readonly weight: Stake }
    | undefined;
}

/** すべての投票の重みが 1 で、boost も無い — 素の GHOST カウント。 */
export const UNIT_WEIGHTS: ForkChoiceWeights = { weightOf: () => 1 };

/** 1 回の fork choice 実行が、tree・votes・root 以外に受け取るもの。 */
export interface ForkChoiceOptions {
  readonly weights?: ForkChoiceWeights;
  /** GHOST はすべての投票を数える。LMD-GHOST(既定)は各バリデー
   * タの最新の投票のみ数える。 */
  readonly rule?: ForkChoiceRule;
  /**
   * 指定された場合、これらのブロックにしか降りられない: 集合外の子はその
   * 部分木ごと飛ばされる(緩和策: unrealized justification は、より古い
   * justified チェックポイントしか実現できない枝を除外する)。
   */
  readonly candidates?: ReadonlySet<BlockIndex> | undefined;
}

/**
 * 各バリデータの最新の投票(LMD)。同じバリデータによる同じスロットの投
 * 票(エクイボケーション)については、骨格の内容順序(order.ts)で先に来
 * る方を勝者とするので、結果はメッセージの到着順序に依存しない(決定
 * 性)。
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
 * fork-choice ルールが数える投票(必須 27): LMD-GHOST の下では各バリデ
 * ータの最新の投票のみ、GHOST の下ではすべての投票 — したがって GHOST で
 * はあるバリデータの過去の投票や、エクイボケーションの両方の投票も重み
 * を保つ。
 */
export function countedVotes(
  votes: readonly Vote[],
  rule: ForkChoiceRule = "LMD-GHOST",
): readonly Vote[] {
  return rule === "GHOST" ? votes : [...latestVotes(votes).values()];
}

/**
 * `block` の GHOST 部分木重み: `block` を根とする部分木内の head を支持
 * する、数える対象の投票のステークに、boost 対象のブロックがその部分木
 * にあれば proposer boost を加えたもの。head がこの tree に未知の投票は
 * 無視される(そのバリデータはまだ head を示していない)。
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
 * `root`(通常は justified チェックポイントのブロック)から GHOST で決ま
 * る head ブロック: 部分木重みが最大の候補の子へ降りる。同点はブロック順
 * 序(order.ts — 子はその順序で並ぶ)で優先される子に決まるので、結果は
 * 決定的である。候補となる子が 1 つも無ければ、そこで降下は止まる。
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
