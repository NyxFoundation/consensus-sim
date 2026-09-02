// Interventions (介入): partitions, operating states (停止/オフライン),
// equivocations, per-message delay/drop and fork creation (propose-parent),
// all expressed as scenario data and compiled onto the engine's
// delivery/directives axes. Each case checks the intervention produces its
// specified observable effect — and that the whole run stays deterministic.

import { describe, expect, it } from "vitest";
import {
  DEFAULT_PARAMS,
  advanceScenario,
  scenarioStates,
  type Intervention,
  type Scenario,
  type SimulationConfig,
  type SimulationState,
} from "../../src/domain";
import {
  closeSpanAt,
  latestVotes,
  observe,
  operatingStateAt,
  proposerForSlot,
  scenarioDelivery,
  type SpanIntervention,
} from "../../src/domain";

const scenario = (
  interventions: Intervention[],
  validatorCount = 4,
): Scenario => ({
  config: { validatorCount, seed: 0, params: DEFAULT_PARAMS },
  interventions,
});

const CONFIG4: SimulationConfig = scenario([]).config;

const statesAt = (s: Scenario, slot: number): SimulationState[] =>
  scenarioStates(s, slot);

describe("partition intervention (分断)", () => {
  const partitioned = scenario([
    { kind: "partition", fromSlot: 2, toSlot: 8, groups: [[0, 1]] },
  ]);

  it("diverges heads across camps and stays equal within a camp", () => {
    const state = statesAt(partitioned, 8)[8];
    if (!state) throw new Error("missing state");
    expect(state.heads.get(0)).toBe(state.heads.get(1));
    expect(state.heads.get(2)).toBe(state.heads.get(3));
    expect(state.heads.get(0)).not.toBe(state.heads.get(2));
  });

  it("messages published before the partition are already through", () => {
    const state = statesAt(partitioned, 3)[3];
    if (!state) throw new Error("missing state");
    // Block of slot 1 (published pre-partition) is visible to everyone.
    const obs2 = observe(state.log, 2, state.slot, CONFIG4);
    const slot1Blocks = [...obs2.view.blockTree.blocks.values()].filter(
      (b) => b.slot === 1,
    );
    expect(slot1Blocks).toHaveLength(1);
  });

  it("healing releases held-back messages and reconverges all views", () => {
    const state = statesAt(partitioned, 10)[10];
    if (!state) throw new Error("missing state");
    const heads = [...state.heads.values()];
    expect(new Set(heads).size).toBe(1);
    // After healing (toSlot 8), every camp's blocks are visible to everyone.
    const obs0 = observe(state.log, 0, state.slot, CONFIG4);
    expect(obs0.view.blockTree.blocks.size).toBe(state.tree.blocks.size);
  });
});

describe("stop intervention (停止/復帰)", () => {
  it("a stopped proposer leaves its slot empty", () => {
    // Slot 1's proposer is V1 (round robin).
    const s = scenario([
      { kind: "stop", fromSlot: 1, toSlot: 1, validators: [1] },
    ]);
    const states = statesAt(s, 2);
    expect(states[1]?.tree.blocks.size).toBe(1); // anchor only
    expect(states[2]?.tree.blocks.size).toBe(2); // slot 2 proposes again
  });

  it("a stopped attester casts no votes until resumed", () => {
    const s = scenario([
      { kind: "stop", fromSlot: 1, toSlot: 2, validators: [2] },
    ]);
    const states = statesAt(s, 3);
    const votersAt = (slot: number) =>
      new Set(
        (states[slot]?.votes ?? [])
          .filter((v) => v.slot === slot)
          .map((v) => v.validator),
      );
    expect(votersAt(1).has(2)).toBe(false);
    expect(votersAt(2).has(2)).toBe(false);
    expect(votersAt(3).has(2)).toBe(true); // resumed
  });

  it("a stopped validator still observes (silenced, not blinded)", () => {
    const s = scenario([
      { kind: "stop", fromSlot: 1, validators: [3] },
    ]);
    const state = statesAt(s, 4)[4];
    if (!state) throw new Error("missing state");
    const obs = observe(state.log, 3, state.slot, CONFIG4);
    expect(obs.view.blockTree.blocks.size).toBe(state.tree.blocks.size);
    expect(state.heads.get(3)).toBe(state.heads.get(0));
  });
});

describe("offline intervention (オフライン)", () => {
  // V3 offline during slots 2..4; everyone else keeps running.
  const offline = scenario([
    { kind: "offline", fromSlot: 2, toSlot: 4, validators: [3] },
  ]);

  it("an offline validator neither proposes nor votes", () => {
    const states = statesAt(offline, 4);
    // V3 proposes slot 3 (round robin): the slot stays empty.
    const slot3 = [...(states[4]?.tree.blocks.values() ?? [])].filter(
      (b) => b.slot === 3,
    );
    expect(slot3).toHaveLength(0);
    const votersAt = (slot: number) =>
      new Set(
        (states[4]?.votes ?? [])
          .filter((v) => v.slot === slot)
          .map((v) => v.validator),
      );
    expect(votersAt(2).has(3)).toBe(false);
    expect(votersAt(3).has(3)).toBe(false);
    expect(votersAt(4).has(3)).toBe(false);
  });

  it("the view freezes while offline (nothing arrives, unlike 停止)", () => {
    const state = statesAt(offline, 4)[4];
    if (!state) throw new Error("missing state");
    const delivery = scenarioDelivery(offline);
    const obs = observe(state.log, 3, state.slot, CONFIG4, delivery);
    // Frozen at the state entering slot 2: anchor + the slot-1 block only,
    // and only votes published through slot 1.
    expect([...obs.view.blockTree.blocks.keys()].sort()).toEqual([0, 1]);
    expect(obs.view.votes.every((v) => v.slot <= 1)).toBe(true);
    // The god view moved on without it.
    expect(state.tree.blocks.size).toBeGreaterThan(obs.view.blockTree.blocks.size);
  });

  it("after returning, pent-up messages arrive through normal propagation", () => {
    const states = statesAt(offline, 6);
    const delivery = scenarioDelivery(offline);
    // Return slot is 5: the whole backlog becomes visible there, not before.
    const at5 = states[5];
    if (!at5) throw new Error("missing state");
    const obs5 = observe(at5.log, 3, at5.slot, CONFIG4, delivery);
    expect(obs5.view.blockTree.blocks.size).toBe(at5.tree.blocks.size);
    // Caught up: by slot 6 V3 votes again and shares the common head.
    const at6 = states[6];
    if (!at6) throw new Error("missing state");
    expect(
      at6.votes.some((v) => v.validator === 3 && v.slot === 6),
    ).toBe(true);
    expect(at6.heads.get(3)).toBe(at6.heads.get(0));
  });
});

describe("propose-parent intervention (フォーク作成)", () => {
  it("forces the designated parent, creating a fork", () => {
    const s = scenario([{ kind: "propose-parent", slot: 3, parent: 1 }]);
    const state = statesAt(s, 3)[3];
    if (!state) throw new Error("missing state");
    const slot3 = [...state.tree.blocks.values()].find((b) => b.slot === 3);
    expect(slot3?.parent).toBe(1); // fork choice would have picked B2
  });

  it("without a designation the fork choice picks the parent", () => {
    const state = statesAt(scenario([]), 3)[3];
    const slot3 = [...(state?.tree.blocks.values() ?? [])].find(
      (b) => b.slot === 3,
    );
    expect(slot3?.parent).toBe(2);
  });

  it("falls back to fork choice when the parent is not in the proposer's view", () => {
    // Slot 3's proposer is V3; drop B1 for it, so B1 (and orphaned B2) are
    // invisible and its honest head is the anchor.
    const s = scenario([
      { kind: "drop", message: { kind: "block", block: 1 }, observers: [3] },
      { kind: "propose-parent", slot: 3, parent: 1 },
    ]);
    const state = statesAt(s, 3)[3];
    if (!state) throw new Error("missing state");
    const slot3 = [...state.tree.blocks.values()].find((b) => b.slot === 3);
    expect(slot3?.parent).toBe(0); // anchor — the view's own fork choice
  });
});

describe("equivocation interventions (二重提案・二重投票)", () => {
  it("double propose publishes two sibling blocks in one slot", () => {
    const s = scenario([
      { kind: "double-propose", slot: 1, validator: proposerForSlot(1, CONFIG4) },
    ]);
    const state = statesAt(s, 1)[1];
    if (!state) throw new Error("missing state");
    const slot1 = [...state.tree.blocks.values()].filter((b) => b.slot === 1);
    expect(slot1).toHaveLength(2);
    expect(slot1[0]?.parent).toBe(slot1[1]?.parent);
    expect(slot1[0]?.proposer).toBe(slot1[1]?.proposer);
    // Attesters resolve the conflict deterministically (both are visible).
    const nextState = advanceScenario(s, state);
    expect(nextState.tree.blocks.size).toBe(4);
  });

  it("double propose by a non-proposer of that slot is ignored", () => {
    const nonProposer = (proposerForSlot(1, CONFIG4) + 1) % 4;
    const s = scenario([
      { kind: "double-propose", slot: 1, validator: nonProposer },
    ]);
    const state = statesAt(s, 1)[1];
    expect(
      [...(state?.tree.blocks.values() ?? [])].filter((b) => b.slot === 1),
    ).toHaveLength(2 - 1);
  });

  it("double vote casts two conflicting votes in one slot", () => {
    const s = scenario([{ kind: "double-vote", slot: 3, validator: 0 }]);
    const state = statesAt(s, 3)[3];
    if (!state) throw new Error("missing state");
    const v0AtSlot3 = state.votes.filter(
      (v) => v.validator === 0 && v.slot === 3,
    );
    expect(v0AtSlot3).toHaveLength(2);
    expect(v0AtSlot3[0]?.head).not.toBe(v0AtSlot3[1]?.head);
    // LMD resolution of the equivocation is deterministic.
    const resolved = latestVotes(state.votes).get(0);
    expect(resolved).toBeDefined();
  });

  it("double vote at slot 1 (head = only child of anchor) still equivocates or degrades to one vote", () => {
    const s = scenario([{ kind: "double-vote", slot: 1, validator: 2 }]);
    const state = statesAt(s, 1)[1];
    if (!state) throw new Error("missing state");
    const votes = state.votes.filter((v) => v.validator === 2 && v.slot === 1);
    // Head at slot 1 is B1 whose parent is the anchor — a distinct alt exists.
    expect(votes).toHaveLength(2);
    expect(new Set(votes.map((v) => v.head)).size).toBe(2);
  });
});

describe("delay / drop interventions (遅延・欠落)", () => {
  it("a delayed block is invisible to its targets until untilSlot", () => {
    const s = scenario([
      { kind: "delay", message: { kind: "block", block: 1 }, untilSlot: 3 },
    ]);
    const states = statesAt(s, 3);
    const delivery = scenarioDelivery(s);
    const sees = (slot: number, observer: number) => {
      const st = states[slot];
      if (!st) throw new Error("missing state");
      return observe(st.log, observer, st.slot, CONFIG4, delivery)
        .view.blockTree.blocks.has(1);
    };
    expect(sees(1, 0)).toBe(false);
    expect(sees(2, 0)).toBe(false);
    expect(sees(3, 0)).toBe(true);
    // The sender (slot 1's proposer, V1) always sees its own block.
    expect(sees(1, 1)).toBe(true);
  });

  it("a dropped block never arrives for its targets, and observers can be scoped", () => {
    const s = scenario([
      {
        kind: "drop",
        message: { kind: "block", block: 1 },
        observers: [2, 3],
      },
    ]);
    const state = statesAt(s, 4)[4];
    if (!state) throw new Error("missing state");
    const delivery = scenarioDelivery(s);
    const sees = (observer: number) =>
      observe(state.log, observer, state.slot, CONFIG4, delivery)
        .view.blockTree.blocks.has(1);
    expect(sees(0)).toBe(true);
    expect(sees(1)).toBe(true); // sender
    expect(sees(2)).toBe(false);
    expect(sees(3)).toBe(false);
  });

  it("a dropped vote is excluded from the targets' views only", () => {
    const s = scenario([]);
    const base = statesAt(s, 2)[2];
    if (!base) throw new Error("missing state");
    const vote = base.votes.find((v) => v.validator === 3 && v.slot === 1);
    if (!vote) throw new Error("expected V3's slot-1 vote");
    const dropped = scenario([
      {
        kind: "drop",
        message: {
          kind: "vote",
          validator: vote.validator,
          slot: vote.slot,
          head: vote.head,
        },
        observers: [0],
      },
    ]);
    const state = statesAt(dropped, 2)[2];
    if (!state) throw new Error("missing state");
    const delivery = scenarioDelivery(dropped);
    const votesSeen = (observer: number) =>
      observe(state.log, observer, state.slot, CONFIG4, delivery).view.votes.filter(
        (v) => v.validator === 3 && v.slot === 1,
      ).length;
    expect(votesSeen(0)).toBe(0);
    expect(votesSeen(1)).toBe(1);
  });
});

describe("scenario determinism (決定性)", () => {
  it("the same intervention-laden scenario reproduces identical states", () => {
    const interventions: Intervention[] = [
      { kind: "partition", fromSlot: 2, toSlot: 6, groups: [[0, 1]] },
      { kind: "stop", fromSlot: 3, toSlot: 4, validators: [2] },
      { kind: "double-propose", slot: 5, validator: proposerForSlot(5, CONFIG4) },
      { kind: "double-vote", slot: 6, validator: 1 },
      { kind: "drop", message: { kind: "block", block: 2 }, observers: [3] },
      { kind: "offline", fromSlot: 7, toSlot: 8, validators: [0] },
      { kind: "propose-parent", slot: 9, parent: 1 },
    ];
    const a = statesAt(scenario(interventions), 10);
    const b = statesAt(scenario(interventions), 10);
    expect(a).toHaveLength(11);
    for (let i = 0; i <= 10; i++) {
      expect(a[i]?.tree.blocks.size).toBe(b[i]?.tree.blocks.size);
      expect([...(a[i]?.heads ?? [])]).toEqual([...(b[i]?.heads ?? [])]);
      expect(a[i]?.votes).toEqual(b[i]?.votes);
      expect(a[i]?.chainStates).toEqual(b[i]?.chainStates);
    }
  });

  it("scenarioStates(s, n)[i] is the state at slot i", () => {
    const states = statesAt(scenario([]), 5);
    expect(states.map((s) => s.slot)).toEqual([0, 1, 2, 3, 4, 5]);
  });
});

describe("closeSpanAt (介入キューの健全性)", () => {
  const spans: SpanIntervention[] = [
    { kind: "partition", fromSlot: 2, groups: [[0, 1]] },
    { kind: "stop", fromSlot: 2, validators: [1] },
    { kind: "offline", fromSlot: 2, validators: [1] },
  ];

  it("closes an effective span at the cursor (inclusive)", () => {
    for (const span of spans) {
      const closed = closeSpanAt(span, 5);
      expect(closed).toEqual({ ...span, toSlot: 5 });
    }
  });

  it("refuses to close a span that has not taken effect yet", () => {
    for (const span of spans) {
      // Cursor 1, fromSlot 2: closing would yield toSlot < fromSlot.
      expect(closeSpanAt(span, 1)).toBeUndefined();
    }
  });

  it("never produces a toSlot-before-fromSlot span", () => {
    for (const span of spans) {
      for (let cursor = 0; cursor <= 6; cursor++) {
        const closed = closeSpanAt(span, cursor);
        if (closed) expect(closed.toSlot).toBeGreaterThanOrEqual(closed.fromSlot);
      }
    }
  });
});

describe("operatingStateAt (稼働状態)", () => {
  const interventions: Intervention[] = [
    { kind: "stop", fromSlot: 2, toSlot: 5, validators: [1] },
    { kind: "offline", fromSlot: 4, toSlot: 6, validators: [1, 2] },
  ];

  it("reads active outside every span and at span boundaries", () => {
    expect(operatingStateAt(interventions, 1, 1)).toBe("active");
    expect(operatingStateAt(interventions, 1, 7)).toBe("active");
    expect(operatingStateAt(interventions, 0, 4)).toBe("active");
  });

  it("reads stopped inside a stop span and offline wins where spans overlap", () => {
    expect(operatingStateAt(interventions, 1, 2)).toBe("stopped");
    expect(operatingStateAt(interventions, 1, 4)).toBe("offline");
    expect(operatingStateAt(interventions, 1, 6)).toBe("offline");
    expect(operatingStateAt(interventions, 2, 4)).toBe("offline");
    expect(operatingStateAt(interventions, 2, 3)).toBe("active");
  });

  it("treats an open-ended span as covering every later slot", () => {
    const open: Intervention[] = [
      { kind: "stop", fromSlot: 3, validators: [0] },
    ];
    expect(operatingStateAt(open, 0, 2)).toBe("active");
    expect(operatingStateAt(open, 0, 100)).toBe("stopped");
  });
});
