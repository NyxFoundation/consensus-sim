// Scenario (de)serialization: round-trips preserve the run's identity
// (proved by comparing recomputed states), and parsing rejects every
// structural violation — unknown kinds, out-of-range validators, bad slots —
// so a loaded scenario is exactly as trustworthy as a built one.

import { describe, expect, it } from "vitest";
import {
  DEFAULT_PARAMS,
  PRESETS,
  parseScenario,
  scenarioStates,
  serializeScenario,
  SCENARIO_FORMAT,
  SCENARIO_VERSION,
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
];

const SCENARIO: Scenario = {
  config: {
    validatorCount: 4,
    seed: 7,
    params: { ...PRESETS.phase0, committee: { kind: "sized", size: 3 } },
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
