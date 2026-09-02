// Attack library (攻撃ライブラリ) — every library attack reaches its goal under
// its declared premise and default run (成功条件 19), the boost-sensitive
// reorgs (A01) miss under the merge preset with the overrides removed, and a
// saved attack round-trips through the codec and replays identically (成功条件 20).

import { describe, expect, it } from "vitest";
import {
  ATTACK_LIBRARY,
  ATTACK_REGISTRY,
  PRESETS,
  goalAchievedAt,
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
    seed: 0,
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

  it("the mitigation-sensitive attacks (A01, A07) miss under the merge preset (成功条件 19)", () => {
    for (const id of ["A01", "A07"]) {
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
