import { describe, expect, it } from "vitest";
import {
  ANCHOR_BLOCK_INDEX,
  NO_PARENT,
  NO_PROPOSER,
  START_SLOT,
  addBlock,
  anchorBlock,
  childrenOf,
  createBlockTree,
  getBlock,
  hasBlock,
  isAncestor,
  leafIndices,
  pathToAnchor,
  type Block,
} from "../../src/domain";

const block = (
  index: number,
  parent: number,
  slot: number,
  proposer = 0,
): Block => ({ index, parent, slot, proposer });

describe("anchor block", () => {
  it("is block 0 at slot 0 with no parent and no proposer", () => {
    expect(anchorBlock()).toEqual({
      index: ANCHOR_BLOCK_INDEX,
      parent: NO_PARENT,
      slot: START_SLOT,
      proposer: NO_PROPOSER,
    });
  });

  it("is the only block of a fresh tree", () => {
    const tree = createBlockTree();
    expect([...tree.blocks.keys()]).toEqual([ANCHOR_BLOCK_INDEX]);
    expect(getBlock(tree, ANCHOR_BLOCK_INDEX)).toEqual(anchorBlock());
  });
});

describe("addBlock", () => {
  it("adds a child of the anchor", () => {
    const tree = addBlock(createBlockTree(), block(1, 0, 1));
    expect(hasBlock(tree, 1)).toBe(true);
    expect(childrenOf(tree, 0)).toEqual([1]);
  });

  it("does not mutate the original tree", () => {
    const before = createBlockTree();
    addBlock(before, block(1, 0, 1));
    expect(hasBlock(before, 1)).toBe(false);
  });

  it("is a no-op for an identical duplicate", () => {
    const tree = addBlock(createBlockTree(), block(1, 0, 1));
    expect(addBlock(tree, block(1, 0, 1))).toBe(tree);
  });

  it("rejects a conflicting block at an existing index", () => {
    const tree = addBlock(createBlockTree(), block(1, 0, 1));
    expect(() => addBlock(tree, block(1, 0, 2))).toThrow(/different content/);
  });

  it("rejects an unknown parent", () => {
    expect(() => addBlock(createBlockTree(), block(2, 9, 1))).toThrow(
      /unknown/,
    );
  });

  it("rejects a second root", () => {
    expect(() =>
      addBlock(createBlockTree(), block(1, NO_PARENT, 1)),
    ).toThrow(/anchor/);
  });

  it("rejects a slot not after the parent's slot", () => {
    const tree = addBlock(createBlockTree(), block(1, 0, 2));
    expect(() => addBlock(tree, block(2, 1, 2))).toThrow(/after parent/);
  });
});

describe("tree queries", () => {
  // anchor(0) ─ 1 ─ 2
  //         └─ 3
  const tree = [block(1, 0, 1), block(2, 1, 2), block(3, 0, 2, 1)].reduce(
    addBlock,
    createBlockTree(),
  );

  it("childrenOf returns ordered children", () => {
    expect(childrenOf(tree, 0)).toEqual([1, 3]);
    expect(childrenOf(tree, 2)).toEqual([]);
  });

  it("isAncestor walks the parent chain, inclusive", () => {
    expect(isAncestor(tree, 0, 2)).toBe(true);
    expect(isAncestor(tree, 1, 2)).toBe(true);
    expect(isAncestor(tree, 2, 2)).toBe(true);
    expect(isAncestor(tree, 3, 2)).toBe(false);
    expect(isAncestor(tree, 2, 1)).toBe(false);
  });

  it("pathToAnchor lists the chain from the block to the root", () => {
    expect(pathToAnchor(tree, 2).map((b) => b.index)).toEqual([2, 1, 0]);
  });

  it("leafIndices lists blocks without children", () => {
    expect(leafIndices(tree)).toEqual([2, 3]);
    expect(leafIndices(createBlockTree())).toEqual([0]);
  });
});
