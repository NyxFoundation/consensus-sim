// Scenario (de)serialization: round-trips preserve the run's identity
// (proved by comparing recomputed states), and parsing rejects every
// structural violation — unknown kinds, out-of-range validators, bad slots —
// so a loaded scenario is exactly as trustworthy as a built one.

import { describe, expect, it } from "vitest";
import {
  DEFAULT_PARAMS,
  PRESETS,
  equalStakes,
  parseScenario,
  runScenario,
  scenarioStates,
  serializeScenario,
  SCENARIO_FORMAT,
  SCENARIO_VERSION,
  type Action,
  type Attack,
  type AttackRegistry,
  type Intervention,
  type Scenario,
} from "../../src/domain";

const ALL_KINDS: Intervention[] = [
  { kind: "partition", fromSlot: 2, toSlot: 6, groups: [[0, 1]] },
  { kind: "partition", fromSlot: 9, groups: [[0], [1, 2]] },
  { kind: "stop", fromSlot: 3, toSlot: 4, validators: [2] },
  { kind: "offline", fromSlot: 7, toSlot: 8, validators: [3] },
  { kind: "propose-parent", slot: 5, parent: 1 },
  { kind: "double-propose", slot: 5, validator: 1 },
  { kind: "double-vote", slot: 6, validator: 3 },
  { kind: "delay", message: { kind: "block", block: 2 }, untilSlot: 4 },
  {
    kind: "drop",
    message: { kind: "vote", validator: 1, slot: 2, head: 2 },
    observers: [0, 3],
  },
  { kind: "vote-target", slot: 7, validator: 2, head: 3, source: 0 },
  {
    kind: "omit-inclusion",
    slot: 8,
    votes: [{ kind: "vote", validator: 0, slot: 7, head: 7 }],
    evidence: [{ kind: "double-vote", validator: 3, slot: 6 }],
  },
];

const SCENARIO: Scenario = {
  config: {
    validatorCount: 4,
    seed: 7,
    params: { ...PRESETS.phase0, committee: { kind: "sized", size: 3 } },
    initialStakes: [32, 48, 16, 32],
  },
  interventions: ALL_KINDS,
};

describe("scenario round-trip", () => {
  it("serialize → parse preserves config, runSlot and every intervention kind", () => {
    const parsed = parseScenario(
      JSON.parse(JSON.stringify(serializeScenario(SCENARIO, 12))),
    );
    expect(parsed.runSlot).toBe(12);
    expect(parsed.scenario.config).toEqual(SCENARIO.config);
    expect(parsed.scenario.interventions).toEqual(ALL_KINDS);
  });

  it("a round-tripped scenario recomputes the identical run (再実行の同一性)", () => {
    const parsed = parseScenario(serializeScenario(SCENARIO, 10));
    const original = scenarioStates(SCENARIO, 10);
    const replayed = scenarioStates(parsed.scenario, parsed.runSlot);
    expect(replayed).toHaveLength(original.length);
    for (let i = 0; i < original.length; i++) {
      expect(replayed[i]?.votes).toEqual(original[i]?.votes);
      expect([...(replayed[i]?.heads ?? [])]).toEqual([
        ...(original[i]?.heads ?? []),
      ]);
      expect(replayed[i]?.chainStates).toEqual(original[i]?.chainStates);
      expect(replayed[i]?.tree.blocks.size).toBe(original[i]?.tree.blocks.size);
    }
  });

  it("carries the format tag and version", () => {
    const data = serializeScenario(SCENARIO, 3);
    expect(data.format).toBe(SCENARIO_FORMAT);
    expect(data.version).toBe(SCENARIO_VERSION);
  });
});

describe("parse rejection", () => {
  const valid = () =>
    JSON.parse(JSON.stringify(serializeScenario(SCENARIO, 5)));

  it.each([
    ["not an object", 42],
    ["wrong format", { ...valid(), format: "other" }],
    ["wrong version", { ...valid(), version: 999 }],
    ["missing config", { ...valid(), config: undefined }],
    ["validatorCount out of range", { ...valid(), config: { validatorCount: 3, seed: 0 } }],
    ["non-integer seed", { ...valid(), config: { validatorCount: 4, seed: 0.5 } }],
    ["negative runSlot", { ...valid(), runSlot: -1 }],
    ["interventions not an array", { ...valid(), interventions: {} }],
  ])("rejects %s", (_name, data) => {
    expect(() => parseScenario(data)).toThrow();
  });

  const withParams = (patch: Record<string, unknown>) => {
    const base = valid();
    return {
      ...base,
      config: { ...base.config, params: { ...base.config.params, ...patch } },
    };
  };

  it.each([
    ["boost above 1", { boost: 1.5 }],
    ["negative boost", { boost: -0.1 }],
    ["unknown fork choice rule", { forkChoice: "PBFT" }],
    ["unknown checkpoint switch", { checkpointSwitch: "sometimes" }],
    ["non-boolean slashing", { slashing: "on" }],
    ["committee of unknown kind", { committee: { kind: "random" } }],
    ["committee larger than the validator set", { committee: { kind: "sized", size: 5 } }],
    ["empty committee", { committee: { kind: "sized", size: 0 } }],
    ["leak without delay", { inactivityLeak: { enabled: true, delayEpochs: 0, rate: 0.25 } }],
    ["leak rate above 1", { inactivityLeak: { enabled: true, delayEpochs: 4, rate: 2 } }],
  ])("rejects protocol params with %s", (_name, patch) => {
    expect(() => parseScenario(withParams(patch))).toThrow();
  });

  it("defaults absent protocol params to the merge preset (pre-parameter scenarios)", () => {
    const base = valid();
    const { params: _dropped, ...config } = base.config;
    const parsed = parseScenario({ ...base, config });
    expect(parsed.scenario.config.params).toEqual(DEFAULT_PARAMS);
  });

  const withStakes = (initialStakes: unknown) => {
    const base = valid();
    return { ...base, config: { ...base.config, initialStakes } };
  };

  it.each([
    ["too few stakes", [32, 32, 32]],
    ["too many stakes", [32, 32, 32, 32, 32]],
    ["a zero stake", [32, 0, 32, 32]],
    ["a negative stake", [32, -1, 32, 32]],
    ["a fractional stake", [32, 1.5, 32, 32]],
    ["stakes not an array", { 0: 32 }],
  ])("rejects initial stakes with %s", (_name, stakes) => {
    expect(() => parseScenario(withStakes(stakes))).toThrow();
  });

  it("defaults absent initial stakes to equal stakes (pre-stake scenarios)", () => {
    const base = valid();
    const { initialStakes: _dropped, ...config } = base.config;
    const parsed = parseScenario({ ...base, config });
    expect(parsed.scenario.config.initialStakes).toEqual(equalStakes(4));
  });

  const withIntervention = (i: unknown) => ({
    ...valid(),
    interventions: [i],
  });

  it.each([
    ["unknown kind", { kind: "bribe", fromSlot: 1 }],
    ["validator out of range", { kind: "double-vote", slot: 1, validator: 4 }],
    ["negative validator", { kind: "stop", fromSlot: 1, validators: [-1] }],
    ["empty stop validators", { kind: "stop", fromSlot: 1, validators: [] }],
    ["toSlot before fromSlot", { kind: "stop", fromSlot: 5, toSlot: 2, validators: [0] }],
    ["offline toSlot before fromSlot", { kind: "offline", fromSlot: 5, toSlot: 2, validators: [0] }],
    ["empty offline validators", { kind: "offline", fromSlot: 1, validators: [] }],
    ["negative propose-parent parent", { kind: "propose-parent", slot: 2, parent: -1 }],
    ["non-integer propose-parent parent", { kind: "propose-parent", slot: 2, parent: 1.5 }],
    ["duplicate across partition groups", { kind: "partition", fromSlot: 1, groups: [[0, 1], [1]] }],
    ["empty partition groups", { kind: "partition", fromSlot: 1, groups: [] }],
    ["bad message kind", { kind: "drop", message: { kind: "gossip" } }],
    ["non-positive block ref", { kind: "drop", message: { kind: "block", block: 0 } }],
    ["delay without untilSlot", { kind: "delay", message: { kind: "block", block: 1 } }],
    ["empty observers", { kind: "drop", message: { kind: "block", block: 1 }, observers: [] }],
  ])("rejects intervention with %s", (_name, i) => {
    expect(() => parseScenario(withIntervention(i))).toThrow();
  });

  it("accepts a minimal valid document", () => {
    const parsed = parseScenario({
      format: SCENARIO_FORMAT,
      version: SCENARIO_VERSION,
      config: { validatorCount: 4, seed: 0 },
      runSlot: 0,
      interventions: [],
    });
    expect(parsed.scenario.interventions).toHaveLength(0);
    expect(parsed.runSlot).toBe(0);
  });
});

describe("attack in a scenario (高々 1 つの攻撃)", () => {
  const silence: Action = { kind: "stop", fromSlot: 2, toSlot: 3, validators: [1] };
  const attack: Attack = {
    attackers: { kind: "count", atLeast: 1 },
    goal: [{ kind: "liveness-stall", slots: 8 }],
    strategy: (observation) => (observation.slot === 1 ? [silence] : []),
  };
  const registry: AttackRegistry = new Map([["test-attack", attack]]);
  const withAttack: Scenario = {
    ...SCENARIO,
    interventions: [{ kind: "double-vote", slot: 6, validator: 3 }],
    attack: { id: "test-attack", attack, attackers: [1, 2], params: { maxDelay: 2, hold: 1 } },
  };
  const serialized = () => JSON.parse(JSON.stringify(serializeScenario(withAttack, 9)));

  it("saves the attack by id, attacker set and parameters — never the generated actions", () => {
    const data = serialized();
    expect(data.attack).toEqual({
      id: "test-attack",
      attackers: [1, 2],
      params: { maxDelay: 2, hold: 1 },
    });
    expect(Object.keys(data)).not.toContain("generated");
  });

  it("resolves the attack through the registry and replays the same generated actions and states", () => {
    const parsed = parseScenario(serialized(), registry);
    expect(parsed.scenario.attack).toEqual(withAttack.attack);
    const original = runScenario(withAttack, 9);
    const replayed = runScenario(parsed.scenario, 9);
    expect(replayed.generated).toEqual(original.generated);
    expect(replayed.generated).toEqual([{ action: silence, generatedAt: 1 }]);
    replayed.states.forEach((state, slot) => {
      const o = original.states[slot]!;
      expect([...state.heads.entries()]).toEqual([...o.heads.entries()]);
      expect(state.votes).toEqual(o.votes);
      expect(state.tree.blocks.size).toBe(o.tree.blocks.size);
    });
  });

  it("round-trips ahead-of-publication message references (proposal / attestation)", () => {
    const ahead: Intervention[] = [
      { kind: "delay", message: { kind: "proposal", proposer: 1, slot: 5 }, untilSlot: 6 },
      { kind: "drop", message: { kind: "attestation", validator: 2, slot: 5 }, observers: [0] },
      { kind: "omit-inclusion", slot: 8, votes: [{ kind: "attestation", validator: 0, slot: 7 }] },
    ];
    const parsed = parseScenario(
      JSON.parse(JSON.stringify(serializeScenario({ ...SCENARIO, interventions: ahead }, 3))),
    );
    expect(parsed.scenario.interventions).toEqual(ahead);
  });

  it.each([
    ["an unknown attack id", { id: "no-such-attack", attackers: [1], params: { maxDelay: 1 } }],
    ["an empty attacker set", { id: "test-attack", attackers: [], params: { maxDelay: 1 } }],
    ["a duplicate attacker", { id: "test-attack", attackers: [1, 1], params: { maxDelay: 1 } }],
    ["an attacker out of range", { id: "test-attack", attackers: [4], params: { maxDelay: 1 } }],
    ["params without maxDelay", { id: "test-attack", attackers: [1], params: { hold: 1 } }],
    ["a negative maxDelay", { id: "test-attack", attackers: [1], params: { maxDelay: -1 } }],
    ["a non-numeric parameter", { id: "test-attack", attackers: [1], params: { maxDelay: 1, hold: "x" } }],
    ["a non-string id", { id: 7, attackers: [1], params: { maxDelay: 1 } }],
  ])("rejects an attack with %s", (_name, attackData) => {
    expect(() => parseScenario({ ...serialized(), attack: attackData }, registry)).toThrow();
  });

  it("rejects a saved attack when no registry resolves it", () => {
    expect(() => parseScenario(serialized())).toThrow(/unknown/);
  });

  it.each([
    ["a proposal reference with an out-of-range proposer", { kind: "proposal", proposer: 4, slot: 5 }],
    ["an attestation reference without a slot", { kind: "attestation", validator: 1 }],
  ])("rejects %s", (_name, message) => {
    expect(() =>
      parseScenario(withIntervention({ kind: "delay", message, untilSlot: 6 })),
    ).toThrow();
  });

  const withIntervention = (i: unknown) => ({
    ...JSON.parse(JSON.stringify(serializeScenario(SCENARIO, 5))),
    interventions: [i],
  });
});
