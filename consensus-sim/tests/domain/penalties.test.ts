// Stakes and penalties (必須対応事項 25・26): initial stakes weigh fork choice
// and the FFG threshold; slashing zeroes an equivocator on the branch that
// includes the evidence (and only there, and only when on); the inactivity
// leak drains non-participants while finality stalls and stops once it
// resumes (and never runs when off).

import { describe, expect, it } from "vitest";
import {
  ANCHOR_CHECKPOINT,
  DEFAULT_INACTIVITY_LEAK,
  DEFAULT_PARAMS,
  EMPTY_BODY,
  PRESETS,
  addBlock,
  atEnd,
  bodyOf,
  chainStateOf,
  createBlockTree,
  epochOf,
  equalStakes,
  resolveView,
  scenarioStates,
  scheduleOf,
  viewOf,
  type BlockBody,
  type Equivocation,
  type Intervention,
  type ProposedBlock,
  type ProtocolParams,
  type Scenario,
  type InitialConditions,
  type Vote,
} from "../../src/domain";

const configOf = (
  params: ProtocolParams = DEFAULT_PARAMS,
  initialStakes: readonly number[] = equalStakes(4),
): InitialConditions => ({
  validatorCount: initialStakes.length,
  seed: 0,
  params,
  initialStakes,
});

const block = (
  index: number,
  parent: number,
  slot: number,
  proposer = 0,
  body: BlockBody = EMPTY_BODY,
): ProposedBlock => ({ kind: "proposed", index, parent, slot, proposer, body });

// source / target are block numbers on the linear chain() below, where block
// index equals slot (the anchor is index/slot 0), so epochOf(number) gives
// the checkpoint's own epoch directly.
const vote = (
  validator: number,
  slot: number,
  head: number,
  source = 0,
  target = 0,
): Vote => ({
  validator,
  slot,
  head,
  source: { epoch: epochOf(source), block: source },
  target: { epoch: epochOf(slot), block: target },
});

/** Linear chain, one block per slot (index n at slot n), bodies by slot. */
const chain = (upToSlot: number, bodies: Record<number, BlockBody> = {}) => {
  let tree = createBlockTree();
  for (let s = 1; s <= upToSlot; s++) {
    tree = addBlock(tree, block(s, s - 1, s, s % 4, bodies[s] ?? EMPTY_BODY));
  }
  return tree;
};

const stakesOf = (config: InitialConditions, tree: ReturnType<typeof chain>, at: number) =>
  [...chainStateOf(tree, at, config).stakes.values()];

describe("initial stakes (初期ステーク)", () => {
  // anchor ─ B1 (slot 1)      voted by validator 0
  //       └─ B2 (slot 2)      voted by validators 1 and 2
  const tree = [block(1, 0, 1, 1), block(2, 0, 2, 2)].reduce(addBlock, createBlockTree());
  const votes = [vote(0, 2, 1), vote(1, 2, 2), vote(2, 2, 2)];
  const view = { blockTree: tree, votes };

  it("default to equal stakes for everyone", () => {
    expect(equalStakes(5)).toEqual([32, 32, 32, 32, 32]);
    expect(stakesOf(configOf(), chain(2), 2)).toEqual([32, 32, 32, 32]);
  });

  it("weigh fork choice: one heavy validator outweighs two light ones", () => {
    const light = configOf(PRESETS.phase0);
    const heavy = configOf(PRESETS.phase0, [100, 32, 32, 32]);
    expect(resolveView(view, light, scheduleOf(light), 2).head).toBe(2);
    expect(resolveView(view, heavy, scheduleOf(heavy), 2).head).toBe(1);
  });

  it("weigh the FFG threshold: 2/3 of the stake, not of the validators", () => {
    const lone = { 5: { votes: [vote(0, 4, 4, 0, 4)], evidence: [] } };
    expect(chainStateOf(chain(6, lone), 6, configOf()).justified).toEqual(ANCHOR_CHECKPOINT);
    expect(
      chainStateOf(chain(6, lone), 6, configOf(DEFAULT_PARAMS, [100, 32, 32, 32])).justified,
    ).toEqual(ANCHOR_CHECKPOINT);
    expect(
      chainStateOf(chain(6, lone), 6, configOf(DEFAULT_PARAMS, [200, 32, 32, 32])).justified,
    ).toEqual({ epoch: 1, block: 4 });
  });
});

describe("slashing (スラッシング)", () => {
  const evidence: Equivocation = {
    kind: "double-vote",
    votes: [vote(3, 4, 3, 0, 4), vote(3, 4, 4, 0, 4)],
  };
  // anchor ─ 1 ─ 2 ─ 3 ─ 4 ─ 5 (includes evidence against 3 + two link votes 0→4)
  //                     └─ 6 (slot 5, no evidence)
  const withEvidence = (params: ProtocolParams) => {
    let tree = chain(5, {
      5: { votes: [vote(0, 4, 4, 0, 4), vote(1, 4, 4, 0, 4)], evidence: [evidence] },
    });
    tree = addBlock(tree, block(6, 4, 5, 2));
    return { tree, config: configOf(params) };
  };

  it("zeroes the equivocator from the including block onward, on that branch only", () => {
    const { tree, config } = withEvidence(DEFAULT_PARAMS);
    expect(stakesOf(config, tree, 4)).toEqual([32, 32, 32, 32]);
    expect(stakesOf(config, tree, 5)).toEqual([32, 32, 32, 0]);
    expect(stakesOf(config, tree, 6)).toEqual([32, 32, 32, 32]);
  });

  it("does nothing when slashing is off", () => {
    const { tree, config } = withEvidence({ ...DEFAULT_PARAMS, slashing: false });
    expect(stakesOf(config, tree, 5)).toEqual([32, 32, 32, 32]);
  });

  it("zeroes the equivocator for every form of evidence (成功条件 22)", () => {
    // Slot 5's block carries one form per validator: デイブ's double
    // proposal, キャロル's cross-slot double vote (one target epoch, two
    // targets), ボブ's surround vote (epoch 0 → 2 around epoch 1 → 1).
    const forms: Equivocation[] = [
      { kind: "double-proposal", validator: 3, slot: 3, blocks: [3, 9] },
      { kind: "double-vote", votes: [vote(2, 4, 4, 0, 4), vote(2, 5, 3, 0, 3)] },
      {
        kind: "surround-vote",
        votes: [
          { validator: 1, slot: 5, head: 5, source: { epoch: 1, block: 4 }, target: { epoch: 1, block: 4 } },
          { validator: 1, slot: 8, head: 8, source: ANCHOR_CHECKPOINT, target: { epoch: 2, block: 8 } },
        ],
      },
    ];
    const tree = chain(5, { 5: { votes: [], evidence: forms } });
    expect(stakesOf(configOf(), tree, 4)).toEqual([32, 32, 32, 32]);
    expect(stakesOf(configOf(), tree, 5)).toEqual([32, 0, 0, 0]);
  });

  it("excludes the equivocator from the finality threshold", () => {
    // Two of the three remaining validators (64 of 96) justify 4; with the
    // equivocator still counted, 64 of 128 would not.
    expect(chainStateOf(withEvidence(DEFAULT_PARAMS).tree, 5, configOf()).justified).toEqual({
      epoch: 1,
      block: 4,
    });
    const off = withEvidence({ ...DEFAULT_PARAMS, slashing: false });
    expect(chainStateOf(off.tree, 5, off.config).justified).toEqual(ANCHOR_CHECKPOINT);
  });

  it("excludes the equivocator's votes from fork choice on the evidence branch", () => {
    const { tree, config } = withEvidence(DEFAULT_PARAMS);
    const { weights } = resolveView(
      { blockTree: tree, votes: [] },
      config,
      scheduleOf(config),
      5,
    );
    expect(weights.weightOf(vote(3, 5, 5))).toBe(0);
    expect(weights.weightOf(vote(3, 5, 6))).toBe(32);
    expect(weights.weightOf(vote(0, 5, 5))).toBe(32);
  });

  it("arises in the simulation: a double vote is slashed by the next block", () => {
    const run = (params: ProtocolParams) =>
      scenarioStates(
        {
          config: configOf(params),
          interventions: [{ kind: "double-vote", slot: 2, validator: 1 }],
        },
        4,
      );
    const states = run(DEFAULT_PARAMS);
    const stakeAt = (blockIndex: number, v: number) =>
      states[4]!.chainStates.get(blockIndex)!.stakes.get(v);
    expect(bodyOf(states[3]!.tree.blocks.get(3)!).evidence).toHaveLength(1);
    expect(stakeAt(2, 1)).toBe(32);
    expect(stakeAt(3, 1)).toBe(0);
    expect(stakeAt(4, 1)).toBe(0);
    // Every validator's head is on the slashed branch, so ボブ's vote weighs 0
    // in everyone's fork choice from then on.
    const finalConfig = configOf();
    const { weights } = resolveView(
      viewOf(states[4]!.log, 0, atEnd(4)),
      finalConfig,
      scheduleOf(finalConfig),
      4,
    );
    expect(weights.weightOf(vote(1, 4, 4))).toBe(0);
    expect(weights.weightOf(vote(0, 4, 4))).toBe(32);
    expect(run({ ...DEFAULT_PARAMS, slashing: false })[4]!.chainStates.get(4)!.stakes.get(1)).toBe(32);
  });
});

describe("inactivity leak", () => {
  // デイブ (3) is silent for good; キャロル (2) is silent through slot 25.
  // With two of four voting (64 of 128) nothing justifies, so finality
  // stalls at the anchor: epoch 5 is the first whose finality delay exceeds
  // N = 4, and it is processed at the first block of epoch 6 (slot 24).
  const interventions: Intervention[] = [
    { kind: "stop", fromSlot: 1, validators: [3] },
    { kind: "stop", fromSlot: 1, toSlot: 25, validators: [2] },
  ];
  const scenario = (params: ProtocolParams): Scenario => ({ config: configOf(params), interventions });
  const headStakes = (params: ProtocolParams, slot: number) => {
    const state = scenarioStates(scenario(params), slot)[slot]!;
    return [...state.chainStates.get(state.heads.get(0)!)!.stakes.values()];
  };
  const headFinalized = (params: ProtocolParams, slot: number) => {
    const state = scenarioStates(scenario(params), slot)[slot]!;
    return state.chainStates.get(state.heads.get(0)!)!.finalized;
  };

  it("drains non-participants by r per epoch once finality has stalled N epochs", () => {
    expect(headStakes(DEFAULT_PARAMS, 23)).toEqual([32, 32, 32, 32]);
    expect(headStakes(DEFAULT_PARAMS, 24)).toEqual([32, 32, 24, 24]);
    expect(headStakes(DEFAULT_PARAMS, 27)).toEqual([32, 32, 24, 24]);
  });

  it("spares a validator that participates again and stops once finality resumes", () => {
    // キャロル votes from slot 26: epoch 6 leaks only デイブ (slot 28)…
    expect(headStakes(DEFAULT_PARAMS, 28)).toEqual([32, 32, 24, 18]);
    // …and with 88 of 112 voting, epoch 6 gets finalized during epoch 7,
    // so epoch 7 (processed at slot 32) leaks nobody, デイブ included.
    expect(headFinalized(DEFAULT_PARAMS, 31)).not.toEqual(ANCHOR_CHECKPOINT);
    expect(headStakes(DEFAULT_PARAMS, 32)).toEqual([32, 32, 24, 18]);
    expect(headStakes(DEFAULT_PARAMS, 36)).toEqual([32, 32, 24, 18]);
  });

  it("never runs when off, and follows its own N and r when on", () => {
    const off: ProtocolParams = { ...DEFAULT_PARAMS, inactivityLeak: "off" };
    expect(headStakes(off, 36)).toEqual([32, 32, 32, 32]);
    expect(DEFAULT_INACTIVITY_LEAK).toEqual({ delayEpochs: 4, rate: 0.25 });
    const sooner: ProtocolParams = { ...DEFAULT_PARAMS, inactivityLeak: { delayEpochs: 2, rate: 0.5 } };
    // Epoch 3 is the first whose delay exceeds N = 2, processed at slot 16.
    expect(headStakes(sooner, 15)).toEqual([32, 32, 32, 32]);
    expect(headStakes(sooner, 16)).toEqual([32, 32, 16, 16]);
  });

  it("keeps the run deterministic", () => {
    expect(scenarioStates(scenario(DEFAULT_PARAMS), 36)).toEqual(
      scenarioStates(scenario(DEFAULT_PARAMS), 36),
    );
  });
});
