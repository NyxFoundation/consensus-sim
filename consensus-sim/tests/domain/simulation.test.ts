import { describe, expect, it } from "vitest";
import {
  DEFAULT_VALIDATOR_COUNT,
  advanceSlot,
  initialState,
  proposerForSlot,
  stateAtSlot,
  type SimulationConfig,
  type SimulationState,
} from "../../src/domain";

const config: SimulationConfig = {
  validatorCount: DEFAULT_VALIDATOR_COUNT,
  seed: 42,
};

describe("proposer schedule", () => {
  it("rotates round-robin over the validator set", () => {
    expect([1, 2, 3, 4, 5].map((s) => proposerForSlot(s, 4))).toEqual([
      1, 2, 3, 0, 1,
    ]);
  });
});

describe("slot progression", () => {
  it("starts at slot 0 with only the anchor and no votes", () => {
    const state = initialState(config);
    expect(state.slot).toBe(0);
    expect(state.tree.blocks.size).toBe(1);
    expect(state.votes).toEqual([]);
    expect([...state.heads.values()]).toEqual([0, 0, 0, 0]);
  });

  it("adds one proposal and one vote per validator each slot", () => {
    let state = initialState(config);
    state = advanceSlot(config, state);
    expect(state.slot).toBe(1);
    expect(state.tree.blocks.size).toBe(2);
    expect(state.votes.length).toBe(config.validatorCount);
    state = advanceSlot(config, state);
    expect(state.tree.blocks.size).toBe(3);
    expect(state.votes.length).toBe(2 * config.validatorCount);
  });

  it("keeps every validator on the same head while views are shared", () => {
    const state = stateAtSlot(config, 6);
    const heads = [...state.heads.values()];
    expect(new Set(heads).size).toBe(1);
    expect(heads[0]).toBe(6);
  });

  it("advances justification and finality along epoch boundaries", () => {
    // 4-slot epochs: epoch-1 checkpoint (slot 4) justifies at slot 4 and
    // finalizes when the epoch-2 checkpoint (slot 8) is justified.
    expect(stateAtSlot(config, 3).finality.justifiedHead).toBe(0);
    expect(stateAtSlot(config, 4).finality.justifiedHead).toBe(4);
    expect(stateAtSlot(config, 4).finality.finalized).toBe(0);
    expect(stateAtSlot(config, 8).finality.finalized).toBe(4);
    expect(stateAtSlot(config, 12).finality.finalized).toBe(8);
  });
});

describe("determinism (決定性)", () => {
  it("reproduces the identical state from the same scenario", () => {
    const a = stateAtSlot(config, 12);
    const b = stateAtSlot(config, 12);
    expect(b).toEqual(a);
  });

  it("is stable across validator counts in [4, 10]", () => {
    for (const validatorCount of [4, 7, 10]) {
      const cfg = { validatorCount, seed: 7 };
      expect(stateAtSlot(cfg, 9)).toEqual(stateAtSlot(cfg, 9));
    }
  });
});

describe("rewind (巻き戻し)", () => {
  it("recomputes exactly the state the run passed through", () => {
    const passedThrough: SimulationState[] = [initialState(config)];
    for (let s = 1; s <= 10; s++) {
      passedThrough.push(advanceSlot(config, passedThrough[s - 1]!));
    }
    for (const slot of [0, 1, 5, 10]) {
      expect(stateAtSlot(config, slot)).toEqual(passedThrough[slot]);
    }
  });

  it("rejects negative or fractional slots", () => {
    expect(() => stateAtSlot(config, -1)).toThrow();
    expect(() => stateAtSlot(config, 1.5)).toThrow();
  });
});
