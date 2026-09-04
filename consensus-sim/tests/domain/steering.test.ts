// Vote designation (投票先指定) and omitted inclusion (取り込みの省略),
// 必須対応事項 9: a designated vote is steered to blocks of the voter's own
// view (unspecified components follow the rules), an omitted item stays out
// of the proposer's block but remains includable later, and both survive
// the scenario codec and keep the run deterministic.

import { describe, expect, it } from "vitest";
import {
  ANCHOR_CHECKPOINT,
  DEFAULT_PARAMS,
  bodyOf,
  equalStakes,
  parseScenario,
  proposerForSlot,
  scenarioStates,
  serializeScenario,
  type InitialConditions,
  type Intervention,
  type Scenario,
  type Vote,
} from "../../src/domain";

const CONFIG: InitialConditions = {
  validatorCount: 4,
  seed: 0,
  params: DEFAULT_PARAMS,
  initialStakes: equalStakes(4),
};

const scenario = (interventions: Intervention[]): Scenario => ({
  config: CONFIG,
  interventions,
});

/** The exact reference of B_n, the block published at slot n in these
 * honest-numbering scenarios (block index = slot). */
const blockAt = (slot: number) =>
  ({ kind: "proposal", sender: proposerForSlot(slot, CONFIG), slot, block: slot }) as const;

const votesAt = (s: Scenario, slot: number): Vote[] =>
  scenarioStates(s, slot)[slot]!.votes.filter((v) => v.slot === slot);

const bodyAt = (s: Scenario, slot: number) =>
  bodyOf(scenarioStates(s, slot)[slot]!.tree.blocks.get(slot)!);

describe("vote designation (投票先指定)", () => {
  // Honest run: B_n at slot n; at slot 6 everyone votes head B6.
  // T-053: the FFG part (source, target) is decided once per epoch, at the
  // first vote of the epoch (slot 4 here) and repeated afterward, so slot
  // 6's source is what was settled at slot 4 (nothing justified yet:
  // ANCHOR_CHECKPOINT), not freshly derived from B6's chain state — expected
  // changed from source {epoch:1, block:4} to ANCHOR_CHECKPOINT.
  it("follows the rules when nothing is designated", () => {
    expect(votesAt(scenario([]), 6)).toEqual(
      [0, 1, 2, 3].map((v) => ({
        validator: v,
        slot: 6,
        head: 6,
        source: ANCHOR_CHECKPOINT,
        target: { epoch: 1, block: 4 },
      })),
    );
  });

  it("steers the head and repeats the FFG part already settled for the epoch", () => {
    const votes = votesAt(scenario([{ kind: "vote-target", slot: 6, validator: 1, head: 3 }]), 6);
    // T-053: validator 1 already settled its epoch-1 FFG part at slot 4
    // (following the main chain, target B4); a later designated head no
    // longer moves a freshly decided FFG part onto its own chain once the
    // epoch's FFG part is settled — expected changed from target
    // {epoch:1, block:3} (B3's own checkpoint) to {epoch:1, block:4}
    // (the settled target, repeated).
    expect(votes[1]).toEqual({
      validator: 1,
      slot: 6,
      head: 3,
      source: ANCHOR_CHECKPOINT,
      target: { epoch: 1, block: 4 },
    });
    expect(votes.filter((v) => v.validator !== 1).map((v) => v.head)).toEqual([6, 6, 6]);
  });

  it("applies an explicit source / target on top of the rules", () => {
    const votes = votesAt(
      scenario([
        { kind: "vote-target", slot: 6, validator: 2, source: ANCHOR_CHECKPOINT, target: 5 },
      ]),
      6,
    );
    expect(votes[2]).toEqual({
      validator: 2,
      slot: 6,
      head: 6,
      source: ANCHOR_CHECKPOINT,
      target: { epoch: 1, block: 5 },
    });
  });

  it("makes a designated FFG part that differs from the epoch's settled one evidence (必須 9)", () => {
    // キャロル settled (anchor → B4) at slot 4; a target B5 designated at slot
    // 6 is a second target of epoch 1 — an FFG double vote every view holds
    // at the end of slot 6, included by B7 and slashed on its branch.
    const steered = scenario([{ kind: "vote-target", slot: 6, validator: 2, target: 5 }]);
    const states = scenarioStates(steered, 7);
    const b7 = bodyAt(steered, 7);
    expect(b7.evidence).toEqual([
      {
        kind: "double-vote",
        votes: [
          { validator: 2, slot: 4, head: 4, source: ANCHOR_CHECKPOINT, target: { epoch: 1, block: 4 } },
          { validator: 2, slot: 6, head: 6, source: ANCHOR_CHECKPOINT, target: { epoch: 1, block: 5 } },
        ],
      },
    ]);
    expect(states[7]!.chainStates.get(6)!.stakes.get(2)).toBe(32);
    expect(states[7]!.chainStates.get(7)!.stakes.get(2)).toBe(0);
    // Repeating the settled part, or designating the head alone, is no evidence.
    expect(bodyAt(scenario([{ kind: "vote-target", slot: 6, validator: 2, target: 4 }]), 7).evidence).toEqual([]);
    expect(bodyAt(scenario([{ kind: "vote-target", slot: 6, validator: 2, head: 3 }]), 7).evidence).toEqual([]);
  });

  it("ignores a designated block the voter's view does not hold", () => {
    const s = scenario([
      { kind: "vote-target", slot: 6, validator: 1, head: 99, target: 2 },
      // B2 is dropped for ボブ, so target B2 is unknown to it while B99 never exists.
      { kind: "drop", message: blockAt(2), observers: [1] },
    ]);
    const honest = scenario([{ kind: "drop", message: blockAt(2), observers: [1] }]);
    expect(votesAt(s, 6)).toEqual(votesAt(honest, 6));
  });

  it("is silenced by a stop, and the designated vote is included like any other", () => {
    const stopped = scenario([
      { kind: "vote-target", slot: 6, validator: 1, head: 3 },
      { kind: "stop", fromSlot: 6, toSlot: 6, validators: [1] },
    ]);
    expect(votesAt(stopped, 6).map((v) => v.validator)).toEqual([0, 2, 3]);
    const steered = scenario([{ kind: "vote-target", slot: 6, validator: 1, head: 3 }]);
    // T-053: see the same settled-FFG explanation above — target changed
    // from {epoch:1, block:3} to {epoch:1, block:4}.
    expect(bodyAt(steered, 7).votes).toContainEqual({
      validator: 1,
      slot: 6,
      head: 3,
      source: ANCHOR_CHECKPOINT,
      target: { epoch: 1, block: 4 },
    });
  });
});

describe("omitted inclusion (取り込みの省略)", () => {
  const aliceAt2 = { kind: "vote", sender: 0, slot: 2 } as const;

  it("leaves the named vote out of the proposer's block; a later block includes it", () => {
    const s = scenario([{ kind: "omit-inclusion", slot: 3, votes: [aliceAt2] }]);
    const b3 = bodyAt(s, 3);
    expect(b3.votes.map((v) => v.validator)).toEqual([1, 2, 3]);
    const b4 = bodyAt(s, 4);
    expect(b4.votes).toContainEqual({
      validator: 0,
      slot: 2,
      head: 2,
      source: ANCHOR_CHECKPOINT,
      target: ANCHOR_CHECKPOINT,
    });
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
      votes: [{ kind: "vote", sender: 0, slot: 2 }],
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
    expect(() =>
      parseScenario(withSecond({ votes: [{ kind: "proposal", sender: 0, slot: 2 }] })),
    ).toThrow(/must be a vote/);
    expect(() => parseScenario(withSecond({ votes: "x" }))).toThrow(/array/);
    expect(() =>
      parseScenario(withSecond({ evidence: [{ kind: "triple", validator: 1, slot: 2 }] })),
    ).toThrow(/kind/);
    expect(() =>
      parseScenario(withSecond({ evidence: [{ kind: "double-vote", validator: 9, slot: 2 }] })),
    ).toThrow(/validator/);
  });
});
