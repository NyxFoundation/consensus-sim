import { describe, expect, it } from "vitest";
import {
  DEFAULT_PARAMS,
  DEFAULT_VALIDATOR_COUNT,
  equalStakes,
  instantDelivery,
  observe,
  stateAtSlot,
  viewOf,
  type Delivery,
  type SimulationConfig,
} from "../../src/domain";

const config: SimulationConfig = {
  validatorCount: DEFAULT_VALIDATOR_COUNT,
  seed: 42,
  params: DEFAULT_PARAMS,
  initialStakes: equalStakes(DEFAULT_VALIDATOR_COUNT),
};

describe("local views under instant delivery", () => {
  it("every local view equals the god view", () => {
    const state = stateAtSlot(config, 8);
    for (let v = 0; v < config.validatorCount; v++) {
      const view = viewOf(state.log, v, state.slot);
      expect(view.validator).toBe(v);
      expect(view.slot).toBe(state.slot);
      expect(view.blockTree).toEqual(state.tree);
      expect(view.votes).toEqual(state.votes);
    }
  });

  it("local head and its chain state match the god view", () => {
    const state = stateAtSlot(config, 8);
    for (let v = 0; v < config.validatorCount; v++) {
      const local = observe(state.log, v, state.slot, config);
      expect(local.head).toBe(state.heads.get(v));
      expect(local.chainState).toEqual(state.chainStates.get(local.head));
    }
  });

  it("a past-slot view sees only messages published by then", () => {
    const state = stateAtSlot(config, 8);
    const view = viewOf(state.log, 0, 3);
    expect(view.blockTree.blocks.size).toBe(4); // anchor + slots 1..3
    expect(view.votes.length).toBe(3 * config.validatorCount);
  });
});

// Partition {0,1} | {2,3} from slot 3 on; heals at slot `healAt`: messages
// across camps published while partitioned arrive once the observer's clock
// reaches healAt.
const partitioned = (healAt: number): Delivery => {
  const camp = (v: number) => (v <= 1 ? 0 : 1);
  return (sender, publishedAt, observer, atSlot) => {
    if (publishedAt > atSlot) return false;
    if (publishedAt < 3 || camp(sender) === camp(observer)) return true;
    return atSlot >= healAt;
  };
};

describe("local views under a partition", () => {
  const never = partitioned(Number.MAX_SAFE_INTEGER);

  it("views diverge across camps and stay equal within a camp", () => {
    const state = stateAtSlot(config, 6, never);
    const [a, b, c, d] = [0, 1, 2, 3].map((v) =>
      viewOf(state.log, v, state.slot, never),
    );
    expect(a!.blockTree).toEqual(b!.blockTree);
    expect(c!.blockTree).toEqual(d!.blockTree);
    expect(a!.blockTree).not.toEqual(c!.blockTree);
    expect(a!.votes).not.toEqual(c!.votes);
  });

  it("heads diverge between camps", () => {
    const state = stateAtSlot(config, 6, never);
    expect(state.heads.get(0)).toBe(state.heads.get(1));
    expect(state.heads.get(2)).toBe(state.heads.get(3));
    expect(state.heads.get(0)).not.toBe(state.heads.get(2));
  });

  it("the god view still holds every published block", () => {
    const state = stateAtSlot(config, 6, never);
    expect(state.tree.blocks.size).toBe(7); // anchor + one block per slot
  });

  it("views converge again after the partition heals", () => {
    const heal = partitioned(9);
    const state = stateAtSlot(config, 10, heal);
    const views = [0, 1, 2, 3].map((v) =>
      viewOf(state.log, v, state.slot, heal),
    );
    for (const view of views.slice(1)) {
      expect(view.blockTree).toEqual(views[0]!.blockTree);
      expect([...view.votes].sort((x, y) => x.slot - y.slot || x.validator - y.validator))
        .toEqual([...views[0]!.votes].sort((x, y) => x.slot - y.slot || x.validator - y.validator));
    }
    expect(new Set(state.heads.values()).size).toBe(1);
  });

  it("skips a visible block whose parent is not visible", () => {
    // Deliver only even-indexed blocks to observer 0: odd parents missing.
    const oddDropped: Delivery = (sender, publishedAt, observer, atSlot) => {
      if (publishedAt > atSlot) return false;
      return observer !== 0 || sender % 2 === 0;
    };
    const state = stateAtSlot(config, 4, oddDropped);
    const view = viewOf(state.log, 0, state.slot, oddDropped);
    // proposers rotate 1,2,3,0 → blocks from proposers 2 and 0 are sent, but
    // the chain is linear, so a missing odd ancestor orphans what follows.
    expect(view.blockTree.blocks.size).toBeLessThan(state.tree.blocks.size);
    for (const block of view.blockTree.blocks.values()) {
      if (block.index !== 0) {
        expect(view.blockTree.blocks.has(block.parent)).toBe(true);
      }
    }
  });
});

describe("determinism with a custom delivery", () => {
  it("the same partitioned scenario reproduces the same state", () => {
    const heal = partitioned(9);
    expect(stateAtSlot(config, 10, heal)).toEqual(stateAtSlot(config, 10, heal));
  });

  it("instantDelivery is the identity case of the delivery parameter", () => {
    expect(stateAtSlot(config, 8, instantDelivery)).toEqual(
      stateAtSlot(config, 8),
    );
  });
});
