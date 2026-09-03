// The revised reference types: identifier sorts, checkpoints {epoch, block},
// the skeleton's total orders, and the FFG link validity they imply.

import { describe, expect, it } from "vitest";
import {
  ANCHOR_CHECKPOINT,
  DEFAULT_PARAMS,
  EMPTY_BODY,
  addBlock,
  anchorBlock,
  bodyOf,
  chainStateOf,
  checkpointFor,
  compareBlockIndex,
  compareCheckpoints,
  compareVoteContent,
  createBlockTree,
  equalStakes,
  higherCheckpoint,
  isCheckpointOn,
  type BlockIndex,
  type BlockBody,
  type Checkpoint,
  type ProposedBlock,
  type InitialConditions,
  type SlotIndex,
  type Vote,
} from "../../src/domain";

const config: InitialConditions = {
  validatorCount: 4,
  seed: 0,
  params: DEFAULT_PARAMS,
  initialStakes: equalStakes(4),
};

const block = (
  index: number,
  parent: number,
  slot: number,
  body: BlockBody = EMPTY_BODY,
): ProposedBlock => ({ kind: "proposed", index, parent, slot, proposer: index % 4, body });

const vote = (
  validator: number,
  slot: number,
  head: number,
  source: Checkpoint,
  target: Checkpoint,
): Vote => ({ validator, slot, head, source, target });

const votes = (voters: number[], slot: number, head: number, source: Checkpoint, target: Checkpoint) =>
  voters.map((v) => vote(v, slot, head, source, target));

describe("identifier sorts", () => {
  it("keeps the sorts apart while admitting number literals", () => {
    const slot: SlotIndex = 3;
    const index: BlockIndex = 3;
    // @ts-expect-error a slot is not a block index (混用を型検査で防ぐ)
    const mixed: BlockIndex = slot;
    expect(mixed).toBe(index);
  });

  it("has no sentinel on the anchor", () => {
    const anchor = anchorBlock();
    expect(anchor).toEqual({ kind: "anchor", index: 0, slot: 0 });
    expect("parent" in anchor).toBe(false);
    expect(bodyOf(anchor)).toEqual(EMPTY_BODY);
  });
});

describe("the skeleton's orders", () => {
  it("prefers the smaller block index and orders checkpoints by epoch first", () => {
    expect(compareBlockIndex(2, 5)).toBeLessThan(0);
    expect(compareCheckpoints({ epoch: 2, block: 9 }, { epoch: 1, block: 4 })).toBeLessThan(0);
    expect(compareCheckpoints({ epoch: 2, block: 3 }, { epoch: 2, block: 7 })).toBeLessThan(0);
    expect(higherCheckpoint({ epoch: 1, block: 4 }, { epoch: 2, block: 9 })).toEqual({ epoch: 2, block: 9 });
    expect(higherCheckpoint({ epoch: 2, block: 7 }, { epoch: 2, block: 3 })).toEqual({ epoch: 2, block: 3 });
  });

  it("orders vote content by head, then source, then target", () => {
    const a = vote(0, 5, 3, ANCHOR_CHECKPOINT, { epoch: 1, block: 3 });
    const b = vote(0, 5, 4, ANCHOR_CHECKPOINT, { epoch: 1, block: 4 });
    const c = vote(0, 5, 3, ANCHOR_CHECKPOINT, { epoch: 1, block: 4 });
    expect(compareVoteContent(a, b)).toBeLessThan(0);
    expect(compareVoteContent(a, c)).toBeLessThan(0);
    expect(compareVoteContent(c, a)).toBeGreaterThan(0);
    expect(compareVoteContent(a, { ...a })).toBe(0);
  });
});

describe("checkpoints of consecutive epochs on an empty boundary", () => {
  // anchor ─ B1(s1) ─ B2(s2) ─ B3(s3) ─ B9(s9) ─ B10(s10): slots 4..8 are
  // empty, so B3 stands for epoch 1 and for epoch 2 alike.
  const cp1: Checkpoint = { epoch: 1, block: 3 };
  const cp2: Checkpoint = { epoch: 2, block: 3 };
  const tree = [
    block(1, 0, 1),
    block(2, 1, 2),
    block(3, 2, 3),
    // Epoch-1 votes (slots 5..7) justify {1, B3}; included at slot 9.
    block(9, 3, 9, { votes: votes([0, 1, 2], 6, 3, ANCHOR_CHECKPOINT, cp1), evidence: [] }),
    // Epoch-2 votes link {1, B3} → {2, B3}: the same block, consecutive epochs.
    block(10, 9, 10, { votes: votes([0, 1, 2], 9, 9, cp1, cp2), evidence: [] }),
  ].reduce(addBlock, createBlockTree());

  it("derives the same block as the checkpoint of both epochs", () => {
    expect(checkpointFor(tree, 10, 1)).toEqual(cp1);
    expect(checkpointFor(tree, 10, 2)).toEqual(cp2);
    expect(checkpointFor(tree, 10, 0)).toEqual(ANCHOR_CHECKPOINT);
    expect(isCheckpointOn(tree, 10, { epoch: 1, block: 2 })).toBe(false);
  });

  it("counts the same-block link and finalizes by epoch adjacency", () => {
    expect(chainStateOf(tree, 9, config)).toMatchObject({ justified: cp1, finalized: ANCHOR_CHECKPOINT });
    expect(chainStateOf(tree, 10, config)).toMatchObject({ justified: cp2, finalized: cp1 });
  });
});

describe("link validity", () => {
  it("ignores a vote whose target is not the branch's checkpoint of its epoch", () => {
    // anchor ─ B1 ─ … ─ B5: epoch 1's checkpoint is B4, yet the votes
    // target B5 — a block of the branch, but not its checkpoint.
    const stray = votes([0, 1, 2], 5, 5, ANCHOR_CHECKPOINT, { epoch: 1, block: 5 });
    const tree = [
      block(1, 0, 1),
      block(2, 1, 2),
      block(3, 2, 3),
      block(4, 3, 4),
      block(5, 4, 5),
      block(6, 5, 6, { votes: stray, evidence: [] }),
    ].reduce(addBlock, createBlockTree());
    expect(chainStateOf(tree, 6, config).justified).toEqual(ANCHOR_CHECKPOINT);
  });

  it("ignores a link whose source epoch is not below its target epoch", () => {
    const flat = votes([0, 1, 2], 5, 5, { epoch: 1, block: 4 }, { epoch: 1, block: 4 });
    const tree = [
      block(1, 0, 1),
      block(2, 1, 2),
      block(3, 2, 3),
      block(4, 3, 4),
      block(5, 4, 5),
      block(6, 5, 6, { votes: flat, evidence: [] }),
    ].reduce(addBlock, createBlockTree());
    expect(chainStateOf(tree, 6, config).justified).toEqual(ANCHOR_CHECKPOINT);
  });
});
