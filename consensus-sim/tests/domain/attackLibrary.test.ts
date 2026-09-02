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

  it("the boost-sensitive Ex-Ante reorg (A01) misses under the merge preset (成功条件 19)", () => {
    const a01 = ATTACK_LIBRARY.find((a) => a.id === "A01")!;
    // Under its phase0 premise the reorg lands…
    expect(goalAchievedAt(runScenario(scenarioFor(a01), a01.defaultRun.throughSlot).goal!)).toBeTypeOf(
      "number",
    );
    // …but with the overrides removed (the merge preset, boost on) it does not.
    const merged = runScenario(scenarioFor(a01, PRESETS.merge), a01.defaultRun.throughSlot);
    expect(goalAchievedAt(merged.goal!)).toBeUndefined();
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
