// Attack goal (攻撃目標) — the observable predicates an attack is judged by
// (必須 19), and their evaluation. A goal is a non-empty sequence of
// predicates evaluated from the god view (神視点: every published block and
// vote, and each branch's chain state) at every slot boundary, stage by
// stage from the first: a stage is judged only once the stage before it has
// been achieved, and the goal is achieved once the last stage is. Every
// verdict carries its evidence, so the trace can show why a stage holds or
// does not at each slot.

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
 * - 安全性違反: two checkpoints of the published block tree, neither an
 *   ancestor of the other, each finalized in the chain state of its own
 *   branch.
 * - 活性停止: on no branch of the published tree has finalized advanced
 *   during the last `slots` slots (L).
 * - リオーグ: an honest validator's head moving to a block that does not
 *   descend from its previous slot's head counts one event; some honest
 *   validator accumulates `count` events (k, default 1).
 * - 攻撃者ステーク比率: in the chain state of some honest validator's head,
 *   the attackers' total stake ÷ everyone's total stake reaches `threshold` (θ).
 */
export type AttackGoal =
  | { readonly kind: "safety-violation" }
  | { readonly kind: "liveness-stall"; readonly slots: number }
  | { readonly kind: "reorg"; readonly count: number }
  | { readonly kind: "attacker-stake-ratio"; readonly threshold: number };

/** The default k of the reorg predicate. */
export const DEFAULT_REORG_COUNT = 1;

/** The god view at the end of a slot, as the predicates read it: every
 * published block with its chain state, and every validator's head. */
export interface GodView {
  readonly slot: SlotIndex;
  readonly tree: BlockTree;
  readonly chainStates: ChainStateIndex;
  readonly heads: ReadonlyMap<ValidatorIndex, BlockIndex>;
}

/** Why a predicate holds or does not at a slot. */
export type GoalEvidence =
  | {
      readonly kind: "safety-violation";
      readonly holds: boolean;
      /** Two finalized checkpoints in conflict, when there are any. */
      readonly conflicting?: readonly [BlockIndex, BlockIndex];
    }
  | {
      readonly kind: "liveness-stall";
      readonly holds: boolean;
      /** The latest finalized checkpoint of the god view. */
      readonly finalized: Checkpoint;
      /** Slots since it last advanced (the anchor counts as finalized at slot 0). */
      readonly stalledSlots: number;
    }
  | {
      readonly kind: "reorg";
      readonly holds: boolean;
      /** The largest cumulative event count over the honest validators. */
      readonly count: number;
      /** The most recent event so far (the lowest validator index at that slot). */
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
      /** The largest ratio over the honest validators' heads. */
      readonly ratio: number;
      /** The honest validator (and its head) that ratio is read at. */
      readonly validator?: ValidatorIndex;
      readonly head?: BlockIndex;
    };

const honestValidators = (
  attackers: readonly ValidatorIndex[],
  config: InitialConditions,
): ValidatorIndex[] =>
  validatorIndices(config.validatorCount).filter((v) => !attackers.includes(v));

/**
 * Evaluate one predicate at `history[at]` (`history[i]` is the god view at
 * the end of slot i; the predicates on progress read the slots before).
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

/** A stage is pending until the stage before it is achieved, active while
 * it is being judged, and achieved from the first slot it holds at. */
export type StageStatus = "pending" | "active" | "achieved";

export interface StageVerdict {
  readonly stage: number;
  readonly status: StageStatus;
  readonly evidence: GoalEvidence;
  /** The slot the stage was achieved at, once it is. */
  readonly achievedAt?: SlotIndex;
}

/** `trace[slot][stage]`: every stage's verdict at every slot of the history. */
export type GoalTrace = readonly (readonly StageVerdict[])[];

/**
 * Judge the goal over the whole history, stage by stage: stage 0 is judged
 * from slot 0; stage i + 1 from the slot stage i is achieved at (the same
 * slot may achieve several stages). The evidence of every stage is
 * reported at every slot, so a pending stage's measure is visible before
 * it comes into judgment.
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

/** The slot the whole goal — its last stage — was achieved at, if any. */
export function goalAchievedAt(trace: GoalTrace): SlotIndex | undefined {
  const last = trace[trace.length - 1];
  const final = last?.[last.length - 1];
  return final?.achievedAt;
}
