// 攻撃 — 形式的な体系: 攻撃とは (攻撃者集合の条件, 攻撃目標,
// 戦略) の 3 つ組である(必須 17)。
//
// - 攻撃者集合はバリデータの空でない部分集合である。ライ
//   ブラリの攻撃は条件(攻撃者集合の条件)までを固定し、シナリオは条件を
//   満たさない場合もある具体的な 1 集合を束縛する。
// - 攻撃目標は述語の空でない列(attackGoal.ts)で、段ごと
//   に判定される。
// - 戦略は、すべてのスロット境界において攻撃者の観測 — 攻撃
//   者の View の併合(攻撃者は即座かつ完全にすべてを共有する)と予定表
//   — を、能力範囲(必須 18)の中でこの先のスロットの行動へ写す規則であ
//   る。入力を無視する戦略が固定行動リストという特殊ケースになる。
//
// 攻撃はその前提を宣言する: 保持するプロトコルパラメータ(プロト
// コルプリセットと上書き)と、正直なメッセージがどれだけ保留されうるか
// の上限であるネットワーク前提 d である。
//
// 3 つ組・能力範囲・述語の意味論を変更することは人間の決定であり(ESSENCE
// 思想 (c))、本モジュールはそれらをあるがままに記述する。

import type { Action } from "./action";
import type { AttackGoal } from "./attackGoal";
import { addBlock, createBlockTree, type BlockTree } from "./blockTree";
import type { InitialConditions } from "./initialConditions";
import { voteKey } from "./inclusion";
import { isExactRef, type MessageRef } from "./messageRef";
import type { PresetName, ProtocolParams } from "./protocolParams";
import type { Schedule } from "./schedule";
import type { Block, SlotIndex, ValidatorIndex, Vote } from "./types";
import type { View } from "./view";

/**
 * 攻撃が保持する前提: プロトコルプリセット名とフィールド単位の上
 * 書きとして表すプロトコルパラメータ、および遅延上限 d(`maxDelay`)—
 * 正直なメッセージが公開から高々 d スロット後にはすべての受信者に届くと
 * いうネットワーク前提。
 */
export interface AttackPremise {
  readonly preset: PresetName;
  readonly overrides?: Partial<ProtocolParams>;
  readonly maxDelay: number;
}

/**
 * 攻撃パラメータ: 戦略と既定実行構成が読み取
 * る、攻撃ごとの数値。`maxDelay`(d)はすべての攻撃に共通する — 前提の遅
 * 延上限であり、能力範囲が攻撃者による正直なメッセージの遅延に対して強
 * 制する(必須 18)。
 */
export interface AttackParams {
  readonly maxDelay: number;
  readonly [name: string]: number;
}

/** 攻撃者集合が満たすべき条件: 少なくとも `atLeast` 人のバリデータ、
 * または初期ステーク総量の少なくとも `atLeast` の割合。 */
export type AttackerCondition =
  | { readonly kind: "count"; readonly atLeast: number }
  | { readonly kind: "stake-ratio"; readonly atLeast: number };

/** 攻撃者が占める初期ステーク総量に対する割合。 */
export function attackerStakeRatio(
  attackers: readonly ValidatorIndex[],
  config: InitialConditions,
): number {
  let mine = 0;
  let total = 0;
  config.initialStakes.forEach((stake, v) => {
    total += stake;
    if (attackers.includes(v)) mine += stake;
  });
  return total === 0 ? 0 : mine / total;
}

export function satisfiesCondition(
  condition: AttackerCondition,
  attackers: readonly ValidatorIndex[],
  config: InitialConditions,
): boolean {
  return condition.kind === "count"
    ? attackers.length >= condition.atLeast
    : attackerStakeRatio(attackers, config) >= condition.atLeast;
}

/**
 * スロット境界で攻撃者が観測するもの(攻撃者の観測状態): `slot` の終わ
 * り、その時点でのすべての攻撃者の View の併合、そして予定表。`config`
 * は攻撃者が推論に用いるプロトコルパラメータと初期ステーク(閾値、プリ
 * セット)を運ぶ。
 */
export interface AttackerObservation {
  readonly slot: SlotIndex;
  readonly attackers: readonly ValidatorIndex[];
  /** 併合された View: いずれかの攻撃者が保持するすべてのブロックと投票。 */
  readonly view: View;
  readonly schedule: Schedule;
  readonly config: InitialConditions;
}

/**
 * ある1つの時点で取った複数の View の併合: それらのブロックの和集合
 * (どの View も parent を保持しないブロックは、他の View と同様に除外さ
 * れる)と投票の和集合(重複除去し、最初に現れたものを残す)。併合結果
 * も他と同じ 1 つの View であり、それ自身の座標は持たない。
 */
export function mergeViews(views: readonly View[]): View {
  if (views.length === 0) throw new Error("mergeViews needs at least one view");
  const blocks = new Map<number, Block>();
  for (const view of views) {
    for (const block of view.blockTree.blocks.values()) blocks.set(block.index, block);
  }
  let blockTree: BlockTree = createBlockTree();
  const ordered = [...blocks.values()].sort((a, b) => a.slot - b.slot || a.index - b.index);
  for (const block of ordered) {
    if (block.kind === "anchor" || !blockTree.blocks.has(block.parent)) continue;
    blockTree = addBlock(blockTree, block);
  }
  const seen = new Set<string>();
  const votes: Vote[] = [];
  for (const view of views) {
    for (const vote of view.votes) {
      const key = voteKey(vote);
      if (seen.has(key)) continue;
      seen.add(key);
      votes.push(vote);
    }
  }
  return { blockTree, votes };
}

/** その時点での各攻撃者個別の View(攻撃者ごとに 1 つ、攻撃者の順序で)
 * から得られる、`slot` の終わりにおける攻撃者の観測。 */
export function observeAsAttackers(
  attackers: readonly ValidatorIndex[],
  views: readonly View[],
  slot: SlotIndex,
  config: InitialConditions,
  schedule: Schedule,
): AttackerObservation {
  if (attackers.length === 0) throw new Error("the attacker set must not be empty");
  if (views.length !== attackers.length) {
    throw new Error("one view per attacker is required");
  }
  return { slot, attackers, view: mergeViews(views), schedule, config };
}

/** 戦略: 観測した境界より後のスロットに対する攻撃者の行動を返す。純
 * 粋関数であり、同じ観測と同じパラメータからは常に同じ行動が得られる —
 * これにより攻撃は同一に再現できる。 */
export type Strategy = (
  observation: AttackerObservation,
  params: AttackParams,
) => readonly Action[];

/** 3 つ組 (攻撃者集合の条件, 攻撃目標, 戦略)。 */
export interface Attack {
  readonly attackers: AttackerCondition;
  /** 空でない列。最初の段から判定される。 */
  readonly goal: readonly AttackGoal[];
  readonly strategy: Strategy;
}

// ── 攻撃者の行動の 2 基底(必須 18) ────────────────────────────────

/** 集合として名指しされるメッセージ: スロット区間の中で `senders` が公開
 * するすべて — partition や silence が参照する形である。 */
export interface MessageSpan {
  readonly senders: readonly ValidatorIndex[];
  readonly fromSlot: SlotIndex;
  /** 両端を含む。無指定なら無期限。 */
  readonly toSlot?: SlotIndex;
}

/**
 * 公開 (i): 公開前に(送信者・スロット・種別で、または span として)名指
 * しされる攻撃者自身のメッセージと、それについて行動が決めること: その
 * 内容(攻撃者の観測のみに基づく — ブロックの parent と body、投票の
 * head / source / target: 偽造は不可能)、そのタイミング(後のスロット
 * まで保留する)、その受信者集合(選択配送)、あるいは沈黙(一切公開し
 * ない)。
 */
export interface PublishBase {
  readonly base: "publish";
  readonly message: MessageRef | MessageSpan;
  readonly decides: "content" | "timing" | "receivers" | "silence";
}

/**
 * 配送 (ii): 公開前に(または span として)名指しされる正直バリデータの
 * メッセージ。`observers`(無指定なら送信者以外の全員)への到達は、公開
 * から `hold` スロット — 高々 d — 遅らせるか、あるいは欠落させる。
 */
export interface DeliverBase {
  readonly base: "deliver";
  readonly message: MessageRef | MessageSpan;
  readonly hold: number | "drop";
  readonly observers?: readonly ValidatorIndex[];
}

/** 行動の 2 基底: publish(公開)と deliver(配送)の総称。 */
export type ActionBase = PublishBase | DeliverBase;

const isSpan = (m: MessageRef | MessageSpan): m is MessageSpan => "senders" in m;

const sendersOf = (m: MessageRef | MessageSpan): readonly ValidatorIndex[] =>
  isSpan(m) ? m.senders : [m.sender];

/** 閉じた span がその内部で公開されたメッセージを高々どれだけ保留するか。 */
const spanHold = (fromSlot: SlotIndex, toSlot: SlotIndex | undefined): number | "drop" =>
  toSlot === undefined ? "drop" : toSlot - fromSlot + 1;

/**
 * 行動語彙は 2 基底の上の糖衣構文である: ある行動が攻撃者自身のメッセー
 * ジ(publish)と正直なメッセージ(deliver)に対して何を行うか。delay や
 * drop は攻撃者自身のメッセージの publish(timing または receivers)と、
 * 正直なメッセージの deliver である。partition は対称な集合である —
 * span の間、すべての正直なメッセージの deliver と、すべての攻撃者の
 * publish(receivers)を、分断が解消するまで保留し、解消しないなら欠落
 * させる。`attackers` がある送信者をどちら側に分類するかを決める。
 */
export function basesOf(
  action: Action,
  attackers: readonly ValidatorIndex[],
  schedule: Schedule,
): readonly ActionBase[] {
  const own = (v: ValidatorIndex): boolean => attackers.includes(v);
  const publish = (message: MessageRef | MessageSpan, decides: PublishBase["decides"]): PublishBase =>
    ({ base: "publish", message, decides });
  switch (action.kind) {
    case "double-propose":
      return [publish({ kind: "proposal", sender: action.validator, slot: action.slot }, "content")];
    case "double-vote": {
      const message: MessageRef = { kind: "vote", sender: action.validator, slot: action.slot };
      return action.split === undefined
        ? [publish(message, "content")]
        : [publish(message, "content"), publish(message, "receivers")];
    }
    case "vote-target":
      return [publish({ kind: "vote", sender: action.validator, slot: action.slot }, "content")];
    case "propose-parent":
    case "omit-inclusion":
      return [
        publish(
          { kind: "proposal", sender: schedule.proposerOf(action.slot), slot: action.slot },
          "content",
        ),
      ];
    case "stop":
      return [
        publish(
          {
            senders: action.validators,
            fromSlot: action.fromSlot,
            ...(action.toSlot === undefined ? {} : { toSlot: action.toSlot }),
          },
          "silence",
        ),
      ];
    case "delay":
    case "drop": {
      const hold = action.kind === "delay" ? action.untilSlot - action.message.slot : "drop";
      if (own(action.message.sender)) {
        return [publish(action.message, action.kind === "delay" ? "timing" : "receivers")];
      }
      return [
        {
          base: "deliver",
          message: action.message,
          hold,
          ...(action.observers === undefined ? {} : { observers: action.observers }),
        },
      ];
    }
    case "partition": {
      const hold = spanHold(action.fromSlot, action.toSlot);
      const span = (senders: readonly ValidatorIndex[]): MessageSpan => ({
        senders,
        fromSlot: action.fromSlot,
        ...(action.toSlot === undefined ? {} : { toSlot: action.toSlot }),
      });
      const involved = action.groups.flat();
      const honest = involved.filter((v) => !own(v));
      const mine = involved.filter(own);
      return [
        ...(honest.length === 0 ? [] : [{ base: "deliver", message: span(honest), hold } as const]),
        ...(mine.length === 0 ? [] : [publish(span(mine), "receivers")]),
      ];
    }
  }
}

/**
 * 攻撃者に必要な能力(必須 18) — 攻撃一覧がその攻撃に何が必要かを示す名
 * 前であり、行動が能力範囲に収まりうる各様式に 1 つずつ対応する: 攻撃者
 * 自身のバリデータのエクイボケーション・parent 指定・投票先指定・沈黙、
 * 自身のメッセージの保留と選択配送、自身の提案での取り込みの省略、正直
 * バリデータのメッセージの delay・drop・partition。
 */
export type Capability =
  | "equivocation"
  | "propose-parent"
  | "vote-target"
  | "silence"
  | "withhold"
  | "omit-inclusion"
  | "delay-honest"
  | "drop-honest"
  | "partition";

/** ある行動のすべての基底が能力範囲に収まっているかどうか: publish は攻
 * 撃者自身のメッセージでなければならない。deliver は正直なメッセージを
 * 公開前に(個体によってではなく — その内容を攻撃者が事前に知ることはで
 * きない)名指しし、高々 `maxDelay` スロットの保留、あるいは欠落でなけれ
 * ばならない。 */
export function withinRange(
  bases: readonly ActionBase[],
  attackers: readonly ValidatorIndex[],
  maxDelay: number,
): boolean {
  return bases.every((b) =>
    b.base === "publish"
      ? sendersOf(b.message).every((v) => attackers.includes(v))
      : (isSpan(b.message) || !isExactRef(b.message)) &&
        (b.hold === "drop" || b.hold <= maxDelay),
  );
}

/**
 * これらの攻撃者に対して `action` が行使する能力、または行動がその基底
 * について範囲外(`withinRange` が偽)のとき undefined: 攻撃者でないバリ
 * データとして振る舞う、正直バリデータが提案するスロットで提案する
 * (parent / omission)、正直なメッセージをその個体によって名指しする、
 * あるいは正直なメッセージを `maxDelay` スロットを超えて保留する — delay
 * によるものでも、それより遅く解消する partition によるものでも同様。攻
 * 撃者自身のメッセージはどちらの方法でも、任意の長さ保留・名指しできる。
 */
export function capabilityOf(
  action: Action,
  attackers: readonly ValidatorIndex[],
  schedule: Schedule,
  maxDelay: number,
): Capability | undefined {
  if (!withinRange(basesOf(action, attackers, schedule), attackers, maxDelay)) return undefined;
  switch (action.kind) {
    case "double-propose":
    case "double-vote":
      return "equivocation";
    case "vote-target":
      return "vote-target";
    case "stop":
      return "silence";
    case "propose-parent":
      return "propose-parent";
    case "omit-inclusion":
      return "omit-inclusion";
    case "partition":
      return "partition";
    case "delay":
      return attackers.includes(action.message.sender) ? "withhold" : "delay-honest";
    case "drop":
      return attackers.includes(action.message.sender) ? "withhold" : "drop-honest";
  }
}
