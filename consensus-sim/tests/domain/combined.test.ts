// Adversarial combinations — every intervention kind at once, overlapping
// spans on one validator, and interactions between the delivery conditions
// (delay × partition, equivocation × partition). Each case pins the exact
// combined semantics; the first block also pins the three global guarantees
// (determinism, rewind-as-prefix, codec round-trip) under maximal load.

import { describe, expect, it } from "vitest";
import {
  DEFAULT_PARAMS,
  equalStakes,
  latestVotes,
  parseScenario,
  scenarioDelivery,
  scenarioStates,
  serializeScenario,
  viewOf,
  type Intervention,
  type Scenario,
} from "../../src/domain";

const scenario = (
  interventions: Intervention[],
  validatorCount = 4,
): Scenario => ({
  config: {
    validatorCount,
    seed: 0,
    params: DEFAULT_PARAMS,
    initialStakes: equalStakes(validatorCount),
  },
  interventions,
});

// Every intervention kind in one 4-validator run. Round robin: slot s is
// proposed by validator s % 4. Blocks index in publication order: B1@s1,
// B2@s2, B3@s3, B4@s4(V0), then slot 5 (V1) double-proposes B5+B6 — slot 7
// belongs to V3, back from offline, forced onto the anchor.
const everything = scenario([
  { kind: "partition", fromSlot: 2, toSlot: 5, groups: [[0, 1]] },
  { kind: "stop", fromSlot: 3, toSlot: 4, validators: [2] },
  { kind: "offline", fromSlot: 4, toSlot: 6, validators: [3] },
  { kind: "double-propose", slot: 5, validator: 1 },
  { kind: "double-vote", slot: 3, validator: 0 },
  { kind: "delay", message: { kind: "block", block: 2 }, untilSlot: 4, observers: [0] },
  { kind: "drop", message: { kind: "block", block: 4 }, observers: [1] },
  { kind: "propose-parent", slot: 7, parent: 0 },
]);

describe("all intervention kinds combined", () => {
  const THROUGH = 12;
  const run = scenarioStates(everything, THROUGH);

  it("is deterministic: recomputation reproduces every state exactly", () => {
    expect(scenarioStates(everything, THROUGH)).toEqual(run);
  });

  it("rewind is a prefix: the run through slot i equals the first i+1 states", () => {
    for (let i = 0; i <= THROUGH; i++) {
      expect(scenarioStates(everything, i)).toEqual(run.slice(0, i + 1));
    }
  });

  it("survives a codec round-trip and replays to the same states", () => {
    const saved = parseScenario(
      JSON.parse(JSON.stringify(serializeScenario(everything, THROUGH))),
    );
    expect(saved.runSlot).toBe(THROUGH);
    expect(scenarioStates(saved.scenario, THROUGH)).toEqual(run);
  });

  it("visibility is monotone: once a validator has seen a message, it stays seen", () => {
    const last = run[THROUGH];
    if (!last) throw new Error("missing state");
    const delivery = scenarioDelivery(everything);
    for (let v = 0; v < 4; v++) {
      for (let s = 0; s < THROUGH; s++) {
        const now = viewOf(last.log, v, s, delivery);
        const next = viewOf(last.log, v, s + 1, delivery);
        for (const index of now.blockTree.blocks.keys()) {
          expect(next.blockTree.blocks.has(index)).toBe(true);
        }
        expect(next.votes.length).toBeGreaterThanOrEqual(now.votes.length);
      }
    }
  });

  it("applies the combined directives: double proposal siblings and the forced anchor parent", () => {
    const last = run[THROUGH];
    if (!last) throw new Error("missing state");
    const slot5 = [...last.tree.blocks.values()].filter((b) => b.slot === 5);
    expect(slot5).toHaveLength(2);
    expect(new Set(slot5.map((b) => b.parent)).size).toBe(1);
    const slot7 = [...last.tree.blocks.values()].filter((b) => b.slot === 7);
    expect(slot7.map((b) => b.parent)).toEqual([0]);
  });

  it("keeps a dropped block invisible to its observers forever, and only to them", () => {
    const last = run[THROUGH];
    if (!last) throw new Error("missing state");
    const delivery = scenarioDelivery(everything);
    expect(viewOf(last.log, 1, THROUGH, delivery).blockTree.blocks.has(4)).toBe(false);
    expect(viewOf(last.log, 0, THROUGH, delivery).blockTree.blocks.has(4)).toBe(true);
  });
});

describe("overlapping stop and offline spans on one validator", () => {
  // V2 proposes slots 2, 6, 10. Stopped s2..s5, offline s4..s7: silent for
  // s2..s7 (both proposal slots in range are empty), receiving until s3,
  // frozen s4..s7, back to normal from s8.
  const overlapped = scenario([
    { kind: "stop", fromSlot: 2, toSlot: 5, validators: [2] },
    { kind: "offline", fromSlot: 4, toSlot: 7, validators: [2] },
    { kind: "double-vote", slot: 3, validator: 2 },
  ]);
  const run = scenarioStates(overlapped, 11);

  it("leaves both covered proposal slots empty and silences the equivocation", () => {
    const last = run[11];
    if (!last) throw new Error("missing state");
    const bySlot = (s: number) =>
      [...last.tree.blocks.values()].filter((b) => b.slot === s);
    expect(bySlot(2)).toHaveLength(0);
    expect(bySlot(6)).toHaveLength(0);
    expect(bySlot(10)).toHaveLength(1);
    expect(last.votes.filter((v) => v.validator === 2 && v.slot === 3)).toHaveLength(0);
  });

  it("keeps receiving while merely stopped, freezes only across the offline span", () => {
    const last = run[11];
    if (!last) throw new Error("missing state");
    const delivery = scenarioDelivery(overlapped);
    const sizeAt = (s: number) =>
      viewOf(last.log, 2, s, delivery).blockTree.blocks.size;
    expect(sizeAt(3)).toBeGreaterThan(sizeAt(1));
    expect(sizeAt(7)).toBe(sizeAt(3));
    expect(sizeAt(8)).toBeGreaterThan(sizeAt(7));
  });

  it("reconverges with the others after returning", () => {
    const last = run[11];
    if (!last) throw new Error("missing state");
    expect(new Set(last.heads.values()).size).toBe(1);
  });
});

describe("delay and partition must both clear at the same instant", () => {
  // B1 (published at slot 1) is delayed for V0 until slot 3, and V0 is cut
  // off by a partition over slots 3..5. Pointwise delivery requires one slot
  // where every condition holds at once, so B1 reaches V0 only at slot 6 —
  // not at slot 3, when the delay alone has expired.
  const squeezed = scenario([
    { kind: "delay", message: { kind: "block", block: 1 }, untilSlot: 3, observers: [0] },
    { kind: "partition", fromSlot: 3, toSlot: 5, groups: [[0]] },
  ]);

  it("holds the message through the delay-then-partition squeeze", () => {
    const run = scenarioStates(squeezed, 6);
    const last = run[6];
    if (!last) throw new Error("missing state");
    const delivery = scenarioDelivery(squeezed);
    expect(viewOf(last.log, 0, 2, delivery).blockTree.blocks.has(1)).toBe(false);
    expect(viewOf(last.log, 0, 5, delivery).blockTree.blocks.has(1)).toBe(false);
    expect(viewOf(last.log, 0, 6, delivery).blockTree.blocks.has(1)).toBe(true);
  });
});

describe("equivocation inside a partition", () => {
  // V0 double-votes at slot 3 while partitioned with V1; V2/V3 see neither
  // vote until healing, then everyone resolves the same LMD row for V0.
  const split = scenario([
    { kind: "partition", fromSlot: 2, toSlot: 6, groups: [[0, 1]] },
    { kind: "double-vote", slot: 3, validator: 0 },
  ]);
  const run = scenarioStates(split, 10);

  it("confines both votes to the equivocator's side until healing", () => {
    const last = run[10];
    if (!last) throw new Error("missing state");
    const delivery = scenarioDelivery(split);
    const votesOfV0At = (observer: number, slot: number) =>
      viewOf(last.log, observer, slot, delivery).votes.filter(
        (v) => v.validator === 0 && v.slot === 3,
      );
    expect(votesOfV0At(1, 6)).toHaveLength(2);
    expect(votesOfV0At(2, 6)).toHaveLength(0);
    expect(votesOfV0At(2, 7)).toHaveLength(2);
  });

  it("resolves the same latest vote for the equivocator everywhere after healing", () => {
    const last = run[10];
    if (!last) throw new Error("missing state");
    const delivery = scenarioDelivery(split);
    const resolved = [0, 1, 2, 3].map((observer) =>
      latestVotes(viewOf(last.log, observer, 10, delivery).votes).get(0),
    );
    expect(resolved[0]).toBeDefined();
    for (const r of resolved) expect(r).toEqual(resolved[0]);
    expect(new Set(last.heads.values()).size).toBe(1);
  });
});
