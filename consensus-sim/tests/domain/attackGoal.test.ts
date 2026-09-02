// Attack goal predicates (攻撃目標述語, 必須 19): safety violation, liveness
// stall (L), reorg (k) and attacker stake ratio (θ), evaluated from the god
// view at every slot boundary, with the evidence each verdict rests on; and
// the staged judgment of a goal sequence — a stage is judged only after the
// stage before it is achieved, the goal once the last stage is.

import { describe, expect, it } from "vitest";
import {
  DEFAULT_PARAMS,
  addBlock,
  chainStatesOf,
  createBlockTree,
  equalStakes,
  evaluatePredicate,
  goalAchievedAt,
  latestFinalized,
  runScenario,
  scenarioStates,
  type Attack,
  type AttackGoal,
  type AttackInstance,
  type Block,
  type GodView,
  type Intervention,
  type Scenario,
  type SimulationConfig,
  type Vote,
} from "../../src/domain";

const CONFIG: SimulationConfig = {
  validatorCount: 4,
  seed: 0,
  params: DEFAULT_PARAMS,
  initialStakes: equalStakes(4),
};

const scenario = (
  interventions: Intervention[],
  config: SimulationConfig = CONFIG,
): Scenario => ({ config, interventions });

const history = (s: Scenario, through: number): GodView[] => scenarioStates(s, through);

const at = (
  goal: AttackGoal,
  h: readonly GodView[],
  slot: number,
  attackers: number[] = [0],
  config: SimulationConfig = CONFIG,
) => evaluatePredicate(goal, h, slot, attackers, config);

describe("safety violation (安全性違反)", () => {
  // Two branches off the anchor, each finalizing its own epoch-1 checkpoint
  // from the votes its blocks include: {0,1,2} finalize B1 on branch A,
  // {1,2,3} finalize B4 on branch B (75% of the stake each side).
  const vote = (validator: number, slot: number, head: number, source: number, target: number): Vote =>
    ({ validator, slot, head, source, target });
  const block = (index: number, parent: number, slot: number, proposer: number, votes: Vote[]): Block =>
    ({ index, parent, slot, proposer, body: { votes, evidence: [] } });
  const linkVotes = (voters: number[], slot: number, head: number, source: number, target: number) =>
    voters.map((v) => vote(v, slot, head, source, target));

  const conflicting = (): GodView => {
    let tree = createBlockTree();
    for (const b of [
      block(1, 0, 4, 1, []),
      block(2, 1, 8, 2, linkVotes([0, 1, 2], 5, 1, 0, 1)),
      block(3, 2, 9, 3, linkVotes([0, 1, 2], 8, 2, 1, 2)),
      block(4, 0, 4, 0, []),
      block(5, 4, 8, 1, linkVotes([1, 2, 3], 5, 4, 0, 4)),
      block(6, 5, 9, 2, linkVotes([1, 2, 3], 8, 5, 4, 5)),
    ]) {
      tree = addBlock(tree, b);
    }
    const chainStates = chainStatesOf(tree, CONFIG);
    return { slot: 9, tree, chainStates, heads: new Map([[0, 3], [1, 3], [2, 6], [3, 6]]) };
  };

  it("holds when two finalized checkpoints are in conflict, naming them", () => {
    const view = conflicting();
    expect(view.chainStates.get(3)!.finalized).toBe(1);
    expect(view.chainStates.get(6)!.finalized).toBe(4);
    expect(at({ kind: "safety-violation" }, [view], 0)).toEqual({
      kind: "safety-violation",
      holds: true,
      conflicting: [1, 4],
    });
  });

  it("does not hold on an honest run, where every finalized checkpoint lies on one chain", () => {
    const h = history(scenario([]), 13);
    expect(latestFinalized(h[13]!.tree, h[13]!.chainStates)).not.toBe(0);
    for (let s = 0; s <= 13; s++) {
      expect(at({ kind: "safety-violation" }, h, s)).toEqual({ kind: "safety-violation", holds: false });
    }
  });
});

describe("liveness stall (活性停止)", () => {
  it("measures the slots since finalized last advanced on any branch", () => {
    const h = history(scenario([]), 16);
    const finalizedAt = (s: number) => latestFinalized(h[s]!.tree, h[s]!.chainStates);
    let lastAdvance = 0;
    for (let s = 0; s <= 16; s++) {
      if (s > 0 && finalizedAt(s) !== finalizedAt(s - 1)) lastAdvance = s;
      expect(at({ kind: "liveness-stall", slots: 100 }, h, s)).toEqual({
        kind: "liveness-stall",
        holds: false,
        finalized: finalizedAt(s),
        stalledSlots: s - lastAdvance,
      });
    }
    // Finality does advance on an honest run: the stall never exceeds the
    // start-up plus one epoch.
    const stalls = h.map((_, s) => at({ kind: "liveness-stall", slots: 100 }, h, s));
    expect(Math.max(...stalls.map((e) => (e.kind === "liveness-stall" ? e.stalledSlots : 0)))).toBeLessThan(
      12,
    );
    expect(finalizedAt(16)).not.toBe(finalizedAt(8));
  });

  it("holds from the L-th stalled slot on when half the validators fall silent, and releases once finality resumes", () => {
    const stalled = scenario([{ kind: "stop", fromSlot: 1, toSlot: 12, validators: [2, 3] }]);
    const h = history(stalled, 28);
    const L = 10;
    for (let s = 0; s < L; s++) expect(at({ kind: "liveness-stall", slots: L }, h, s).holds).toBe(false);
    for (let s = L; s <= 12; s++) {
      expect(at({ kind: "liveness-stall", slots: L }, h, s)).toEqual({
        kind: "liveness-stall",
        holds: true,
        finalized: 0,
        stalledSlots: s,
      });
    }
    // After the return at slot 13 finality catches up and the stall count resets.
    const late = at({ kind: "liveness-stall", slots: L }, h, 28);
    expect(late.kind === "liveness-stall" && late.finalized).not.toBe(0);
    expect(late.holds).toBe(false);
  });
});

describe("reorg (リオーグ)", () => {
  // Honest B1 (s1) – B2 (s2); at slot 3 the proposer forks the anchor (B3)
  // and every validator is steered to vote B3: heads move B2 → B3, a block
  // that does not descend from B2.
  const reorged = scenario([
    { kind: "propose-parent", slot: 3, parent: 0 },
    ...[0, 1, 2, 3].map((v): Intervention => ({ kind: "vote-target", slot: 3, validator: v, head: 3 })),
  ]);

  it("counts a head move to a non-descendant once per honest validator, and holds at k", () => {
    const h = history(reorged, 5);
    expect(h[2]!.heads.get(1)).toBe(2);
    expect(h[3]!.heads.get(1)).toBe(3);
    expect(at({ kind: "reorg", count: 1 }, h, 2, [0])).toEqual({ kind: "reorg", holds: false, count: 0 });
    expect(at({ kind: "reorg", count: 1 }, h, 3, [0])).toEqual({
      kind: "reorg",
      holds: true,
      count: 1,
      latest: { validator: 1, slot: 3, from: 2, to: 3 },
    });
    // The count is cumulative and k = 2 is not reached by one event.
    expect(at({ kind: "reorg", count: 2 }, h, 5, [0]).holds).toBe(false);
    expect(at({ kind: "reorg", count: 1 }, h, 5, [0]).holds).toBe(true);
  });

  it("ignores the attackers' own heads and never fires on an honest run", () => {
    const h = history(reorged, 4);
    // With everyone but validator 0 an attacker, only validator 0's head counts.
    const e = at({ kind: "reorg", count: 1 }, h, 3, [1, 2, 3]);
    expect(e).toEqual({ kind: "reorg", holds: true, count: 1, latest: { validator: 0, slot: 3, from: 2, to: 3 } });
    const honest = history(scenario([]), 12);
    for (let s = 0; s <= 12; s++) {
      expect(at({ kind: "reorg", count: 1 }, honest, s).holds).toBe(false);
    }
  });
});

describe("attacker stake ratio (攻撃者ステーク比率)", () => {
  it("reads the attackers' share in the chain state of an honest head", () => {
    const h = history(scenario([]), 2);
    expect(at({ kind: "attacker-stake-ratio", threshold: 1 / 3 }, h, 2, [0])).toEqual({
      kind: "attacker-stake-ratio",
      holds: false,
      ratio: 0.25,
      validator: 1,
      head: 2,
    });
    expect(at({ kind: "attacker-stake-ratio", threshold: 0.5 }, h, 2, [0, 1]).holds).toBe(true);
    const skewed = { ...CONFIG, initialStakes: [64, 32, 32, 32] };
    const hs = history(scenario([], skewed), 1);
    expect(at({ kind: "attacker-stake-ratio", threshold: 1 / 3 }, hs, 0, [0], skewed)).toEqual({
      kind: "attacker-stake-ratio",
      holds: true,
      ratio: 0.4,
      validator: 1,
      head: 0,
    });
  });

  it("follows the branch: a penalty included on the honest head's branch changes the ratio", () => {
    // Attacker 1 double-votes at slot 2; the evidence is included at slot 3
    // and slashing zeroes its stake on that branch.
    const h = history(scenario([{ kind: "double-vote", slot: 2, validator: 1 }]), 4);
    expect(at({ kind: "attacker-stake-ratio", threshold: 0.2 }, h, 2, [1]).holds).toBe(true);
    const after = at({ kind: "attacker-stake-ratio", threshold: 0.2 }, h, 4, [1]);
    expect(after.kind === "attacker-stake-ratio" && after.ratio).toBe(0);
    expect(after.holds).toBe(false);
  });
});

describe("staged judgment (段階ごとの判定)", () => {
  const attackOf = (goal: AttackGoal[]): Attack => ({
    attackers: { kind: "count", atLeast: 1 },
    goal,
    strategy: () => [],
  });
  const instance = (goal: AttackGoal[], attackers: number[]): AttackInstance => ({
    id: "t",
    attack: attackOf(goal),
    attackers,
    params: { maxDelay: 1 },
  });

  it("judges stage i + 1 only from the slot stage i is achieved at, and the goal at the last stage", () => {
    const reorgThenStall: AttackGoal[] = [
      { kind: "reorg", count: 1 },
      { kind: "liveness-stall", slots: 6 },
    ];
    const s: Scenario = {
      config: CONFIG,
      interventions: [
        { kind: "propose-parent", slot: 3, parent: 0 },
        ...[1, 2, 3].map((v): Intervention => ({ kind: "vote-target", slot: 3, validator: v, head: 3 })),
      ],
      attack: instance(reorgThenStall, [0]),
    };
    const run = runScenario(s, 8);
    const trace = run.goal!;
    expect(trace).toHaveLength(9);
    // Stage 0 is active from slot 0 and achieved at slot 3.
    expect(trace[0]![0]!.status).toBe("active");
    expect(trace[2]![0]!.status).toBe("active");
    expect(trace[3]![0]).toMatchObject({ status: "achieved", achievedAt: 3 });
    expect(trace[8]![0]).toMatchObject({ status: "achieved", achievedAt: 3 });
    // Stage 1 is pending until then — its measure is still reported — and
    // active from slot 3; the stall of 6 slots is reached at slot 6.
    expect(trace[2]![1]).toMatchObject({ status: "pending", evidence: { kind: "liveness-stall", stalledSlots: 2 } });
    expect(trace[3]![1]!.status).toBe("active");
    expect(trace[5]![1]!.status).toBe("active");
    expect(trace[6]![1]).toMatchObject({ status: "achieved", achievedAt: 6 });
    expect(goalAchievedAt(trace)).toBe(6);
    expect(goalAchievedAt(runScenario(s, 5).goal!)).toBeUndefined();
  });

  it("keeps a later stage pending while the first is never achieved, and achieves both in one slot when both hold", () => {
    const ratioThenSafety: AttackGoal[] = [
      { kind: "attacker-stake-ratio", threshold: 1 / 3 },
      { kind: "safety-violation" },
    ];
    const never = runScenario({ config: CONFIG, interventions: [], attack: instance(ratioThenSafety, [0]) }, 6);
    for (const verdicts of never.goal!) {
      expect(verdicts[0]!.status).toBe("active");
      expect(verdicts[1]!.status).toBe("pending");
    }
    expect(goalAchievedAt(never.goal!)).toBeUndefined();

    const skewed = { ...CONFIG, initialStakes: [64, 32, 32, 32] };
    const stallTwice: AttackGoal[] = [
      { kind: "attacker-stake-ratio", threshold: 1 / 3 },
      { kind: "liveness-stall", slots: 0 },
    ];
    const both = runScenario({ config: skewed, interventions: [], attack: instance(stallTwice, [0]) }, 2);
    expect(both.goal![0]!.map((v) => v.status)).toEqual(["achieved", "achieved"]);
    expect(goalAchievedAt(both.goal!)).toBe(0);
    // A scenario without an attack carries no trace.
    expect(runScenario(scenario([]), 2).goal).toBeUndefined();
  });
});
