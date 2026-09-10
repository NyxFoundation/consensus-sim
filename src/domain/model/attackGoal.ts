// 攻撃目標 — 攻撃を判定する観測可能な述語(必須 19)とその
// 評価。攻撃目標は述語の空でない列であり、すべてのスロット境界において god
// view(神視点: 公開されたすべてのブロックと投票、および各枝の
// チェーン状態)から、最初の段から順に段ごとに評価される: ある段は、その
// 一つ前の段が達成されて初めて判定され、攻撃目標は最後の段が達成されたとき
// に達成される。すべての判定 (verdict) はその証拠を伴うので、trace は各
// スロットにおいてある段がなぜ成立する／しないかを示すことができる。

import { isAncestor, type BlockTree } from "./blockTree";
import {
  checkpointStatus,
  latestFinalized,
  totalStake,
  type ChainStateIndex,
} from "./chainState";
import { validatorIndices, type InitialConditions } from "./initialConditions";
import { compareBlockIndex, sameCheckpoint } from "./order";
import type { BlockIndex, Checkpoint, SlotIndex, ValidatorIndex } from "./types";

/**
 * - 安全性違反: 公開されたブロック木の 2 つのチェックポイントが、互いに
 *   祖先の関係になく、それぞれ自身の枝の チェーン状態 で finalized
 *   になっている。
 * - 活性停止: 公開された木のどの枝においても、直近 `slots` スロッ
 *   ト(L)の間 finalized が進んでいない。
 * - リオーグ: 正直バリデータの head が、その 1 つ前のスロットの head の
 *   子孫でないブロックへ移ることを 1 イベントとして数える。何らかの正直
 *   バリデータが `count` 個(k、既定 1)のイベントを累積する。
 * - 攻撃者ステーク比率: 何らかの正直バリデータの head の チェーン状態 に
 *   おいて、攻撃者の総ステーク ÷ 全員の総ステークが `threshold`(θ)に達
 *   する。
 */
export type AttackGoal =
  | { readonly kind: "safety-violation" }
  | { readonly kind: "liveness-stall"; readonly slots: number }
  | { readonly kind: "reorg"; readonly count: number }
  | { readonly kind: "attacker-stake-ratio"; readonly threshold: number };

/** リオーグ述語の既定の k。 */
export const DEFAULT_REORG_COUNT = 1;

/** 述語が読み取る、あるスロット終了時点での 神視点: 公開されたすべての
 * ブロックとその チェーン状態、およびすべてのバリデータの head。 */
export interface GodView {
  readonly slot: SlotIndex;
  readonly tree: BlockTree;
  readonly chainStates: ChainStateIndex;
  readonly heads: ReadonlyMap<ValidatorIndex, BlockIndex>;
}

/** ある述語がそのスロットで成立する／しない理由。 */
export type GoalEvidence =
  | {
      readonly kind: "safety-violation";
      readonly holds: boolean;
      /** 矛盾する finalized な 2 つのチェックポイント(あれば)。 */
      readonly conflicting?: readonly [BlockIndex, BlockIndex];
    }
  | {
      readonly kind: "liveness-stall";
      readonly holds: boolean;
      /** 神視点 における最新の finalized チェックポイント。 */
      readonly finalized: Checkpoint;
      /** 最後に finalized が進んでからのスロット数(錨ブロックはスロット 0
       * で finalized とみなす)。 */
      readonly stalledSlots: number;
    }
  | {
      readonly kind: "reorg";
      readonly holds: boolean;
      /** 正直バリデータ全体での最大の累積イベント数。 */
      readonly count: number;
      /** これまでで最も新しいイベント(同一スロットでは最小のバリデータ
       * インデックス)。 */
      readonly latest?: {
        readonly validator: ValidatorIndex;
        readonly slot: SlotIndex;
        readonly from: BlockIndex;
        readonly to: BlockIndex;
      };
    }
  | {
      readonly kind: "attacker-stake-ratio";
      readonly holds: boolean;
      /** 正直バリデータの head 全体での最大の比率。 */
      readonly ratio: number;
      /** その比率を読み取った正直バリデータ(とその head)。 */
      readonly validator?: ValidatorIndex;
      readonly head?: BlockIndex;
    };

const honestValidators = (
  attackers: readonly ValidatorIndex[],
  config: InitialConditions,
): ValidatorIndex[] =>
  validatorIndices(config.validatorCount).filter((v) => !attackers.includes(v));

/**
 * `history[at]` において 1 つの述語を評価する(`history[i]` はスロット i
 * 終了時点の 神視点。進行を見る述語はそれ以前のスロットを読む)。
 */
export function evaluatePredicate(
  goal: AttackGoal,
  history: readonly GodView[],
  at: number,
  attackers: readonly ValidatorIndex[],
  config: InitialConditions,
): GoalEvidence {
  const view = history[at];
  if (view === undefined) throw new Error(`no god view at index ${at}`);
  switch (goal.kind) {
    case "safety-violation": {
      const finalized = [...checkpointStatus(view.tree, config).finalized].sort(compareBlockIndex);
      for (let i = 0; i < finalized.length; i++) {
        for (let j = i + 1; j < finalized.length; j++) {
          const a = finalized[i]!;
          const b = finalized[j]!;
          if (!isAncestor(view.tree, a, b) && !isAncestor(view.tree, b, a)) {
            return { kind: "safety-violation", holds: true, conflicting: [a, b] };
          }
        }
      }
      return { kind: "safety-violation", holds: false };
    }
    case "liveness-stall": {
      const finalizedAt = (i: number): Checkpoint => latestFinalized(history[i]!.chainStates);
      const finalized = finalizedAt(at);
      let lastAdvance = 0;
      for (let i = at; i > 0; i--) {
        if (!sameCheckpoint(finalizedAt(i), finalizedAt(i - 1))) {
          lastAdvance = i;
          break;
        }
      }
      const stalledSlots = at - lastAdvance;
      return {
        kind: "liveness-stall",
        holds: stalledSlots >= goal.slots,
        finalized,
        stalledSlots,
      };
    }
    case "reorg": {
      let count = 0;
      let latest: Extract<GoalEvidence, { kind: "reorg" }>["latest"];
      for (const v of honestValidators(attackers, config)) {
        let events = 0;
        for (let i = 1; i <= at; i++) {
          const from = history[i - 1]!.heads.get(v);
          const to = history[i]!.heads.get(v);
          if (from === undefined || to === undefined) continue;
          if (isAncestor(history[i]!.tree, from, to)) continue;
          events += 1;
          if (latest === undefined || i > latest.slot) {
            latest = { validator: v, slot: history[i]!.slot, from, to };
          }
        }
        count = Math.max(count, events);
      }
      return {
        kind: "reorg",
        holds: count >= goal.count,
        count,
        ...(latest === undefined ? {} : { latest }),
      };
    }
    case "attacker-stake-ratio": {
      let best: Extract<GoalEvidence, { kind: "attacker-stake-ratio" }> = {
        kind: "attacker-stake-ratio",
        holds: false,
        ratio: 0,
      };
      for (const v of honestValidators(attackers, config)) {
        const head = view.heads.get(v);
        const state = head === undefined ? undefined : view.chainStates.get(head);
        if (head === undefined || state === undefined) continue;
        const total = totalStake(state.stakes);
        let mine = 0;
        for (const a of attackers) mine += state.stakes.get(a) ?? 0;
        const ratio = total === 0 ? 0 : mine / total;
        if (best.validator === undefined || ratio > best.ratio) {
          best = { kind: "attacker-stake-ratio", holds: false, ratio, validator: v, head };
        }
      }
      return { ...best, holds: best.ratio >= goal.threshold };
    }
  }
}

/** ある段は、その一つ前の段が達成されるまで pending、判定中は active、
 * 初めて成立したスロットから achieved となる。 */
export type StageStatus = "pending" | "active" | "achieved";

/** ある段の、あるスロットにおける判定結果。 */
export interface StageVerdict {
  readonly stage: number;
  readonly status: StageStatus;
  readonly evidence: GoalEvidence;
  /** 達成された場合、その段が達成されたスロット。 */
  readonly achievedAt?: SlotIndex;
}

/** `trace[slot][stage]`: history の各スロットにおける各段の判定。 */
export type GoalTrace = readonly (readonly StageVerdict[])[];

/**
 * history 全体にわたって 攻撃目標を段ごとに判定する: 段 0 はスロット 0 から
 * 判定され、段 i + 1 は段 i が達成されたスロットから判定される(同じス
 * ロットで複数の段が達成されることもある)。すべての段の証拠がすべての
 * スロットで報告されるので、pending の段の指標も判定に入る前から見える。
 */
export function evaluateGoal(
  goal: readonly AttackGoal[],
  history: readonly GodView[],
  attackers: readonly ValidatorIndex[],
  config: InitialConditions,
): GoalTrace {
  if (goal.length === 0) throw new Error("an attack goal must have at least one stage");
  const achievedAt: (SlotIndex | undefined)[] = goal.map(() => undefined);
  return history.map((view, at) =>
    goal.map((predicate, stage) => {
      const evidence = evaluatePredicate(predicate, history, at, attackers, config);
      const previous = stage === 0 ? 0 : achievedAt[stage - 1];
      if (achievedAt[stage] === undefined && previous !== undefined && evidence.holds) {
        achievedAt[stage] = view.slot;
      }
      const done = achievedAt[stage];
      const status: StageStatus =
        done !== undefined ? "achieved" : previous !== undefined ? "active" : "pending";
      return {
        stage,
        status,
        evidence,
        ...(done === undefined ? {} : { achievedAt: done }),
      };
    }),
  );
}

/** 攻撃目標全体 — その最後の段 — が達成されたスロット(あれば)。 */
export function goalAchievedAt(trace: GoalTrace): SlotIndex | undefined {
  const last = trace[trace.length - 1];
  const final = last?.[last.length - 1];
  return final?.achievedAt;
}
