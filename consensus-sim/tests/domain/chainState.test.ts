import { describe, expect, it } from "vitest";
import {
  ANCHOR_BLOCK_INDEX,
  DEFAULT_PARAMS,
  DEFAULT_STAKE,
  EMPTY_BODY,
  SLOTS_PER_EPOCH,
  addBlock,
  buildBody,
  chainStateOf,
  chainStatesOf,
  checkpointFor,
  checkpointStatus,
  createBlockTree,
  epochBoundarySlot,
  epochOf,
  equalStakes,
  equivocationsIn,
  evidenceRef,
  forkChoiceRoot,
  includedOn,
  isSupermajority,
  totalStake,
  voteKey,
  voteRef,
  type Block,
  type BlockBody,
  type BlockTree,
  type SimulationConfig,
  type Vote,
} from "../../src/domain";

const config: SimulationConfig = {
  validatorCount: 4,
  seed: 0,
  params: DEFAULT_PARAMS,
  initialStakes: equalStakes(4),
};
const stakes = new Map(config.initialStakes.map((s, v) => [v, s]));

const block = (
  index: number,
  parent: number,
  slot: number,
  proposer = 0,
  body: BlockBody = EMPTY_BODY,
): Block => ({ index, parent, slot, proposer, body });

const vote = (
  validator: number,
  slot: number,
  head: number,
  source: number,
  target: number,
): Vote => ({ validator, slot, head, source, target });

const withVotes = (votes: Vote[]): BlockBody => ({ votes, evidence: [] });

/** Linear chain, one block per slot (index n at slot n), bodies by slot. */
const chain = (upToSlot: number, bodies: Record<number, BlockBody> = {}) => {
  let tree = createBlockTree();
  for (let s = 1; s <= upToSlot; s++) {
    tree = addBlock(tree, block(s, s - 1, s, s % 4, bodies[s] ?? EMPTY_BODY));
  }
  return tree;
};

// Three of four validators voting the link source→target at slot `slot`.
const link = (slot: number, source: number, target: number, head = target) =>
  [0, 1, 2].map((v) => vote(v, slot, head, source, target));

describe("epoch math", () => {
  it("uses 4-slot epochs with slot 0 as an epoch head", () => {
    expect(SLOTS_PER_EPOCH).toBe(4);
    expect(epochOf(0)).toBe(0);
    expect(epochOf(3)).toBe(0);
    expect(epochOf(4)).toBe(1);
    expect(epochBoundarySlot(2)).toBe(8);
  });

  it("supermajority is 2/3 of the total stake", () => {
    expect(totalStake(stakes)).toBe(4 * DEFAULT_STAKE);
    expect(isSupermajority(3 * DEFAULT_STAKE, 4 * DEFAULT_STAKE)).toBe(true);
    expect(isSupermajority(2 * DEFAULT_STAKE, 4 * DEFAULT_STAKE)).toBe(false);
    expect(isSupermajority(4 * DEFAULT_STAKE, 6 * DEFAULT_STAKE)).toBe(true);
    expect(isSupermajority(7 * DEFAULT_STAKE, 10 * DEFAULT_STAKE)).toBe(true);
    expect(isSupermajority(6 * DEFAULT_STAKE, 10 * DEFAULT_STAKE)).toBe(false);
  });
});

describe("checkpointFor", () => {
  it("returns the epoch-boundary block on the head's chain", () => {
    const tree = chain(6);
    expect(checkpointFor(tree, 6, 1)).toBe(4);
    expect(checkpointFor(tree, 6, 0)).toBe(ANCHOR_BLOCK_INDEX);
  });

  it("falls back to the last block before an empty boundary slot", () => {
    let tree = chain(3);
    tree = addBlock(tree, block(5, 3, 5));
    expect(checkpointFor(tree, 5, 1)).toBe(3);
  });
});

describe("chain state derivation (チェーン状態)", () => {
  it("starts every branch with the anchor justified and finalized", () => {
    const states = chainStatesOf(chain(3), config);
    for (const state of states.values()) {
      expect(state.justified).toBe(ANCHOR_BLOCK_INDEX);
      expect(state.finalized).toBe(ANCHOR_BLOCK_INDEX);
      expect(state.stakes).toEqual(stakes);
    }
  });

  it("justifies a checkpoint only once a block includes the link", () => {
    const tree = chain(6, { 5: withVotes(link(4, 0, 4)) });
    const states = chainStatesOf(tree, config);
    expect(states.get(4)?.justified).toBe(0);
    expect(states.get(5)?.justified).toBe(4);
    expect(states.get(6)?.justified).toBe(4);
    expect(states.get(6)?.finalized).toBe(0);
  });

  it("completes a link whose votes are spread across blocks", () => {
    const [a, b, c] = link(4, 0, 4);
    const tree = chain(7, { 5: withVotes([a!, b!]), 6: withVotes([c!]) });
    const states = chainStatesOf(tree, config);
    expect(states.get(5)?.justified).toBe(0);
    expect(states.get(6)?.justified).toBe(4);
  });

  it("counts a validator once per link even when included twice", () => {
    const tree = chain(6, {
      5: withVotes([vote(0, 4, 4, 0, 4), vote(1, 4, 4, 0, 4)]),
      6: withVotes([vote(0, 5, 5, 0, 4)]),
    });
    expect(chainStateOf(tree, 6, config).justified).toBe(0);
  });

  it("finalizes the source of a justified adjacent-epoch link", () => {
    const tree = chain(10, {
      5: withVotes(link(4, 0, 4)),
      9: withVotes(link(8, 4, 8)),
    });
    const states = chainStatesOf(tree, config);
    expect(states.get(8)?.finalized).toBe(0);
    expect(states.get(9)?.justified).toBe(8);
    expect(states.get(9)?.finalized).toBe(4);
    expect(states.get(10)?.finalized).toBe(4);
  });

  it("does not finalize across a skipped epoch", () => {
    const tree = chain(13, {
      5: withVotes(link(4, 0, 4)),
      13: withVotes(link(12, 4, 12)),
    });
    const state = chainStateOf(tree, 13, config);
    expect(state.justified).toBe(12);
    expect(state.finalized).toBe(0);
  });

  it("ignores included votes whose checkpoints lie on another branch", () => {
    // anchor ─ 1 ─ 2 ─ 3 ─ 4 ─ 5      (branch A, checkpoint 4)
    //        └─ 9 (slot 4) ─ 10 (slot 5)   (branch B)
    let tree = chain(5, { 5: withVotes(link(4, 0, 4)) });
    tree = addBlock(tree, block(9, 0, 4, 1));
    tree = addBlock(tree, block(10, 9, 5, 2, withVotes(link(4, 0, 4))));
    const states = chainStatesOf(tree, config);
    expect(states.get(5)?.justified).toBe(4);
    expect(states.get(10)?.justified).toBe(0);
  });

  it("is a pure function of the tree: recomputation is identical", () => {
    const tree = chain(10, {
      5: withVotes(link(4, 0, 4)),
      9: withVotes(link(8, 4, 8)),
    });
    expect(chainStatesOf(tree, config)).toEqual(chainStatesOf(tree, config));
  });
});

describe("checkpointStatus and forkChoiceRoot", () => {
  const tree: BlockTree = chain(10, {
    5: withVotes(link(4, 0, 4)),
    9: withVotes(link(8, 4, 8)),
  });

  it("lists every justified checkpoint and finalizes below the frontier", () => {
    const status = checkpointStatus(tree, config);
    expect([...status.justified].sort((a, b) => a - b)).toEqual([0, 4, 8]);
    expect([...status.finalized].sort((a, b) => a - b)).toEqual([0, 4]);
  });

  it("keeps an intermediate checkpoint justified when two links land at once", () => {
    // Votes for 0→4 and 4→12 both included in block 13: 4 never shows up as
    // any block's `justified`, yet it is justified on the branch.
    const late = chain(13, {
      13: withVotes([...link(4, 0, 4), ...link(12, 4, 12)]),
    });
    const status = checkpointStatus(late, config);
    expect(status.justified.has(4)).toBe(true);
    expect(status.justified.has(12)).toBe(true);
    expect(status.finalized.has(4)).toBe(false);
  });

  it("starts fork choice from the highest justified checkpoint known", () => {
    expect(forkChoiceRoot(tree, chainStatesOf(tree, config))).toBe(8);
    const early = chain(6, { 5: withVotes(link(4, 0, 4)) });
    expect(forkChoiceRoot(early, chainStatesOf(early, config))).toBe(4);
    expect(forkChoiceRoot(chain(3), chainStatesOf(chain(3), config))).toBe(0);
  });
});

describe("inclusion (取り込み) and evidence (証拠)", () => {
  it("detects a double proposal and a double vote in canonical order", () => {
    let tree = chain(2);
    tree = addBlock(tree, block(7, 1, 2, 2)); // second block by proposer 2 at slot 2
    const votes = [vote(1, 2, 2, 0, 0), vote(1, 2, 7, 0, 0), vote(0, 2, 2, 0, 0)];
    const evidence = equivocationsIn(tree, votes);
    expect(evidence).toEqual([
      { kind: "double-proposal", validator: 2, slot: 2, blocks: [2, 7] },
      {
        kind: "double-vote",
        validator: 1,
        slot: 2,
        votes: [vote(1, 2, 2, 0, 0), vote(1, 2, 7, 0, 0)],
      },
    ]);
    expect(equivocationsIn(tree, [...votes].reverse())).toEqual(evidence);
  });

  it("treats a duplicate of the same vote as no equivocation", () => {
    const tree = chain(2);
    const v = vote(1, 2, 2, 0, 0);
    expect(equivocationsIn(tree, [v, { ...v }])).toEqual([]);
  });

  it("builds a body from everything not yet included on the branch", () => {
    const early = link(4, 0, 4);
    const tree = chain(5, { 5: withVotes(early) });
    const later = [vote(3, 4, 4, 0, 4), vote(0, 5, 5, 0, 4)];
    const body = buildBody(tree, [...early, ...later], 5);
    expect(body.votes).toEqual(later);
    expect(body.evidence).toEqual([]);
    const included = includedOn(tree, 5);
    for (const v of early) expect(included.votes.has(voteKey(v))).toBe(true);
  });

  it("includes evidence once and honours omissions", () => {
    let tree = chain(2);
    tree = addBlock(tree, block(7, 1, 2, 2));
    const votes = [vote(1, 2, 2, 0, 0), vote(1, 2, 7, 0, 0)];
    const first = buildBody(tree, votes, 2);
    expect(first.evidence.map((e) => e.kind)).toEqual([
      "double-proposal",
      "double-vote",
    ]);
    // Once a block on the branch carries the evidence, it is not repeated.
    const carrying = addBlock(tree, block(8, 2, 3, 3, first));
    expect(buildBody(carrying, votes, 8)).toEqual({ votes: [], evidence: [] });
    // Omissions (取り込みの省略) leave the named items out.
    const omitted = buildBody(tree, votes, 2, {
      votes: [voteRef(votes[0]!)],
      evidence: [evidenceRef(first.evidence[0]!)],
    });
    expect(omitted.votes).toEqual([votes[1]]);
    expect(omitted.evidence.map((e) => e.kind)).toEqual(["double-vote"]);
  });
});
