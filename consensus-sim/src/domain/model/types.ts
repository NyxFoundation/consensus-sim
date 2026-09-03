// ドメイン層 — 最抽象モデル。
// このモジュールは純粋である: UI もインフラも React も持たない。
// 命名は ESSENCE.md の「用語」節に従うユビキタス言語に沿う。
//
// 識別子はソートごとに区別される(識別子のソート): 生の number はどの
// ソートにも代入できるが、あるソートの値が別のソートとして通ることはない
// — スロットをブロックの識別子を期待する関数に渡すと型エラーになる
// (混用を型検査で防ぐ)。BlockIndex は識別のみを担い、骨格がタイブレーク
// に用いる全順序は order.ts に明示的な規則として存在する。

/** バリデータの識別子(ソート)。他のソートの number とは型上区別される。 */
export type ValidatorIndex = number & { readonly __sort?: "ValidatorIndex" };
/** スロット番号(ソート)。他のソートの number とは型上区別される。 */
export type SlotIndex = number & { readonly __sort?: "SlotIndex" };
/** エポック番号(ソート)。他のソートの number とは型上区別される。 */
export type EpochIndex = number & { readonly __sort?: "EpochIndex" };
/** ブロックの識別子(ソート)。識別のみを担い、順序は order.ts が定める。 */
export type BlockIndex = number & { readonly __sort?: "BlockIndex" };

/** バリデータの重み(ステーク)。非負の有理数。チェーン状態に属し、
 * View には属さない。 */
export type Stake = number & { readonly __sort?: "Stake" };

/** 錨ブロックは常にブロック 0 であり、あらゆる木の根である。 */
export const ANCHOR_BLOCK_INDEX: BlockIndex = 0;

/**
 * シミュレーションはエポックの先頭スロットであるスロット 0 から始まる。
 * 錨ブロックはスロット 0 に置かれ、開始時点で全バリデータの合意により
 * 既に finalized となっている。最初のスロット進行でスロット 1 に移り、
 * この実行の最初の提案が起こる。
 */
export const START_SLOT: SlotIndex = 0;

/**
 * 観測時点(Instant)が取り得る局面。スロット内で提案(proposal)・
 * 投票(vote)・末(end)の順に並ぶ。ブロックは提案の局面で、投票は投票の
 * 局面で公開され、それぞれ配送を経てのちの局面の View に届く。
 */
export type Phase = "proposal" | "vote" | "end";

/**
 * 観測時点(Instant)。スロットと局面(Phase)の組であり、View の座標
 * (知識をどこで読むか)を表すにすぎず、View の内容ではない。
 */
export interface Instant {
  readonly slot: SlotIndex;
  readonly phase: Phase;
}

export const atProposal = (slot: SlotIndex): Instant => ({ slot, phase: "proposal" });
export const atVote = (slot: SlotIndex): Instant => ({ slot, phase: "vote" });
export const atEnd = (slot: SlotIndex): Instant => ({ slot, phase: "end" });

/**
 * チェックポイント: ある枝上で `epoch` を代表するブロック — その枝上で
 * エポックの先頭スロット以前の直近のブロック。境界スロットが空であれば
 * 同じブロックが連続するエポックのチェックポイントになるため、epoch は
 * 識別の一部をなす。
 */
export interface Checkpoint {
  readonly epoch: EpochIndex;
  readonly block: BlockIndex;
}

/** 錨はあらゆる枝におけるエポック 0 のチェックポイントである。 */
export const ANCHOR_CHECKPOINT: Checkpoint = { epoch: 0, block: ANCHOR_BLOCK_INDEX };

/**
 * 投票: `head` は GHOST 系の先頭支持(LMD 部分)であり、`source` →
 * `target` は FFG のチェックポイント対である。`target.epoch` が `slot`
 * の属するエポックと一致するとき整形式とする。
 */
export interface Vote {
  readonly validator: ValidatorIndex;
  readonly slot: SlotIndex;
  readonly head: BlockIndex;
  readonly source: Checkpoint;
  readonly target: Checkpoint;
}

/**
 * エクイボケーションの証拠: 同一バリデータの相反する 2 メッセージの対で、
 * 次の 3 形のいずれかを取る —
 * - 二重提案: 同一スロットの 2 ブロック;
 * - 二重投票: 同一スロットで内容の異なる 2 投票、または同じ target の
 *   エポックで target が異なる 2 投票;
 * - 包囲投票: source₁.epoch < source₂.epoch < target₂.epoch < target₁.epoch
 *   を満たす 2 投票。
 * 後の 2 つは Casper FFG の可罰条件である。独立したメッセージ型ではなく、
 * 両メッセージが揃った View で成立し、ブロックの body に取り込まれる。
 * 対は正準の順序で保持する(ブロックは昇順、投票はスロット順、次いで
 * order.ts の内容順 — このため target のエポックが後の包囲する投票が
 * 2 番目になる)ため、同一の証拠は同一のものとなる。
 */
export type Equivocation =
  | {
      readonly kind: "double-proposal";
      readonly validator: ValidatorIndex;
      readonly slot: SlotIndex;
      /** 相反する 2 ブロックの識別子。昇順。 */
      readonly blocks: readonly [BlockIndex, BlockIndex];
    }
  | {
      readonly kind: "double-vote";
      readonly votes: readonly [Vote, Vote];
    }
  | {
      readonly kind: "surround-vote";
      /** 包囲される投票、続いて包囲する投票。 */
      readonly votes: readonly [Vote, Vote];
    };

/**
 * ブロックが運ぶもの(取り込み): プロポーザーが含めた投票と証拠。
 * チェーン状態は body のみから導出される — 投票はその枝上のブロックに
 * 取り込まれて初めて、その枝の justification に数えられる。
 */
export interface BlockBody {
  readonly votes: readonly Vote[];
  readonly evidence: readonly Equivocation[];
}

/** 錨: あらゆる木の根であり、開始時点で finalized と合意されている。
 * この実行の誰も提案しておらず parent も持たない — そのどちらにも
 * 代わりとなる番兵値は用意しない。 */
export interface AnchorBlock {
  readonly kind: "anchor";
  readonly index: BlockIndex;
  readonly slot: SlotIndex;
}

/** 提案ブロック: プロポーザーが自身のスロットで公開するもの。 */
export interface ProposedBlock {
  readonly kind: "proposed";
  readonly index: BlockIndex;
  readonly parent: BlockIndex;
  readonly slot: SlotIndex;
  readonly proposer: ValidatorIndex;
  readonly body: BlockBody;
}

/** ESSENCE.md の参照型: Block = 錨 {index, slot} | 提案 {…}。 */
export type Block = AnchorBlock | ProposedBlock;

export const EMPTY_BODY: BlockBody = { votes: [], evidence: [] };

/** あらゆるシミュレーションが起点とする錨ブロック。 */
export function anchorBlock(): AnchorBlock {
  return { kind: "anchor", index: ANCHOR_BLOCK_INDEX, slot: START_SLOT };
}

export function isProposed(block: Block): block is ProposedBlock {
  return block.kind === "proposed";
}

/** ブロックが取り込んだ内容 — 錨の場合は何もない。 */
export function bodyOf(block: Block): BlockBody {
  return block.kind === "proposed" ? block.body : EMPTY_BODY;
}
