// Attack goal (攻撃目標) — the observable predicates an attack is judged by
// (必須 19). A goal is a non-empty sequence of predicates, evaluated from the
// god view (神視点: every published block and vote, and each branch's chain
// state) at every slot boundary, stage by stage from the first: the goal is
// achieved once the last stage is. The evaluation itself is attackGoal
// verdicts computed by the simulator over the god view.

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
