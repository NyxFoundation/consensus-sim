// Fork count (フォーク数, 必須 10): the number of leaves of the god-view
// subtree rooted at the latest finalized block, and the projection of that
// count over pending fork designations that the UI (and later the attack
// strategies) check against MAX_FORKS.

import { describe, expect, it } from "vitest";
import {
  DEFAULT_PARAMS,
  MAX_FORKS,
  equalStakes,
  forkCount,
  forkCountAfter,
  latestFinalized,
  leavesUnder,
  pendingForkParents,
  scenarioStates,
  type Intervention,
  type Scenario,
  type SimulationState,
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

const at = (s: Scenario, slot: number): SimulationState => {
  const state = scenarioStates(s, slot)[slot];
  if (!state) throw new Error("missing state");
  return state;
};

const count = (state: SimulationState) => forkCount(state.tree, state.chainStates);
const countAfter = (state: SimulationState, parents: number[]) =>
  forkCountAfter(state.tree, state.chainStates, parents);

describe("fork count (フォーク数)", () => {
  it("is 1 along an honest linear chain, and 1 on the anchor alone", () => {
    const honest = scenario([]);
    const states = scenarioStates(honest, 9);
    for (const state of states) expect(count(state)).toBe(1);
    expect(leavesUnder(states[0]!.tree, 0)).toEqual([0]);
  });

  it("counts a double proposal as a second fork until finality moves past it", () => {
    const s = scenario([{ kind: "double-propose", slot: 1, validator: 1 }]);
    // B1 and B2 are siblings on the anchor; the chain continues on B1
    // (B3 at slot 2, …, B5 at the epoch boundary slot 4).
    expect(count(at(s, 1))).toBe(2);
    expect(count(at(s, 8))).toBe(2);
    // Once B5 (on the B1 branch) is finalized, the orphan sibling B2 lies
    // outside the finalized subtree and no longer counts.
    const at9 = at(s, 9);
    expect(latestFinalized(at9.tree, at9.chainStates)).toBe(5);
    expect(count(at9)).toBe(1);
  });

  it("reaches 4 through designations on the anchor and drops when finality advances", () => {
    // B1 (honest), B2 and B3 designated on the anchor, B4 honest on the head
    // B1 at the epoch boundary, B5 designated on the anchor again.
    const s = scenario([
      { kind: "propose-parent", slot: 2, parent: 0 },
      { kind: "propose-parent", slot: 3, parent: 0 },
      { kind: "propose-parent", slot: 5, parent: 0 },
    ]);
    expect(count(at(s, 1))).toBe(1);
    expect(count(at(s, 2))).toBe(2);
    expect(count(at(s, 3))).toBe(3);
    const at4 = at(s, 4);
    expect(count(at4)).toBe(3);
    // Seen from slot 4, the slot-5 designation is pending and adds a fork.
    expect(countAfter(at4, pendingForkParents(s.interventions, 4))).toBe(4);
    const at5 = at(s, 5);
    expect(count(at5)).toBe(MAX_FORKS);
    // A further proposal on the anchor would exceed the limit; extending
    // the leaf B4 would not.
    expect(countAfter(at5, [0])).toBe(5);
    expect(countAfter(at5, [4])).toBe(4);
    // Honest slots afterwards build on B4: it is finalized at slot 9 and the
    // anchor-level forks stop counting.
    const at9 = at(s, 9);
    expect(latestFinalized(at9.tree, at9.chainStates)).toBe(4);
    expect(count(at9)).toBe(1);
    // The anchor is now outside the finalized subtree: designating it adds
    // nothing to the count by definition; forking B4 again adds one.
    expect(countAfter(at9, [0])).toBe(1);
    expect(countAfter(at9, [4])).toBe(2);
  });

  it("charges pending designations sequentially: a leaf extended twice forks once", () => {
    const at2 = at(scenario([]), 2); // B0 – B1 – B2, B2 the only leaf
    expect(countAfter(at2, [2])).toBe(1);
    expect(countAfter(at2, [2, 2])).toBe(2);
    expect(countAfter(at2, [1])).toBe(2);
    expect(countAfter(at2, [1, 2, 2])).toBe(3);
    // A parent not in the tree yet is outside the definition.
    expect(countAfter(at2, [99])).toBe(1);
  });

  it("lists the parents of the designations scheduled after a slot, in slot order", () => {
    const interventions: Intervention[] = [
      { kind: "propose-parent", slot: 6, parent: 3 },
      { kind: "stop", fromSlot: 3, validators: [0] },
      { kind: "propose-parent", slot: 4, parent: 1 },
      { kind: "propose-parent", slot: 2, parent: 0 },
    ];
    expect(pendingForkParents(interventions, 3)).toEqual([1, 3]);
    expect(pendingForkParents(interventions, 6)).toEqual([]);
  });

  it("does not constrain forks that arise from other interventions", () => {
    // Two double proposals plus a designation: 5 leaves under the anchor —
    // the count reports it; only fork designations are checked against it.
    const s = scenario([
      { kind: "double-propose", slot: 1, validator: 1 },
      { kind: "double-propose", slot: 2, validator: 2 },
      { kind: "propose-parent", slot: 3, parent: 0 },
      { kind: "double-propose", slot: 3, validator: 3 },
    ]);
    expect(count(at(s, 3))).toBeGreaterThan(MAX_FORKS);
  });
});
