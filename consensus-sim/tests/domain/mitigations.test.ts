// Mitigations (緩和策, 必須対応事項 27): the fork-choice rule (GHOST counts
// every vote, LMD-GHOST only the latest), the equivocation discount
// (immediate, local, fork choice only) and justified-checkpoint switching
// (window / unrealized / off) — each a protocol parameter, each transparent
// to an honest run, and each bound to the presets the Essence names.

import { describe, expect, it } from "vitest";
import {
  ANCHOR_CHECKPOINT,
  DEFAULT_PARAMS,
  EMPTY_BODY,
  PRESETS,
  addBlock,
  atEnd,
  chainStatesOf,
  createBlockTree,
  epochOf,
  equalStakes,
  equivocatingVoters,
  forkChoiceRoot,
  inJustifiedSwitchWindow,
  resolveView,
  scenarioDelivery,
  scenarioStates,
  scheduleOf,
  viableBlocks,
  viewOf,
  voteRef,
  type BlockBody,
  type CheckpointSwitch,
  type Intervention,
  type PresetName,
  type ProposedBlock,
  type ProtocolParams,
  type Scenario,
  type InitialConditions,
  type Vote,
} from "../../src/domain";

const configOf = (params: ProtocolParams = DEFAULT_PARAMS): InitialConditions => ({
  validatorCount: 4,
  seed: 0,
  params,
  initialStakes: equalStakes(4),
});

/** phase0 (no boost) with one mitigation overridden, to isolate its effect. */
const bare = (override: Partial<ProtocolParams>): ProtocolParams => ({
  ...PRESETS.phase0,
  ...override,
});

const block = (
  index: number,
  parent: number,
  slot: number,
  body: BlockBody = EMPTY_BODY,
): ProposedBlock => ({ kind: "proposed", index, parent, slot, proposer: 0, body });

// source / target are block numbers whose actual tree slot equals the number
// itself for every call in this file (checked case by case), so epochOf on
// the number gives the source checkpoint's own epoch directly; the target
// checkpoint's epoch is always the vote's own slot's epoch (well-formedness).
const vote = (
  validator: number,
  slot: number,
  head: number,
  source = 0,
  target = 0,
): Vote => ({
  validator,
  slot,
  head,
  source: { epoch: epochOf(source), block: source },
  target: { epoch: epochOf(slot), block: target },
});

const everyone = (slot: number, head: number, source: number, target: number) =>
  [0, 1, 2, 3].map((v) => vote(v, slot, head, source, target));

describe("fork-choice rule (GHOST | LMD-GHOST)", () => {
  // anchor(0) ─ 1 ─ 2      (branch A)
  //         └─ 3          (branch B)
  const tree = [block(1, 0, 1), block(2, 1, 2), block(3, 0, 2)].reduce(
    addBlock,
    createBlockTree(),
  );
  const headUnder = (params: ProtocolParams, votes: Vote[]) => {
    const config = configOf(params);
    return resolveView({ blockTree: tree, votes }, config, scheduleOf(config), 2).head;
  };

  it("counts only each validator's latest vote under LMD-GHOST, every vote under GHOST", () => {
    // アリス voted B1 at slot 1 and B3 at slot 2; ボブ B2; キャロル B3.
    const votes = [vote(0, 1, 1), vote(0, 2, 3), vote(1, 2, 2), vote(2, 2, 3)];
    // LMD: branch A 32 (ボブ) vs branch B 64 (アリス, キャロル).
    expect(headUnder(bare({ forkChoice: "LMD-GHOST" }), votes)).toBe(3);
    // GHOST: アリス's stale vote still counts for branch A: 64 vs 64, tie → B1 → B2.
    expect(headUnder(bare({ forkChoice: "GHOST" }), votes)).toBe(2);
  });

  it("weighs both votes of an equivocator under GHOST, one under LMD-GHOST", () => {
    const votes = [vote(0, 2, 2), vote(0, 2, 3), vote(1, 2, 3)];
    // LMD resolves アリス's pair to B2 (smallest head): 32 vs 32, tie → B2.
    expect(headUnder(bare({ forkChoice: "LMD-GHOST" }), votes)).toBe(2);
    // GHOST counts both: branch A 32, branch B 64.
    expect(headUnder(bare({ forkChoice: "GHOST" }), votes)).toBe(3);
  });
});

describe("equivocation discount (エクイボケーション割引)", () => {
  it("names validators with two content-different votes in one slot", () => {
    expect([...equivocatingVoters([])]).toEqual([]);
    expect([...equivocatingVoters([vote(0, 2, 2), vote(0, 2, 2)])]).toEqual([]);
    expect([...equivocatingVoters([vote(0, 2, 2), vote(1, 2, 2), vote(0, 2, 3)])]).toEqual([0]);
    expect([...equivocatingVoters([vote(0, 1, 1), vote(0, 2, 2)])]).toEqual([]);
  });

  it("zeroes the equivocator's fork-choice weight when on, and only there", () => {
    const tree = [block(1, 0, 1), block(2, 1, 2), block(3, 0, 2)].reduce(
      addBlock,
      createBlockTree(),
    );
    const votes = [vote(0, 2, 2), vote(0, 2, 3), vote(1, 2, 2)];
    const view = { blockTree: tree, votes };
    const onConfig = configOf(bare({ equivocationDiscount: true }));
    const offConfig = configOf(bare({ equivocationDiscount: false }));
    const on = resolveView(view, onConfig, scheduleOf(onConfig), 2);
    const off = resolveView(view, offConfig, scheduleOf(offConfig), 2);
    expect(on.weights.weightOf(vote(0, 2, 2))).toBe(0);
    expect(on.weights.weightOf(vote(0, 2, 3))).toBe(0);
    expect(on.weights.weightOf(vote(1, 2, 2))).toBe(32);
    expect(off.weights.weightOf(vote(0, 2, 2))).toBe(32);
    // Fork choice only: the chain state keeps アリス's stake until a block
    // includes the evidence (slashing is the chain-state layer's penalty).
    expect(on.chainState.stakes.get(0)).toBe(32);
  });

  describe("in the simulation", () => {
    // ボブ double-votes at slot 2: the pair is public at the end of slot 2,
    // one slot before B3 includes it as evidence.
    const run = (params: ProtocolParams, extra: Intervention[] = []) => {
      const scenario: Scenario = {
        config: configOf(params),
        interventions: [{ kind: "double-vote", slot: 2, validator: 1 }, ...extra],
      };
      return { states: scenarioStates(scenario, 3), delivery: scenarioDelivery(scenario) };
    };
    const bobWeightSeenBy = (
      { states, delivery }: ReturnType<typeof run>,
      observer: number,
      params: ProtocolParams,
    ) => {
      const config = configOf(params);
      return resolveView(
        viewOf(states[2]!.log, observer, atEnd(2), delivery),
        config,
        scheduleOf(config),
        2,
      ).weights.weightOf(vote(1, 2, 2));
    };

    it("drops the double voter the moment the pair is observed (before slashing lands)", () => {
      const merge = run(PRESETS.merge);
      expect(bobWeightSeenBy(merge, 0, PRESETS.merge)).toBe(0);
      // The chain state of everyone's head at slot 2 still carries ボブ's 32.
      const head = merge.states[2]!.heads.get(0)!;
      expect(merge.states[2]!.chainStates.get(head)!.stakes.get(1)).toBe(32);
      // Off (phase0): the vote keeps its weight until B3 slashes it.
      const phase0 = run(PRESETS.phase0);
      expect(bobWeightSeenBy(phase0, 0, PRESETS.phase0)).toBe(32);
      expect(phase0.states[3]!.chainStates.get(3)!.stakes.get(1)).toBe(0);
    });

    it("is local: a validator that saw only one of the two votes does not discount", () => {
      // アリス never receives ボブ's second vote (head = B1, the primary head's parent).
      const base = run(PRESETS.merge);
      const secondVote = base.states[2]!.votes.find(
        (v) => v.validator === 1 && v.slot === 2 && v.head === 1,
      );
      if (!secondVote) throw new Error("expected ボブ's second vote (head = B1)");
      const states = run(PRESETS.merge, [
        {
          kind: "drop",
          message: voteRef(secondVote),
          observers: [0],
        },
      ]);
      expect(bobWeightSeenBy(states, 0, PRESETS.merge)).toBe(32);
      expect(bobWeightSeenBy(states, 2, PRESETS.merge)).toBe(0);
    });
  });
});

describe("justified-checkpoint switching (justified チェックポイント切替)", () => {
  // Branch A: anchor ─ 1 ─ 2 ─ 3 ─ 4 ─ 5 ─ 8 ─ 9         (slots 1..5, 8, 9)
  //                                     └─ 10       (slot 10)
  // Branch B:                   3 ─ 6 ─ 7                  (slots 8, 10)
  //                               └─ 11                    (slot 9)
  // B5 includes the votes justifying B4 (epoch 1); B7 includes votes
  // justifying B6 (branch B's epoch-2 checkpoint) and B10 the votes
  // justifying B8 (branch A's epoch-2 checkpoint, source B4). B9 and B11
  // include nothing.
  const tree = [
    block(1, 0, 1),
    block(2, 1, 2),
    block(3, 2, 3),
    block(4, 3, 4),
    block(5, 4, 5, { votes: everyone(4, 4, 0, 4), evidence: [] }),
    block(6, 3, 8),
    block(7, 6, 10, { votes: everyone(9, 6, 0, 6), evidence: [] }),
    block(8, 5, 8),
    block(9, 8, 9),
    block(10, 8, 10, { votes: everyone(9, 8, 4, 8), evidence: [] }),
    block(11, 6, 9),
  ].reduce(addBlock, createBlockTree());
  const config = configOf();
  const states = chainStatesOf(tree, config);
  const rootAt = (switching: CheckpointSwitch, atSlot: number) =>
    forkChoiceRoot(tree, states, switching, atSlot);

  it("derives the branches' justified checkpoints as the test assumes", () => {
    const justified = (b: number) => states.get(b)!.justified;
    expect([5, 6, 7, 8, 9, 10, 11].map(justified)).toEqual([
      { epoch: 1, block: 4 },
      ANCHOR_CHECKPOINT,
      { epoch: 2, block: 6 },
      { epoch: 1, block: 4 },
      { epoch: 1, block: 4 },
      { epoch: 2, block: 8 },
      ANCHOR_CHECKPOINT,
    ]);
  });

  it("opens the switch window in the first slot of each epoch only", () => {
    expect([8, 9, 10, 11, 12].map(inJustifiedSwitchWindow)).toEqual([
      true, false, false, false, true,
    ]);
  });

  it("off: always starts from the highest justified checkpoint known", () => {
    // B6 and B8 are both epoch-2 checkpoints; the tie breaks to the smaller index.
    expect(rootAt("off", 10)).toEqual({ epoch: 2, block: 6 });
    expect(rootAt("off", 12)).toEqual({ epoch: 2, block: 6 });
    expect(rootAt("unrealized", 10)).toEqual({ epoch: 2, block: 6 });
  });

  it("window: outside the window, switches only along the root's own chain", () => {
    // As of the window (blocks before slot 9) the root is B4. B8 descends from
    // it and is adopted at once; B6 conflicts and must wait for slot 12.
    expect(rootAt("window", 10)).toEqual({ epoch: 2, block: 8 });
    expect(rootAt("window", 11)).toEqual({ epoch: 2, block: 8 });
    expect(rootAt("window", 12)).toEqual({ epoch: 2, block: 6 });
  });

  it("unrealized: prunes branches whose included votes only justify something older", () => {
    // Under root B6 (its checkpoint of epoch 2): B7 realizes B6, B11 realizes
    // nothing newer than the anchor.
    const viable = viableBlocks(tree, states, { epoch: 2, block: 6 });
    expect(viable.has(7)).toBe(true);
    expect(viable.has(11)).toBe(false);
    expect(viable.has(9)).toBe(false);
    expect(viable.has(10)).toBe(true);
    // Three votes on B11 against one on B7: off follows the weight, unrealized
    // never descends into B11.
    const votes = [vote(0, 10, 11), vote(1, 10, 11), vote(2, 10, 11), vote(3, 10, 7)];
    const view = { blockTree: tree, votes };
    const offConfig = configOf(bare({ checkpointSwitch: "off" }));
    const unrealizedConfig = configOf(bare({ checkpointSwitch: "unrealized" }));
    const windowConfig = configOf(bare({ checkpointSwitch: "window" }));
    expect(resolveView(view, offConfig, scheduleOf(offConfig), 10).head).toBe(11);
    expect(resolveView(view, unrealizedConfig, scheduleOf(unrealizedConfig), 10).head).toBe(7);
    // window at slot 10 starts from B8 instead, where B9 and B10 tie on zero
    // weight and the smaller index wins.
    expect(resolveView(view, windowConfig, scheduleOf(windowConfig), 10).head).toBe(9);
  });
});

describe("presets bind the mitigations", () => {
  const names: PresetName[] = ["phase0", "merge", "current"];

  it("map phase0 → discount off / window, merge → on / window, current → on / unrealized", () => {
    expect(
      names.map((n) => [n, PRESETS[n].forkChoice, PRESETS[n].equivocationDiscount, PRESETS[n].checkpointSwitch]),
    ).toEqual([
      ["phase0", "LMD-GHOST", false, "window"],
      ["merge", "LMD-GHOST", true, "window"],
      ["current", "LMD-GHOST", true, "unrealized"],
    ]);
  });

  it("leave an honest run identical under every preset", () => {
    const runs = names.map((n) => scenarioStates({ config: configOf(PRESETS[n]), interventions: [] }, 12));
    const summary = (states: ReturnType<typeof scenarioStates>) =>
      states.map((s) => [
        [...s.heads.values()],
        s.chainStates.get(s.heads.get(0)!)!.justified,
        s.chainStates.get(s.heads.get(0)!)!.finalized,
      ]);
    expect(summary(runs[1]!)).toEqual(summary(runs[0]!));
    expect(summary(runs[2]!)).toEqual(summary(runs[0]!));
    expect(runs[0]![12]!.chainStates.get(runs[0]![12]!.heads.get(0)!)!.finalized).toEqual({
      epoch: 1,
      block: 4,
    });
  });

  it("keep a run with equivocation and forks deterministic", () => {
    const scenario: Scenario = {
      config: configOf(PRESETS.current),
      interventions: [
        { kind: "double-vote", slot: 2, validator: 1 },
        { kind: "propose-parent", slot: 6, parent: 3 },
        { kind: "partition", fromSlot: 7, toSlot: 10, groups: [[0, 1], [2, 3]] },
      ],
    };
    expect(scenarioStates(scenario, 16)).toEqual(scenarioStates(scenario, 16));
  });
});
