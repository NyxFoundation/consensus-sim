import { describe, expect, it } from "vitest";
import {
  ANCHOR_BLOCK_INDEX,
  EMPTY_BODY,
  addBlock,
  createBlockTree,
  ghostHead,
  latestVotes,
  subtreeWeight,
  type Block,
  type Vote,
} from "../../src/domain";

const block = (
  index: number,
  parent: number,
  slot: number,
  proposer = 0,
): Block => ({ index, parent, slot, proposer, body: EMPTY_BODY });

const vote = (
  validator: number,
  slot: number,
  head: number,
  source = 0,
  target = 0,
): Vote => ({ validator, slot, head, source, target });

// anchor(0) ─ 1 ─ 2      (branch A)
//         └─ 3 ─ 4      (branch B)
const tree = [
  block(1, 0, 1),
  block(2, 1, 2),
  block(3, 0, 2, 1),
  block(4, 3, 3, 2),
].reduce(addBlock, createBlockTree());

describe("latestVotes", () => {
  it("keeps only the highest-slot vote per validator", () => {
    const latest = latestVotes([vote(0, 1, 1), vote(0, 2, 2), vote(1, 1, 3)]);
    expect(latest.get(0)?.head).toBe(2);
    expect(latest.get(1)?.head).toBe(3);
  });

  it("resolves same-slot equivocation order-independently", () => {
    const a = vote(0, 2, 1);
    const b = vote(0, 2, 3);
    expect(latestVotes([a, b]).get(0)?.head).toBe(1);
    expect(latestVotes([b, a]).get(0)?.head).toBe(1);
  });
});

describe("subtreeWeight", () => {
  it("counts latest votes for heads in the subtree", () => {
    const latest = latestVotes([vote(0, 3, 2), vote(1, 3, 1), vote(2, 3, 4)]);
    expect(subtreeWeight(tree, latest, 1)).toBe(2);
    expect(subtreeWeight(tree, latest, 3)).toBe(1);
    expect(subtreeWeight(tree, latest, ANCHOR_BLOCK_INDEX)).toBe(3);
  });

  it("ignores votes whose head is unknown to the tree", () => {
    const latest = latestVotes([vote(0, 3, 99)]);
    expect(subtreeWeight(tree, latest, ANCHOR_BLOCK_INDEX)).toBe(0);
  });
});

describe("ghostHead", () => {
  it("follows the heavier branch", () => {
    const votes = [vote(0, 3, 2), vote(1, 3, 4), vote(2, 3, 4)];
    expect(ghostHead(tree, votes, ANCHOR_BLOCK_INDEX)).toBe(4);
  });

  it("breaks weight ties toward the smaller block index", () => {
    const votes = [vote(0, 3, 2), vote(1, 3, 4)];
    expect(ghostHead(tree, votes, ANCHOR_BLOCK_INDEX)).toBe(2);
    expect(ghostHead(tree, [], ANCHOR_BLOCK_INDEX)).toBe(2);
  });

  it("descends only below the given root", () => {
    const votes = [vote(0, 3, 2), vote(1, 3, 4), vote(2, 3, 4)];
    expect(ghostHead(tree, votes, 1)).toBe(2);
  });

  it("rejects a root missing from the tree", () => {
    expect(() => ghostHead(tree, [], 42)).toThrow(/root/);
  });
});
