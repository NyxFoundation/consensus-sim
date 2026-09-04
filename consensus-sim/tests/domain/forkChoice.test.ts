import { describe, expect, it } from "vitest";
import {
  ANCHOR_BLOCK_INDEX,
  ANCHOR_CHECKPOINT,
  EMPTY_BODY,
  addBlock,
  countedVotes,
  createBlockTree,
  ghostHead,
  latestVotes,
  subtreeWeight,
  type ProposedBlock,
  type Vote,
} from "../../src/domain";

const block = (
  index: number,
  parent: number,
  slot: number,
  proposer = 0,
): ProposedBlock => ({
  kind: "proposed",
  index,
  parent,
  slot,
  proposer,
  body: EMPTY_BODY,
});

const vote = (
  validator: number,
  slot: number,
  head: number,
  source = ANCHOR_CHECKPOINT,
  target = ANCHOR_CHECKPOINT,
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

describe("countedVotes", () => {
  const votes = [vote(0, 1, 1), vote(0, 2, 2), vote(1, 1, 3)];

  it("keeps each validator's latest vote under LMD-GHOST", () => {
    expect(countedVotes(votes).map((v) => v.head)).toEqual([2, 3]);
    expect(countedVotes(votes, "LMD-GHOST").map((v) => v.head)).toEqual([2, 3]);
  });

  it("keeps every vote under GHOST", () => {
    expect(countedVotes(votes, "GHOST")).toEqual(votes);
  });
});

describe("subtreeWeight", () => {
  it("counts the given votes for heads in the subtree", () => {
    const counted = countedVotes([vote(0, 3, 2), vote(1, 3, 1), vote(2, 3, 4)]);
    expect(subtreeWeight(tree, counted, 1)).toBe(2);
    expect(subtreeWeight(tree, counted, 3)).toBe(1);
    expect(subtreeWeight(tree, counted, ANCHOR_BLOCK_INDEX)).toBe(3);
  });

  it("ignores votes whose head is unknown to the tree", () => {
    expect(subtreeWeight(tree, [vote(0, 3, 99)], ANCHOR_BLOCK_INDEX)).toBe(0);
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

  it("descends only into candidate blocks when a candidate set is given", () => {
    const votes = [vote(0, 3, 2), vote(1, 3, 4), vote(2, 3, 4)];
    const candidates = new Set([ANCHOR_BLOCK_INDEX, 1, 2]);
    expect(ghostHead(tree, votes, ANCHOR_BLOCK_INDEX, { candidates })).toBe(2);
    // No candidate child: the descent stops at the root.
    expect(ghostHead(tree, votes, ANCHOR_BLOCK_INDEX, { candidates: new Set() })).toBe(
      ANCHOR_BLOCK_INDEX,
    );
  });

  it("rejects a root missing from the tree", () => {
    expect(() => ghostHead(tree, [], 42)).toThrow(/root/);
  });
});
