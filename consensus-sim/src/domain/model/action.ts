// 行動 — スロット境界が引き起こしうる攪乱の形: partition(分断)、
// silence(沈黙 = オンライン停止)、equivocation(二重提案・二重投票)、
// 選んだ受信者集合に対するメッセージ単位の delay / drop(遅延・欠落、受信者
// 集合)、fork creation(提案の parent 指定)、vote designation(投票先指定)、
// omitted inclusion(取り込みの省略)。
//
// これらの形は攻撃者の行動語彙であり(必須 18)、戦略は attack.ts が検査
// する能力範囲の中であらゆる種類を用いてよい(エクイボケーション・parent
// 指定・投票先指定・沈黙・省略には攻撃者自身のバリデータを、保留と選択配送
// には攻撃者自身のメッセージを、delay / drop / partition には正直バリデー
// タのメッセージを対象とする)。同じ形にオフライン状態を加えたものが手動
// 介入の指定内容である(sim/intervention.ts)。純粋なデータであり、シナリ
// オの一部として永続化できる。

import type { EvidenceRef } from "./inclusion";
import type { MessageRef } from "./messageRef";
import type { BlockIndex, Checkpoint, SlotIndex, ValidatorIndex } from "./types";

/** partition が有効な間、メッセージはグループの境界を越えない。
 * どのグループにも含まれないバリデータは、暗黙のひとつの残りグループを
 * 構成する。 */
export interface PartitionAction {
  readonly kind: "partition";
  readonly fromSlot: SlotIndex;
  /** partition が有効な最後のスロット(両端を含む)。無指定なら解消まで。 */
  readonly toSlot?: SlotIndex;
  readonly groups: readonly (readonly ValidatorIndex[])[];
}

/** オンライン停止 / 沈黙: 停止中のバリデータは提案も投票も行わないが、
 * 観測は続ける(沈黙するのであって、盲目になるのではない)。 */
export interface StopAction {
  readonly kind: "stop";
  readonly fromSlot: SlotIndex;
  /** 停止する最後のスロット(両端を含む)。無指定なら再開まで。 */
  readonly toSlot?: SlotIndex;
  readonly validators: readonly ValidatorIndex[];
}

/** `slot` において、そのプロポーザーが同じ parent の上に 2 つのブロックを
 * 公開する。`validator` が実際にそのスロットで提案しない限り無視される。 */
export interface DoubleProposeAction {
  readonly kind: "double-propose";
  readonly slot: SlotIndex;
  readonly validator: ValidatorIndex;
}

/** `slot` において、バリデータは最初の投票と並んで矛盾する 2 回目の投票
 * を行う: `head` が指定されていればそれ(最初の投票の head とは異なる、
 * その View 上のブロック)へ、そうでなければ最初の head の parent へ投票
 * する。`split` は攻撃者による 2 つの半分の選択配送である: 最初の投票は
 * `first` に、2 回目の投票(`head` 宛てで、その場合は `head` の指定が必要)
 * は `second` に即座に届き、それ以外の全員には `untilSlot` 以降にしか届か
 * ない — これは、存在する前からメッセージ参照が一括して名指しできる、
 * 1 スロットの 2 つの公開である。 */
export interface DoubleVoteAction {
  readonly kind: "double-vote";
  readonly slot: SlotIndex;
  readonly validator: ValidatorIndex;
  readonly head?: BlockIndex;
  readonly split?: SplitDelivery;
}

/** 二重投票の 2 通の投票をそれぞれ誰に届けるかを表す選択配送の指定。 */
export interface SplitDelivery {
  readonly first: readonly ValidatorIndex[];
  readonly second: readonly ValidatorIndex[];
  readonly untilSlot: SlotIndex;
}

/** 指定されたメッセージは、対象の観測者には `untilSlot` 以降にしか届かな
 * い。送信者は常に自分自身のメッセージを見る。公開前に(個体を持たない
 * 参照として)名指しされる場合、これは送信者自身による保留と選択配送で
 * ある。 */
export interface DelayAction {
  readonly kind: "delay";
  readonly message: MessageRef;
  readonly untilSlot: SlotIndex;
  /** 無指定なら送信者以外の全観測者。 */
  readonly observers?: readonly ValidatorIndex[];
}

/** 指定されたメッセージは対象の観測者には決して届かない。送信者は常に
 * 自分自身のメッセージを見る。 */
export interface DropAction {
  readonly kind: "drop";
  readonly message: MessageRef;
  /** 無指定なら送信者以外の全観測者。 */
  readonly observers?: readonly ValidatorIndex[];
}

/** フォーク作成: `slot` のプロポーザーは、その fork choice が選ぶブロック
 * の代わりに `parent` の上に構築する。提案時点でプロポーザーの View に
 * `parent` が無ければ無視され、fork choice にフォールバックする。 */
export interface ProposeParentAction {
  readonly kind: "propose-parent";
  readonly slot: SlotIndex;
  readonly parent: BlockIndex;
}

/** 投票先指定: `slot` において、バリデータの投票は指定された head /
 * target(投票時点でのその View のブロック、target の epoch はスロットか
 * ら定まる)と source(その View のある枝のチェックポイント)を用
 * いる。いずれも省略可能で、保持していない指定は無視される。指定されな
 * かった要素は fork choice と FFG ルールに従う — head が指定されていれば
 * その head から。 */
export interface VoteTargetAction {
  readonly kind: "vote-target";
  readonly slot: SlotIndex;
  readonly validator: ValidatorIndex;
  readonly head?: BlockIndex;
  readonly source?: Checkpoint;
  readonly target?: BlockIndex;
}

/** 取り込みの省略: `slot` のプロポーザーは、指定された投票(メッセージ
 * 参照による)と証拠(エクイボケータ・スロット・種別による)をブロック
 * の body から除外する。それ以外はすべて取り込みルールにより取り込まれ
 * る。 */
export interface OmitInclusionAction {
  readonly kind: "omit-inclusion";
  readonly slot: SlotIndex;
  readonly votes?: readonly MessageRef[];
  readonly evidence?: readonly EvidenceRef[];
}

/** 攻撃者やシナリオの手動介入が指定できる行動の全体。 */
export type Action =
  | PartitionAction
  | StopAction
  | DoubleProposeAction
  | DoubleVoteAction
  | DelayAction
  | DropAction
  | ProposeParentAction
  | VoteTargetAction
  | OmitInclusionAction;
