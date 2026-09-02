// Vote designation (投票先指定) and omitted inclusion (取り込みの省略),
// 必須対応事項 9: a designated vote is steered to blocks of the voter's own
// view (unspecified components follow the rules), an omitted item stays out
// of the proposer's block but remains includable later, and both survive
// the scenario codec and keep the run deterministic.

import { describe, expect, it } from "vitest";
import {
  DEFAULT_PARAMS,
  equalStakes,
  parseScenario,
  scenarioStates,
  serializeScenario,
  type Intervention,
  type Scenario,
  type Vote,
} from "../../src/domain";

const scenario = (interventions: Intervention[]): Scenario => ({
  config: {
    validatorCount: 4,
    seed: 0,
    params: DEFAULT_PARAMS,
    initialStakes: equalStakes(4),
  },
  interventions,
});

const votesAt = (s: Scenario, slot: number): Vote[] =>
  scenarioStates(s, slot)[slot]!.votes.filter((v) => v.slot === slot);

const bodyAt = (s: Scenario, slot: number) =>
  scenarioStates(s, slot)[slot]!.tree.blocks.get(slot)!.body;

describe("vote designation (投票先指定)", () => {
  // Honest run: B_n at slot n; at slot 6 everyone votes head B6 with
  // source = B4 (justified in ChainState(B5)) and target = B4.
  it("follows the rules when nothing is designated", () => {
    expect(votesAt(scenario([]), 6)).toEqual(
      [0, 1, 2, 3].map((v) => ({ validator: v, slot: 6, head: 6, source: 4, target: 4 })),
    );
  });

  it("steers the head and derives source / target from the designated head's chain", () => {
    const votes = votesAt(scenario([{ kind: "vote-target", slot: 6, validator: 1, head: 3 }]), 6);
    // B3's chain state has nothing justified; epoch 1's checkpoint on that
    // chain is B3 itself (the last block at or before slot 4).
    expect(votes[1]).toEqual({ validator: 1, slot: 6, head: 3, source: 0, target: 3 });
    expect(votes.filter((v) => v.validator !== 1).map((v) => v.head)).toEqual([6, 6, 6]);
  });

  it("applies an explicit source / target on top of the rules", () => {
    const votes = votesAt(
      scenario([{ kind: "vote-target", slot: 6, validator: 2, source: 0, target: 5 }]),
      6,
    );
    expect(votes[2]).toEqual({ validator: 2, slot: 6, head: 6, source: 0, target: 5 });
  });

  it("ignores a designated block the voter's view does not hold", () => {
    const s = scenario([
      { kind: "vote-target", slot: 6, validator: 1, head: 99, target: 2 },
      // B2 is dropped for ボブ, so target B2 is unknown to it while B99 never exists.
      { kind: "drop", message: { kind: "block", block: 2 }, observers: [1] },
    ]);
    const honest = scenario([{ kind: "drop", message: { kind: "block", block: 2 }, observers: [1] }]);
    expect(votesAt(s, 6)).toEqual(votesAt(honest, 6));
  });

  it("is silenced by a stop, and the designated vote is included like any other", () => {
    const stopped = scenario([
      { kind: "vote-target", slot: 6, validator: 1, head: 3 },
      { kind: "stop", fromSlot: 6, toSlot: 6, validators: [1] },
    ]);
    expect(votesAt(stopped, 6).map((v) => v.validator)).toEqual([0, 2, 3]);
    const steered = scenario([{ kind: "vote-target", slot: 6, validator: 1, head: 3 }]);
    expect(bodyAt(steered, 7).votes).toContainEqual({
      validator: 1,
      slot: 6,
      head: 3,
      source: 0,
      target: 3,
    });
  });
});

describe("omitted inclusion (取り込みの省略)", () => {
  const aliceAt2 = { kind: "vote", validator: 0, slot: 2, head: 2 } as const;

  it("leaves the named vote out of the proposer's block; a later block includes it", () => {
    const s = scenario([{ kind: "omit-inclusion", slot: 3, votes: [aliceAt2] }]);
    const b3 = bodyAt(s, 3);
    expect(b3.votes.map((v) => v.validator)).toEqual([1, 2, 3]);
    const b4 = bodyAt(s, 4);
    expect(b4.votes).toContainEqual({ validator: 0, slot: 2, head: 2, source: 0, target: 0 });
    expect(b4.votes).toHaveLength(5);
    // Honest B3 carries all four slot-2 votes.
    expect(bodyAt(scenario([]), 3).votes).toHaveLength(4);
  });

  it("leaves the named evidence out, so slashing waits for the block that carries it", () => {
    const withEvidence: Intervention[] = [{ kind: "double-vote", slot: 2, validator: 1 }];
    const omitted = scenario([
      ...withEvidence,
      { kind: "omit-inclusion", slot: 3, evidence: [{ kind: "double-vote", validator: 1, slot: 2 }] },
    ]);
    expect(bodyAt(scenario(withEvidence), 3).evidence).toHaveLength(1);
    expect(bodyAt(omitted, 3).evidence).toHaveLength(0);
    expect(bodyAt(omitted, 4).evidence).toHaveLength(1);
    const states = scenarioStates(omitted, 4);
    expect(states[4]!.chainStates.get(3)!.stakes.get(1)).toBe(32);
    expect(states[4]!.chainStates.get(4)!.stakes.get(1)).toBe(0);
  });

  it("does nothing for a slot whose proposer is stopped, and keeps the run deterministic", () => {
    const s = scenario([
      { kind: "omit-inclusion", slot: 3, votes: [aliceAt2] },
      { kind: "stop", fromSlot: 3, toSlot: 3, validators: [3] },
      { kind: "vote-target", slot: 5, validator: 0, head: 1 },
    ]);
    const states = scenarioStates(s, 8);
    expect(states[3]!.tree.blocks.has(3)).toBe(false);
    expect(scenarioStates(s, 8)).toEqual(states);
  });
});

describe("scenario codec", () => {
  const both: Intervention[] = [
    { kind: "vote-target", slot: 6, validator: 1, head: 3, target: 3 },
    {
      kind: "omit-inclusion",
      slot: 3,
      votes: [{ kind: "vote", validator: 0, slot: 2, head: 2 }],
      evidence: [{ kind: "double-vote", validator: 1, slot: 2 }],
    },
  ];
  const doc = () => JSON.parse(JSON.stringify(serializeScenario(scenario(both), 8)));

  it("round-trips both kinds and replays to the same states", () => {
    const parsed = parseScenario(doc());
    expect(parsed.scenario.interventions).toEqual(both);
    expect(scenarioStates(parsed.scenario, 8)).toEqual(scenarioStates(scenario(both), 8));
  });

  it("rejects malformed designations and omissions", () => {
    const withFirst = (patch: Record<string, unknown>) => {
      const d = doc();
      d.interventions[0] = { ...d.interventions[0], ...patch };
      return d;
    };
    const withSecond = (patch: Record<string, unknown>) => {
      const d = doc();
      d.interventions[1] = { ...d.interventions[1], ...patch };
      return d;
    };
    expect(() => parseScenario(withFirst({ validator: 4 }))).toThrow(/validator/);
    expect(() => parseScenario(withFirst({ head: -1 }))).toThrow(/head/);
    expect(() => parseScenario(withFirst({ source: 1.5 }))).toThrow(/source/);
    expect(() => parseScenario(withSecond({ votes: [{ kind: "block", block: 2 }] }))).toThrow(
      /must be a vote/,
    );
    expect(() => parseScenario(withSecond({ votes: "x" }))).toThrow(/array/);
    expect(() =>
      parseScenario(withSecond({ evidence: [{ kind: "triple", validator: 1, slot: 2 }] })),
    ).toThrow(/kind/);
    expect(() =>
      parseScenario(withSecond({ evidence: [{ kind: "double-vote", validator: 9, slot: 2 }] })),
    ).toThrow(/validator/);
  });
});
