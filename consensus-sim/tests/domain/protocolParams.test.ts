// Protocol parameters (必須対応事項 3・24): presets match the Essence table,
// committees and the proposer schedule derive deterministically from
// (slot, params, seed), only committee members vote, and the proposer boost
// weighs the timely proposal of a slot — and only that — in that slot's
// fork choice.

import { describe, expect, it } from "vitest";
import {
  ANCHOR_BLOCK_INDEX,
  DEFAULT_PARAMS,
  DEFAULT_PRESET,
  EMPTY_BODY,
  PRESETS,
  addBlock,
  boostedBlock,
  committeeForSlot,
  createBlockTree,
  equalStakes,
  ghostHead,
  presetOf,
  proposerForSlot,
  resolveView,
  scenarioStates,
  stateAtSlot,
  viewOf,
  type Block,
  type Intervention,
  type ProtocolParams,
  type SimulationConfig,
  type Vote,
} from "../../src/domain";

const withParams = (
  params: ProtocolParams,
  validatorCount = 4,
  seed = 0,
): SimulationConfig => ({
  validatorCount,
  seed,
  params,
  initialStakes: equalStakes(validatorCount),
});

describe("presets (プロトコルプリセット)", () => {
  it("match the Essence table", () => {
    const rows = (["phase0", "merge", "current"] as const).map((name) => {
      const p = PRESETS[name];
      return [
        name,
        p.forkChoice,
        p.boost,
        p.equivocationDiscount,
        p.checkpointSwitch,
        p.slashing,
        p.inactivityLeak.enabled,
        p.inactivityLeak.delayEpochs,
        p.committee.kind,
      ];
    });
    expect(rows).toEqual([
      ["phase0", "LMD-GHOST", 0, false, "window", true, true, 4, "all"],
      ["merge", "LMD-GHOST", 0.4, true, "window", true, true, 4, "all"],
      ["current", "LMD-GHOST", 0.4, true, "unrealized", true, true, 4, "all"],
    ]);
  });

  it("default to merge and are recognized field by field", () => {
    expect(DEFAULT_PRESET).toBe("merge");
    expect(DEFAULT_PARAMS).toEqual(PRESETS.merge);
    expect(presetOf(PRESETS.current)).toBe("current");
    expect(presetOf({ ...PRESETS.merge, boost: 0.3 })).toBeUndefined();
  });
});

describe("schedule (プロポーザー予定表・committee)", () => {
  it("proposes round-robin regardless of the seed", () => {
    const a = withParams(DEFAULT_PARAMS, 4, 1);
    const b = withParams(DEFAULT_PARAMS, 4, 999);
    expect([1, 2, 3, 4, 5].map((s) => proposerForSlot(s, a))).toEqual([1, 2, 3, 0, 1]);
    expect([1, 2, 3, 4, 5].map((s) => proposerForSlot(s, b))).toEqual([1, 2, 3, 0, 1]);
  });

  it("assigns everyone under committee = all", () => {
    expect([...committeeForSlot(3, withParams(DEFAULT_PARAMS, 6))]).toEqual([
      0, 1, 2, 3, 4, 5,
    ]);
  });

  it("draws exactly c distinct members per slot, deterministically from (seed, slot)", () => {
    const sized = { ...DEFAULT_PARAMS, committee: { kind: "sized", size: 3 } as const };
    const config = withParams(sized, 10, 7);
    const seen = new Set<string>();
    for (let slot = 1; slot <= 8; slot++) {
      const committee = [...committeeForSlot(slot, config)];
      expect(committee).toHaveLength(3);
      expect(new Set(committee).size).toBe(3);
      for (const v of committee) expect(v).toBeGreaterThanOrEqual(0);
      for (const v of committee) expect(v).toBeLessThan(10);
      expect([...committeeForSlot(slot, config)]).toEqual(committee);
      seen.add(committee.join(","));
    }
    // The draw varies with the slot and with the seed.
    expect(seen.size).toBeGreaterThan(1);
    const other = withParams(sized, 10, 8);
    const differs = [1, 2, 3, 4, 5, 6, 7, 8].some(
      (s) =>
        [...committeeForSlot(s, config)].join() !==
        [...committeeForSlot(s, other)].join(),
    );
    expect(differs).toBe(true);
  });

  it("rejects a committee size outside [1, n]", () => {
    const bad = { ...DEFAULT_PARAMS, committee: { kind: "sized", size: 5 } as const };
    expect(() => committeeForSlot(1, withParams(bad, 4))).toThrow(/committee size/);
  });

  it("lets only committee members vote in the simulation", () => {
    const sized = { ...DEFAULT_PARAMS, committee: { kind: "sized", size: 2 } as const };
    const config = withParams(sized, 5, 3);
    const state = stateAtSlot(config, 8);
    for (let slot = 1; slot <= 8; slot++) {
      const voters = state.votes.filter((v) => v.slot === slot).map((v) => v.validator);
      expect(voters).toHaveLength(2);
      expect([...committeeForSlot(slot, config)]).toEqual([...voters].sort((a, b) => a - b));
    }
    // Same seed ⇒ same run; the committees are part of the scenario identity.
    expect(stateAtSlot(config, 8)).toEqual(state);
  });
});

describe("proposer boost in fork choice", () => {
  const block = (index: number, parent: number, slot: number, proposer = 0): Block => ({
    index,
    parent,
    slot,
    proposer,
    body: EMPTY_BODY,
  });
  const vote = (validator: number, slot: number, head: number): Vote => ({
    validator,
    slot,
    head,
    source: 0,
    target: 0,
  });
  // anchor(0) ─ 1 ─ 2      (branch A)
  //         └─ 3          (branch B, proposed at slot 3 by validator 3)
  const tree = [block(1, 0, 1, 1), block(2, 1, 2, 2), block(3, 0, 3, 3)].reduce(
    addBlock,
    createBlockTree(),
  );

  it("adds the boost to the boosted block's subtree", () => {
    const votes = [vote(0, 2, 2), vote(1, 2, 3)];
    // Unweighted tie: 1 vote each, smallest index wins.
    expect(ghostHead(tree, votes, ANCHOR_BLOCK_INDEX)).toBe(2);
    expect(
      ghostHead(tree, votes, ANCHOR_BLOCK_INDEX, {
        weightOf: () => 1,
        boost: { block: 3, weight: 0.5 },
      }),
    ).toBe(3);
    // Stakes weigh votes: a heavier validator outweighs the boost.
    expect(
      ghostHead(tree, votes, ANCHOR_BLOCK_INDEX, {
        weightOf: (v) => (v.validator === 0 ? 10 : 1),
        boost: { block: 3, weight: 0.5 },
      }),
    ).toBe(2);
  });

  it("boosts only the current slot's proposal by its scheduled proposer", () => {
    const config = withParams(PRESETS.merge);
    const view = { validator: 0, slot: 3, blockTree: tree, votes: [] };
    expect(boostedBlock(view, 3, config)).toBe(3);
    // Computed at a later slot (e.g. the block arrived late), no boost.
    expect(boostedBlock(view, 4, config)).toBeUndefined();
    // Block 2 was proposed at slot 2 by validator 2 — its slot has passed.
    expect(boostedBlock({ ...view, slot: 2 }, 2, config)).toBe(2);
    expect(boostedBlock(view, 3, withParams(PRESETS.phase0))).toBeUndefined();
  });

  it("weighs the boost as committee weight × boost with root-state stakes", () => {
    const config = withParams(PRESETS.merge);
    const view = { validator: 0, slot: 3, blockTree: tree, votes: [] };
    const { weights } = resolveView(view, config);
    expect(weights.weightOf(vote(0, 3, 3))).toBe(32);
    expect(weights.boost).toEqual({ block: 3, weight: 4 * 32 * 0.4 });
  });
});

describe("proposer boost in the simulation (観測可能な効果)", () => {
  // Slot 2: only キャロル (its proposer) is active, so B2 carries a single
  // vote. Slot 3: デイブ forks onto B1, so B3 competes with B2 for the
  // slot-3 attesters — 32 of votes against the boost (128 × 0.4 = 51.2).
  const interventions: Intervention[] = [
    { kind: "stop", fromSlot: 2, toSlot: 2, validators: [0, 1, 3] },
    { kind: "propose-parent", slot: 3, parent: 1 },
  ];
  const headsVotedAt = (params: ProtocolParams, slot: number) =>
    scenarioStates({ config: withParams(params), interventions }, slot)[slot]!.votes
      .filter((v) => v.slot === slot)
      .map((v) => v.head);

  it("flips the slot's votes to the boosted proposal under merge, not under phase0", () => {
    expect(headsVotedAt(PRESETS.merge, 3)).toEqual([3, 3, 3, 3]);
    expect(headsVotedAt(PRESETS.phase0, 3)).toEqual([2, 2, 2, 2]);
  });

  it("gives no boost to a proposal that arrives late", () => {
    const delayed: Intervention[] = [
      ...interventions,
      {
        kind: "delay",
        message: { kind: "block", block: 3 },
        untilSlot: 4,
        observers: [0, 1, 2],
      },
    ];
    const states = scenarioStates({ config: withParams(PRESETS.merge), interventions: delayed }, 4);
    // At slot 3 only デイブ (the proposer) sees B3 and its boost.
    expect(states[3]!.votes.filter((v) => v.slot === 3).map((v) => v.head)).toEqual([
      2, 2, 2, 3,
    ]);
    // At slot 4 B3 has arrived but its slot has passed: B2's branch keeps the
    // majority, and the slot-4 proposal builds on it.
    const b4 = states[4]!.tree.blocks.get(4)!;
    expect(b4.parent).toBe(2);
    expect([...states[4]!.heads.values()]).toEqual([4, 4, 4, 4]);
    // The proposer of slot 4 never boosts a past proposal in its own fork choice.
    const proposerView = viewOf(states[3]!.log, 0, 3);
    expect(boostedBlock(proposerView, 4, withParams(PRESETS.merge))).toBeUndefined();
  });
});
