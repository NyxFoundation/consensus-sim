import { describe, expect, it } from "vitest";
import {
  ANCHOR_BLOCK_INDEX,
  SLOTS_PER_EPOCH,
  addBlock,
  checkpointFor,
  computeFinality,
  createBlockTree,
  epochBoundarySlot,
  epochOf,
  supermajority,
  type Block,
  type Vote,
} from "../../src/domain";

const block = (
  index: number,
  parent: number,
  slot: number,
  proposer = 0,
): Block => ({ index, parent, slot, proposer });

const vote = (
  validator: number,
  slot: number,
  head: number,
  source: number,
  target: number,
): Vote => ({ validator, slot, head, source, target });

// Linear chain, one block per slot: index n at slot n.
const chain = (upToSlot: number) => {
  let tree = createBlockTree();
  for (let s = 1; s <= upToSlot; s++) {
    tree = addBlock(tree, block(s, s - 1, s));
  }
  return tree;
};

describe("epoch math", () => {
  it("uses 4-slot epochs with slot 0 as an epoch head", () => {
    expect(SLOTS_PER_EPOCH).toBe(4);
    expect(epochOf(0)).toBe(0);
    expect(epochOf(3)).toBe(0);
    expect(epochOf(4)).toBe(1);
    expect(epochBoundarySlot(2)).toBe(8);
  });

  it("supermajority is the least integer ≥ 2/3", () => {
    expect(supermajority(4)).toBe(3);
    expect(supermajority(6)).toBe(4);
    expect(supermajority(10)).toBe(7);
  });
});

describe("checkpointFor", () => {
  it("returns the epoch-boundary block on the head's chain", () => {
    const tree = chain(6);
    expect(checkpointFor(tree, 6, 1)).toBe(4);
    expect(checkpointFor(tree, 6, 0)).toBe(ANCHOR_BLOCK_INDEX);
  });

  it("falls back to the last block before an empty boundary slot", () => {
    // slots 1, 2, 3, then 5: no block at boundary slot 4.
    let tree = chain(3);
    tree = addBlock(tree, block(5, 3, 5));
    expect(checkpointFor(tree, 5, 1)).toBe(3);
  });
});

describe("computeFinality", () => {
  const tree = chain(8);

  it("starts with only the anchor justified and finalized", () => {
    const f = computeFinality(tree, [], 4);
    expect([...f.justified]).toEqual([ANCHOR_BLOCK_INDEX]);
    expect(f.justifiedHead).toBe(ANCHOR_BLOCK_INDEX);
    expect(f.finalized).toBe(ANCHOR_BLOCK_INDEX);
  });

  it("justifies a target with a supermajority link from the anchor", () => {
    const votes = [0, 1, 2].map((v) => vote(v, 4, 4, 0, 4));
    const f = computeFinality(tree, votes, 4);
    expect(f.justified.has(4)).toBe(true);
    expect(f.justifiedHead).toBe(4);
    expect(f.finalized).toBe(ANCHOR_BLOCK_INDEX);
  });

  it("needs the threshold: two of four voters justify nothing", () => {
    const votes = [0, 1].map((v) => vote(v, 4, 4, 0, 4));
    const f = computeFinality(tree, votes, 4);
    expect(f.justified.has(4)).toBe(false);
  });

  it("counts a validator once per link even across slots", () => {
    const votes = [vote(0, 4, 4, 0, 4), vote(0, 5, 4, 0, 4), vote(1, 4, 4, 0, 4)];
    const f = computeFinality(tree, votes, 4);
    expect(f.justified.has(4)).toBe(false);
  });

  it("finalizes the source of a justified adjacent-epoch link", () => {
    const votes = [
      ...[0, 1, 2].map((v) => vote(v, 4, 4, 0, 4)),
      ...[0, 1, 2].map((v) => vote(v, 8, 8, 4, 8)),
    ];
    const f = computeFinality(tree, votes, 4);
    expect(f.justified.has(8)).toBe(true);
    expect(f.justifiedHead).toBe(8);
    expect(f.finalized).toBe(4);
  });

  it("does not finalize across a skipped epoch", () => {
    const longTree = chain(12);
    const votes = [
      ...[0, 1, 2].map((v) => vote(v, 4, 4, 0, 4)),
      // epoch 1 checkpoint → epoch 3 checkpoint: justifies, must not finalize
      ...[0, 1, 2].map((v) => vote(v, 12, 12, 4, 12)),
    ];
    const f = computeFinality(longTree, votes, 4);
    expect(f.justified.has(12)).toBe(true);
    expect(f.finalized).toBe(ANCHOR_BLOCK_INDEX);
  });

  it("rejects links whose target is not a descendant of the source", () => {
    // fork: 1' at slot 1 beside the chain
    const forked = addBlock(tree, block(99, 0, 1, 1));
    const votes = [0, 1, 2].map((v) => vote(v, 4, 4, 99, 4));
    const f = computeFinality(forked, votes, 4);
    expect(f.justified.has(4)).toBe(false);
  });
});
