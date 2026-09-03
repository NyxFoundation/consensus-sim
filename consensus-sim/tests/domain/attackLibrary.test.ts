// Attack library (攻撃ライブラリ) — every library attack reaches its goal under
// its declared premise and default run (成功条件 19), the mitigation-sensitive
// attacks (A01, A03, A04, A07) miss under the merge preset with the overrides
// removed, and a saved attack round-trips through the codec and replays
// identically (成功条件 20). A05's behaviour under the switching mitigations
// (window / unrealized) is not pinned here: see the inspection record.

import { describe, expect, it } from "vitest";
import {
  ATTACK_LIBRARY,
  ATTACK_REGISTRY,
  PRESETS,
  goalAchievedAt,
  isAncestor,
  latestFinalized,
  parseScenario,
  premiseParams,
  runScenario,
  satisfiesCondition,
  serializeScenario,
  type AttackInstance,
  type LibraryAttack,
  type ProtocolParams,
  type Scenario,
  type SimulationConfig,
} from "../../src/domain";

function configFor(a: LibraryAttack, params: ProtocolParams): SimulationConfig {
  return {
    validatorCount: a.defaultRun.validatorCount,
    seed: a.defaultRun.seed,
    params,
    initialStakes: a.defaultRun.initialStakes,
  };
}

function instanceOf(a: LibraryAttack): AttackInstance {
  return {
    id: a.id,
    attack: { attackers: a.attackers, goal: a.goal, strategy: a.strategy },
    attackers: a.defaultRun.attackers,
    params: a.defaultRun.params,
  };
}

function scenarioFor(a: LibraryAttack, params = premiseParams(a.premise)): Scenario {
  return { config: configFor(a, params), interventions: [], attack: instanceOf(a) };
}

describe("attack library", () => {
  it("every attack reaches its goal under its default run (成功条件 19)", () => {
    for (const a of ATTACK_LIBRARY) {
      const achieved = goalAchievedAt(runScenario(scenarioFor(a), a.defaultRun.throughSlot).goal!);
      expect(achieved, `${a.id} never achieves its goal`).toBeTypeOf("number");
    }
  });

  it("every default run satisfies the attacker-set condition", () => {
    for (const a of ATTACK_LIBRARY) {
      expect(
        satisfiesCondition(a.attackers, a.defaultRun.attackers, configFor(a, premiseParams(a.premise))),
        `${a.id} default run violates its attacker condition`,
      ).toBe(true);
    }
  });

  it("the mitigation-sensitive attacks (A01, A03, A04, A07) miss under the merge preset (成功条件 19)", () => {
    for (const id of ["A01", "A03", "A04", "A07"]) {
      const a = ATTACK_LIBRARY.find((x) => x.id === id)!;
      // Under its declared premise the goal is reached…
      expect(goalAchievedAt(runScenario(scenarioFor(a), a.defaultRun.throughSlot).goal!)).toBeTypeOf(
        "number",
      );
      // …but with the overrides removed (the merge preset) it is not.
      const merged = runScenario(scenarioFor(a, PRESETS.merge), a.defaultRun.throughSlot);
      expect(goalAchievedAt(merged.goal!), `${id} reaches its goal under merge`).toBeUndefined();
    }
  });

  it("the avalanche (A07) is stopped by the fork-choice rule alone: phase0 with LMD-GHOST", () => {
    const a07 = ATTACK_LIBRARY.find((a) => a.id === "A07")!;
    expect(premiseParams(a07.premise).forkChoice).toBe("GHOST");
    const lmd = runScenario(scenarioFor(a07, PRESETS.phase0), a07.defaultRun.throughSlot);
    expect(goalAchievedAt(lmd.goal!)).toBeUndefined();
  });

  it("the balancing attacks (A03, A04) keep two honest camps on two branches with nothing justified", () => {
    for (const id of ["A03", "A04"]) {
      const a = ATTACK_LIBRARY.find((x) => x.id === id)!;
      const run = runScenario(scenarioFor(a), a.defaultRun.throughSlot);
      const last = run.states[run.states.length - 1]!;
      // Branch A is rooted at the attacker's slot-1 block B1, branch B at the
      // honest slot-2 block B2 built beside it; camp {0, 4} stays on A and
      // camp {2, 3} on B through the whole run.
      expect(last.tree.blocks.get(2)!.parent).toBe(0);
      for (const v of [0, 4]) expect(isAncestor(last.tree, 1, last.heads.get(v)!)).toBe(true);
      for (const v of [2, 3]) expect(isAncestor(last.tree, 2, last.heads.get(v)!)).toBe(true);
      for (const state of last.chainStates.values()) expect(state.justified).toBe(0);
      expect(run.generated.every((g) => g.discarded === undefined)).toBe(true);
    }
  });

  it("the LMD balancing (A04) is broken by the equivocation discount alone", () => {
    const a04 = ATTACK_LIBRARY.find((a) => a.id === "A04")!;
    expect(premiseParams(a04.premise).equivocationDiscount).toBe(false);
    const discounted = { ...premiseParams(a04.premise), equivocationDiscount: true };
    const run = runScenario(scenarioFor(a04, discounted), a04.defaultRun.throughSlot);
    expect(goalAchievedAt(run.goal!)).toBeUndefined();
    // Every honest validator ends on the same branch (the attacker's head is
    // its own still-withheld block).
    const last = run.states[run.states.length - 1]!;
    expect(new Set([0, 2, 3, 4].map((v) => last.heads.get(v))).size).toBe(1);
  });

  it("the finality delay (A06) splits the epoch-1 targets and defers the first finalization by one epoch", () => {
    const a06 = ATTACK_LIBRARY.find((a) => a.id === "A06")!;
    const run = runScenario(scenarioFor(a06), a06.defaultRun.throughSlot);
    const targets = new Set(run.states[4]!.votes.filter((v) => v.slot === 4).map((v) => v.target));
    expect(targets).toEqual(new Set([3, 4]));
    const firstFinalization = (states: typeof run.states) =>
      states.findIndex((s) => latestFinalized(s.tree, s.chainStates) !== 0);
    expect(firstFinalization(run.states)).toBe(13);
    expect(goalAchievedAt(run.goal!)).toBe(10);
    // The honest run finalizes at slot 9, below the threshold L = 10.
    const { attack: _attack, ...honestScenario } = scenarioFor(a06);
    expect(firstFinalization(runScenario(honestScenario, 16).states)).toBe(9);
  });

  it("the bouncing (A05) alternates the justified checkpoint between two branches and finalizes nothing", () => {
    const a05 = ATTACK_LIBRARY.find((a) => a.id === "A05")!;
    const params = premiseParams(a05.premise);
    expect(params.checkpointSwitch).toBe("off");
    expect(params.committee.kind).toBe("epoch-split");
    const run = runScenario(scenarioFor(a05), 36);
    expect(run.generated.every((g) => g.discarded === undefined)).toBe(true);
    // The two branches fork at the anchor: Y under the attacker's slot-1
    // block B1, X under the honest slot-2 block B2.
    const last = run.states[run.states.length - 1]!;
    expect(last.tree.blocks.get(1)!.parent).toBe(0);
    expect(last.tree.blocks.get(2)!.parent).toBe(0);
    // From the first bounce on, each epoch's justified checkpoint (the
    // highest over the god view) lies on the other branch than the last.
    const highest = (s: (typeof run.states)[number]) =>
      [...s.chainStates.values()].reduce(
        (best, c) => (s.tree.blocks.get(c.justified)!.slot > s.tree.blocks.get(best)!.slot ? c.justified : best),
        0,
      );
    const sequence = [13, 17, 21, 25, 29, 33].map((slot) => highest(run.states[slot]!));
    expect(sequence).toEqual([8, 12, 16, 20, 24, 28]);
    const branchOf = (b: number) => (isAncestor(last.tree, 1, b) ? "Y" : "X");
    expect(sequence.map(branchOf)).toEqual(["X", "Y", "X", "Y", "X", "Y"]);
    // Every state keeps the anchor as the latest finalized block.
    for (const s of run.states) expect(latestFinalized(s.tree, s.chainStates)).toBe(0);
    expect(goalAchievedAt(run.goal!)).toBe(12);
  });

  it("the safety violations (A10, A12) finalize two conflicting checkpoints", () => {
    for (const id of ["A10", "A12"]) {
      const a = ATTACK_LIBRARY.find((x) => x.id === id)!;
      const run = runScenario(scenarioFor(a), a.defaultRun.throughSlot);
      const at = goalAchievedAt(run.goal!)!;
      const evidence = run.goal![at]![0]!.evidence;
      expect(evidence.kind).toBe("safety-violation");
      if (evidence.kind !== "safety-violation") throw new Error("unreachable");
      expect(evidence.conflicting, `${id} reports no conflicting pair`).toBeDefined();
      // The strategy never trips slashing: no evidence is included anywhere.
      const last = run.states[run.states.length - 1]!;
      for (const block of last.tree.blocks.values()) expect(block.body.evidence).toEqual([]);
    }
  });

  it("the leak amplification (A14) reaches its two stages in order", () => {
    const a14 = ATTACK_LIBRARY.find((a) => a.id === "A14")!;
    const run = runScenario(scenarioFor(a14), a14.defaultRun.throughSlot);
    const final = run.goal![run.goal!.length - 1]!;
    const [ratio, safety] = final as [(typeof final)[number], (typeof final)[number]];
    expect(ratio.status).toBe("achieved");
    expect(safety.status).toBe("achieved");
    expect(ratio.achievedAt!).toBeLessThan(safety.achievedAt!);
    // Before the first stage holds, the second is not judged.
    expect(run.goal![ratio.achievedAt! - 1]![1]!.status).toBe("pending");
    // The attacker never leaks: its stake is intact on the isolated branch.
    const evidence = run.goal![ratio.achievedAt!]![0]!.evidence;
    if (evidence.kind !== "attacker-stake-ratio") throw new Error("unreachable");
    const head = run.states[ratio.achievedAt!]!.chainStates.get(evidence.head!)!;
    expect(head.stakes.get(3)).toBe(32);
    expect(head.stakes.get(1)!).toBeLessThan(32);
  });

  it("resolves and replays a saved attack through the registry (成功条件 20)", () => {
    for (const a of ATTACK_LIBRARY) {
      const scenario = scenarioFor(a);
      const wire = JSON.parse(JSON.stringify(serializeScenario(scenario, a.defaultRun.throughSlot)));
      const restored = parseScenario(wire, ATTACK_REGISTRY);
      const before = runScenario(scenario, a.defaultRun.throughSlot);
      const after = runScenario(restored.scenario, a.defaultRun.throughSlot);
      expect(goalAchievedAt(after.goal!)).toBe(goalAchievedAt(before.goal!));
      expect(after.generated).toEqual(before.generated);
    }
  });

  it("keeps the registry in step with the library", () => {
    expect([...ATTACK_REGISTRY.keys()].sort()).toEqual(ATTACK_LIBRARY.map((a) => a.id).sort());
  });
});
