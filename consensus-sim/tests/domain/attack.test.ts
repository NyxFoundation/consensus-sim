// The attack formal system (攻撃の形式体系, 必須 17・18・21, 必須 10): the
// triple's strategy runs at every slot boundary over the attackers' merged
// observation, its actions become the attackers' interventions of the slots
// ahead, and an action is discarded — kept with its reason — when it is not
// causal, outside the capability range, contradicted by a manual
// intervention of the same slot and validator, or past the fork limit.
// A fixed action list is a strategy; the whole run stays deterministic.

import { describe, expect, it } from "vitest";
import {
  DEFAULT_PARAMS,
  MAX_FORKS,
  basesOf,
  capabilityOf,
  compileDelivery,
  coversMessage,
  equalStakes,
  forkCountAfter,
  isProposed,
  observe,
  pendingForkParents,
  proposerForSlot,
  runScenario,
  sameRef,
  satisfiesCondition,
  scenarioStates,
  scheduleOf,
  voteRef,
  type Action,
  type Attack,
  type AttackInstance,
  type AttackerObservation,
  type DoubleVoteAction,
  type Intervention,
  type Scenario,
  type InitialConditions,
  type SimulationState,
  type Strategy,
  type Vote,
} from "../../src/domain";

const CONFIG: InitialConditions = {
  validatorCount: 4,
  seed: 0,
  params: DEFAULT_PARAMS,
  initialStakes: equalStakes(4),
};

const attackOf = (strategy: Strategy): Attack => ({
  attackers: { kind: "count", atLeast: 1 },
  goal: [{ kind: "reorg", count: 1 }],
  strategy,
});

const instance = (
  strategy: Strategy,
  attackers: number[],
  maxDelay = 2,
): AttackInstance => ({
  id: "test",
  attack: attackOf(strategy),
  attackers,
  params: { maxDelay },
});

/** A strategy that emits `actions` at the boundary `at` and nothing else. */
const emitAt =
  (at: number, actions: readonly Action[]): Strategy =>
  (observation) =>
    observation.slot === at ? actions : [];

const scenario = (
  interventions: Intervention[],
  attack?: AttackInstance,
): Scenario => ({
  config: CONFIG,
  interventions,
  ...(attack === undefined ? {} : { attack }),
});

const summary = (state: SimulationState) => ({
  blocks: state.tree.blocks.size,
  votes: state.votes.length,
  heads: [...state.heads.entries()],
});

describe("a fixed action list is a strategy (固定介入列は戦略の特殊ケース)", () => {
  const silence: Action = { kind: "stop", fromSlot: 2, toSlot: 3, validators: [1] };
  const withAttack = scenario([], instance(emitAt(1, [silence]), [1]));
  const manual = scenario([silence]);

  it("generates the action at the boundary, marked with it, and runs identically to the manual scenario", () => {
    const run = runScenario(withAttack, 6);
    expect(run.generated).toEqual([{ action: silence, generatedAt: 1 }]);
    expect(run.interventions).toEqual([silence]);
    const manualStates = scenarioStates(manual, 6);
    run.states.forEach((state, slot) => {
      expect(summary(state)).toEqual(summary(manualStates[slot]!));
    });
    // The silenced attacker proposes nothing at its slots 2 and 3… (proposer
    // of slot s is s mod 4, so 1 proposes at slot 1 and 5; it votes nothing
    // at 2 and 3): 4 voters at slot 1, 3 at slots 2 and 3, 4 again at 4.
    expect(run.states[4]!.votes.length).toBe(4 + 3 + 3 + 4);
  });

  it("is deterministic and prefix-consistent (決定性)", () => {
    const a = runScenario(withAttack, 8);
    const b = runScenario(withAttack, 8);
    expect(b.generated).toEqual(a.generated);
    expect(b.states.map(summary)).toEqual(a.states.map(summary));
    const short = runScenario(withAttack, 4);
    expect(short.generated).toEqual(a.generated.slice(0, short.generated.length));
    expect(short.states.map(summary)).toEqual(a.states.slice(0, 5).map(summary));
    // No attack ⇒ scenarioStates is the manual run.
    expect(scenarioStates(withAttack, 6).map(summary)).toEqual(
      scenarioStates(manual, 6).map(summary),
    );
  });
});

describe("the attackers' observation (攻撃者の観測状態)", () => {
  it("merges every attacker's view across a partition and carries the schedule", () => {
    const seen: AttackerObservation[] = [];
    const record: Strategy = (observation) => {
      seen.push(observation);
      return [];
    };
    // {0,1} | {2,3} partitioned from slot 1; the attackers 0 and 3 sit on
    // opposite sides, yet share everything instantly.
    const partition: Intervention = { kind: "partition", fromSlot: 1, groups: [[0, 1]] };
    const run = runScenario(scenario([partition], instance(record, [0, 3])), 4);
    const at3 = seen.find((o) => o.slot === 3)!;
    const state = run.states[3]!;
    const delivery = compileDelivery(run.interventions);
    const own = (v: number) => observe(state.log, v, 3, CONFIG, delivery).view;
    expect(own(0).blockTree.blocks.size).toBeLessThan(state.tree.blocks.size);
    expect(own(3).blockTree.blocks.size).toBeLessThan(state.tree.blocks.size);
    expect(at3.view.blockTree.blocks.size).toBe(state.tree.blocks.size);
    expect(at3.view.votes.length).toBe(state.votes.length);
    expect(at3.attackers).toEqual([0, 3]);
    expect(at3.slot).toBe(3);
    for (const slot of [4, 5, 9]) {
      expect(at3.schedule.proposerOf(slot)).toBe(proposerForSlot(slot, CONFIG));
      expect(at3.schedule.committeeOf(slot)).toEqual(new Set([0, 1, 2, 3]));
    }
    // One observation per boundary a slot was computed from: 0 … 3.
    expect(seen.map((o) => o.slot)).toEqual([0, 1, 2, 3]);
  });

  it("checks the attacker-set condition by count or by initial stake share", () => {
    expect(satisfiesCondition({ kind: "count", atLeast: 2 }, [0, 1], CONFIG)).toBe(true);
    expect(satisfiesCondition({ kind: "count", atLeast: 3 }, [0, 1], CONFIG)).toBe(false);
    expect(satisfiesCondition({ kind: "stake-ratio", atLeast: 1 / 3 }, [0], CONFIG)).toBe(false);
    expect(satisfiesCondition({ kind: "stake-ratio", atLeast: 1 / 3 }, [0, 1], CONFIG)).toBe(
      true,
    );
    const skewed = { ...CONFIG, initialStakes: [64, 32, 16, 16] };
    expect(satisfiesCondition({ kind: "stake-ratio", atLeast: 0.5 }, [0], skewed)).toBe(true);
  });
});

describe("the capability range (攻撃者の能力範囲, 必須 18)", () => {
  const schedule = scheduleOf(CONFIG);
  const cap = (action: Action, attackers = [1], maxDelay = 2) =>
    capabilityOf(action, attackers, schedule, maxDelay);

  /** A minimal well-formed Vote, for tests that only need a concrete
   * individual to make a message reference exact. */
  const dummyVote = (validator: number, slot: number, head: number): Vote => ({
    validator,
    slot,
    head,
    source: { epoch: 0, block: 0 },
    target: { epoch: 0, block: 0 },
  });

  it("classifies each action by the capability it exercises", () => {
    expect(cap({ kind: "double-propose", slot: 5, validator: 1 })).toBe("equivocation");
    expect(cap({ kind: "double-vote", slot: 5, validator: 1 })).toBe("equivocation");
    expect(cap({ kind: "vote-target", slot: 5, validator: 1, head: 0 })).toBe("vote-target");
    expect(cap({ kind: "stop", fromSlot: 5, validators: [1] })).toBe("silence");
    // Slot 5 is proposed by validator 1.
    expect(cap({ kind: "propose-parent", slot: 5, parent: 0 })).toBe("propose-parent");
    expect(cap({ kind: "omit-inclusion", slot: 5, votes: [] })).toBe("omit-inclusion");
    expect(
      cap({ kind: "delay", message: { kind: "proposal", sender: 1, slot: 5 }, untilSlot: 7 }),
    ).toBe("withhold");
    expect(
      cap({ kind: "drop", message: { kind: "vote", sender: 1, slot: 5 }, observers: [2] }),
    ).toBe("withhold");
    expect(
      cap({ kind: "delay", message: { kind: "proposal", sender: 2, slot: 6 }, untilSlot: 8 }),
    ).toBe("delay-honest");
    expect(cap({ kind: "drop", message: { kind: "vote", sender: 0, slot: 6 } })).toBe(
      "drop-honest",
    );
    expect(cap({ kind: "partition", fromSlot: 5, groups: [[0, 2]] })).toBe("partition");
  });

  it("puts acting as an honest validator, honest proposals and long delays of honest messages outside", () => {
    expect(cap({ kind: "double-vote", slot: 5, validator: 2 })).toBeUndefined();
    expect(cap({ kind: "stop", fromSlot: 5, validators: [1, 2] })).toBeUndefined();
    expect(cap({ kind: "vote-target", slot: 5, validator: 0, head: 0 })).toBeUndefined();
    // Slot 6 is proposed by validator 2.
    expect(cap({ kind: "propose-parent", slot: 6, parent: 0 })).toBeUndefined();
    expect(cap({ kind: "omit-inclusion", slot: 6 })).toBeUndefined();
    // d = 2: an honest message may be held at most 2 slots past its slot…
    expect(
      cap({ kind: "delay", message: { kind: "proposal", sender: 2, slot: 6 }, untilSlot: 9 }),
    ).toBeUndefined();
    expect(
      cap({ kind: "delay", message: { kind: "proposal", sender: 2, slot: 6 }, untilSlot: 8 }),
    ).toBe("delay-honest");
    // …while the attacker's own message it may withhold for any length of
    // time (公開の時機は任意), and drop honest messages outright.
    expect(
      cap({ kind: "delay", message: { kind: "proposal", sender: 1, slot: 5 }, untilSlot: 20 }),
    ).toBe("withhold");
    expect(cap({ kind: "drop", message: { kind: "vote", sender: 0, slot: 6 } })).toBe("drop-honest");
    // A partition is the symmetric set of deliveries: closed within d it is a
    // delay, open it is a drop, closed but longer than d it is outside.
    expect(cap({ kind: "partition", fromSlot: 5, toSlot: 6, groups: [[0, 2]] })).toBe("partition");
    expect(cap({ kind: "partition", fromSlot: 5, groups: [[0, 2]] })).toBe("partition");
    expect(cap({ kind: "partition", fromSlot: 5, toSlot: 7, groups: [[0, 2]] })).toBeUndefined();
    // An honest message named by its individual (exact ref) is outside the
    // range: its content is not the attacker's to know in advance.
    expect(
      cap({
        kind: "delay",
        message: { kind: "proposal", sender: 2, slot: 6, block: 3 },
        untilSlot: 6,
      }),
    ).toBeUndefined();
    expect(
      cap({ kind: "drop", message: { kind: "vote", sender: 0, slot: 5, vote: dummyVote(0, 5, 4) } }),
    ).toBeUndefined();
  });

  it("expands every action into the two bases (公開 / 配送, 必須 18)", () => {
    const bases = (action: Action) => basesOf(action, [1], schedule);
    const vote5 = { kind: "vote", sender: 1, slot: 5 } as const;
    expect(bases({ kind: "double-vote", slot: 5, validator: 1 })).toEqual([
      { base: "publish", message: vote5, decides: "content" },
    ]);
    expect(
      bases({ kind: "double-vote", slot: 5, validator: 1, head: 9, split: { first: [0], second: [2], untilSlot: 7 } }),
    ).toEqual([
      { base: "publish", message: vote5, decides: "content" },
      { base: "publish", message: vote5, decides: "receivers" },
    ]);
    expect(bases({ kind: "vote-target", slot: 5, validator: 1, head: 0 })).toEqual([
      { base: "publish", message: vote5, decides: "content" },
    ]);
    // Parent designation and omission decide the content of the slot's proposal.
    const proposal5 = { kind: "proposal", sender: 1, slot: 5 } as const;
    expect(bases({ kind: "propose-parent", slot: 5, parent: 0 })).toEqual([
      { base: "publish", message: proposal5, decides: "content" },
    ]);
    expect(bases({ kind: "omit-inclusion", slot: 5 })).toEqual([
      { base: "publish", message: proposal5, decides: "content" },
    ]);
    expect(bases({ kind: "stop", fromSlot: 5, toSlot: 6, validators: [1] })).toEqual([
      { base: "publish", message: { senders: [1], fromSlot: 5, toSlot: 6 }, decides: "silence" },
    ]);
    // Delay / drop: own messages are publishes (timing / receivers), honest
    // ones deliveries (hold / drop).
    expect(bases({ kind: "delay", message: proposal5, untilSlot: 7 })).toEqual([
      { base: "publish", message: proposal5, decides: "timing" },
    ]);
    expect(bases({ kind: "drop", message: vote5, observers: [2] })).toEqual([
      { base: "publish", message: vote5, decides: "receivers" },
    ]);
    const honest6 = { kind: "proposal", sender: 2, slot: 6 } as const;
    expect(bases({ kind: "delay", message: honest6, untilSlot: 8, observers: [0] })).toEqual([
      { base: "deliver", message: honest6, hold: 2, observers: [0] },
    ]);
    expect(bases({ kind: "drop", message: honest6 })).toEqual([
      { base: "deliver", message: honest6, hold: "drop" },
    ]);
    // A partition: a delivery of the honest members' messages and a publish
    // (receivers) of the attacker's, over the span.
    expect(bases({ kind: "partition", fromSlot: 5, toSlot: 6, groups: [[0, 1], [2]] })).toEqual([
      { base: "deliver", message: { senders: [0, 2], fromSlot: 5, toSlot: 6 }, hold: 2 },
      { base: "publish", message: { senders: [1], fromSlot: 5, toSlot: 6 }, decides: "receivers" },
    ]);
    expect(bases({ kind: "partition", fromSlot: 5, groups: [[0, 2]] })).toEqual([
      { base: "deliver", message: { senders: [0, 2], fromSlot: 5 }, hold: "drop" },
    ]);
  });

  it("splits a double vote's two halves between two observer sets before untilSlot (選択配送)", () => {
    // Validator 1's double vote at slot 5: the primary half (head 4) reaches
    // `first` at once, the secondary half (the designated head 9) reaches
    // `second` at once, everyone else gets both only from slot 7 on.
    const primary = voteRef(dummyVote(1, 5, 4));
    const secondary = voteRef(dummyVote(1, 5, 9));
    const split: DoubleVoteAction = {
      kind: "double-vote",
      slot: 5,
      validator: 1,
      head: 9,
      split: { first: [0], second: [2], untilSlot: 7 },
    };
    const delivery = compileDelivery([split]);
    // Before untilSlot: observer 0 sees only the primary half…
    expect(delivery(1, 5, 0, 5, primary)).toBe(true);
    expect(delivery(1, 5, 0, 5, secondary)).toBe(false);
    // …and observer 2 sees only the secondary half.
    expect(delivery(1, 5, 2, 5, primary)).toBe(false);
    expect(delivery(1, 5, 2, 5, secondary)).toBe(true);
    // The sender always sees both.
    expect(delivery(1, 5, 1, 5, primary)).toBe(true);
    expect(delivery(1, 5, 1, 5, secondary)).toBe(true);
    // From untilSlot on, both halves reach everyone.
    expect(delivery(1, 5, 0, 7, secondary)).toBe(true);
    expect(delivery(1, 5, 2, 7, primary)).toBe(true);
  });

  it("names messages ahead of publication: proposal / vote references cover what the sender publishes in the slot", () => {
    const proposal = { kind: "proposal", sender: 1, slot: 5 } as const;
    expect(coversMessage(proposal, { kind: "proposal", sender: 1, slot: 5, block: 9 })).toBe(true);
    expect(coversMessage(proposal, { kind: "proposal", sender: 2, slot: 5, block: 9 })).toBe(false);
    expect(coversMessage(proposal, { kind: "proposal", sender: 1, slot: 6, block: 9 })).toBe(false);
    expect(
      coversMessage(proposal, { kind: "vote", sender: 1, slot: 5, vote: dummyVote(1, 5, 9) }),
    ).toBe(false);
    const vote = { kind: "vote", sender: 1, slot: 5 } as const;
    expect(coversMessage(vote, { kind: "vote", sender: 1, slot: 5, vote: dummyVote(1, 5, 9) })).toBe(
      true,
    );
    expect(coversMessage(vote, { kind: "vote", sender: 1, slot: 5, vote: dummyVote(1, 5, 4) })).toBe(
      true,
    );
    expect(coversMessage(vote, { kind: "vote", sender: 1, slot: 6, vote: dummyVote(1, 6, 9) })).toBe(
      false,
    );
    expect(sameRef(proposal, { kind: "proposal", sender: 1, slot: 5 })).toBe(true);
    expect(sameRef(proposal, vote)).toBe(false);
    expect(sameRef(vote, { kind: "vote", sender: 1, slot: 4 })).toBe(false);
  });

  it("withholds the attacker's own proposal by reference before it exists (保留と選択配送)", () => {
    // Validator 1 proposes at slot 1 and holds the block back from everyone
    // until slot 2: honest validators vote for the anchor at slot 1, and
    // see the block at slot 2.
    const hold: Action = {
      kind: "delay",
      message: { kind: "proposal", sender: 1, slot: 1 },
      untilSlot: 2,
    };
    const run = runScenario(scenario([], instance(emitAt(0, [hold]), [1], 1)), 2);
    expect(run.generated).toEqual([{ action: hold, generatedAt: 0 }]);
    const delivery = compileDelivery(run.interventions);
    const at1 = run.states[1]!;
    expect(at1.heads.get(1)).toBe(1);
    for (const honest of [0, 2, 3]) {
      expect(at1.heads.get(honest)).toBe(0);
      expect(observe(at1.log, honest, 1, CONFIG, delivery).view.blockTree.blocks.size).toBe(1);
    }
    const at2 = run.states[2]!;
    for (const honest of [0, 2, 3]) {
      expect(observe(at2.log, honest, 2, CONFIG, delivery).view.blockTree.blocks.has(1)).toBe(
        true,
      );
    }
  });
});

describe("discards (破棄の印付き)", () => {
  it("keeps an action that is not causal — a slot already computed — as discarded", () => {
    const late: Action = { kind: "double-vote", slot: 2, validator: 1 };
    const spanLate: Action = { kind: "stop", fromSlot: 1, validators: [1] };
    const run = runScenario(scenario([], instance(emitAt(2, [late, spanLate]), [1])), 4);
    expect(run.generated).toEqual([
      { action: late, generatedAt: 2, discarded: "not-causal" },
      { action: spanLate, generatedAt: 2, discarded: "not-causal" },
    ]);
    expect(run.interventions).toEqual([]);
  });

  it("discards actions outside the capability range and keeps the others", () => {
    const honestVote: Action = { kind: "double-vote", slot: 3, validator: 2 };
    const ownVote: Action = { kind: "double-vote", slot: 3, validator: 1 };
    const run = runScenario(scenario([], instance(emitAt(1, [honestVote, ownVote]), [1])), 4);
    expect(run.generated).toEqual([
      { action: honestVote, generatedAt: 1, discarded: "outside-capability" },
      { action: ownVote, generatedAt: 1 },
    ]);
    expect(run.interventions).toEqual([ownVote]);
    // The accepted double vote is real: validator 1 casts two votes at slot 3.
    const votesAt3 = run.states[3]!.votes.filter((v) => v.slot === 3 && v.validator === 1);
    expect(votesAt3).toHaveLength(2);
  });

  it("lets a manual intervention of the same slot and validator win (手動介入を優先)", () => {
    const manualSteer: Intervention = { kind: "vote-target", slot: 3, validator: 1, head: 0 };
    const manualStop: Intervention = { kind: "stop", fromSlot: 5, toSlot: 6, validators: [1] };
    const manualDelay: Intervention = {
      kind: "delay",
      message: { kind: "vote", sender: 1, slot: 7 },
      untilSlot: 8,
    };
    const manualPartition: Intervention = { kind: "partition", fromSlot: 4, toSlot: 5, groups: [[0, 1]] };
    const equivocate: Action = { kind: "double-vote", slot: 3, validator: 1 };
    const parent: Action = { kind: "propose-parent", slot: 5, parent: 0 };
    const withhold: Action = {
      kind: "delay",
      message: { kind: "vote", sender: 1, slot: 7 },
      untilSlot: 9,
    };
    const partition: Action = { kind: "partition", fromSlot: 5, toSlot: 6, groups: [[1, 2]] };
    const otherSlot: Action = { kind: "double-vote", slot: 4, validator: 1 };
    const otherAxis: Action = { kind: "partition", fromSlot: 6, toSlot: 6, groups: [[1, 2]] };
    const run = runScenario(
      scenario(
        [manualSteer, manualStop, manualDelay, manualPartition],
        instance(
          emitAt(2, [equivocate, parent, withhold, partition, otherSlot, otherAxis]),
          [1],
        ),
      ),
      3,
    );
    expect(run.generated.map((g) => g.discarded)).toEqual([
      "conflicts-with-manual", // same validator and slot as the manual vote designation
      "conflicts-with-manual", // slot 5 is proposed by 1, silenced by the manual stop
      "conflicts-with-manual", // the manual delay names the same attestation
      "conflicts-with-manual", // validator 1 is partitioned manually at slot 5
      undefined, // slot 4: no manual intervention on validator 1
      undefined, // slot 6: the manual stop is another axis
    ]);
    expect(run.interventions).toEqual([
      manualSteer,
      manualStop,
      manualDelay,
      manualPartition,
      otherSlot,
      otherAxis,
    ]);
  });

  it("applies the fork limit to generated fork creation (必須 10)", () => {
    // Manual designations on the anchor at slots 2, 3 and 5 reach the limit
    // as seen from slot 4 (3 forks + the pending one). Validator 2 proposes
    // slot 6: forking the anchor again is refused; extending its head is not.
    const manual: Intervention[] = [
      { kind: "propose-parent", slot: 2, parent: 0 },
      { kind: "propose-parent", slot: 3, parent: 0 },
      { kind: "propose-parent", slot: 5, parent: 0 },
    ];
    const at4 = scenarioStates(scenario(manual), 4)[4]!;
    const head = at4.heads.get(2)!;
    const pending = pendingForkParents(manual, 4);
    expect(forkCountAfter(at4.tree, at4.chainStates, [...pending, 0])).toBeGreaterThan(MAX_FORKS);
    expect(forkCountAfter(at4.tree, at4.chainStates, [...pending, head])).toBeLessThanOrEqual(
      MAX_FORKS,
    );
    const onAnchor: Action = { kind: "propose-parent", slot: 6, parent: 0 };
    const onHead: Action = { kind: "propose-parent", slot: 6, parent: head };
    const run = runScenario(scenario(manual, instance(emitAt(4, [onAnchor, onHead]), [2])), 6);
    expect(run.generated).toEqual([
      { action: onAnchor, generatedAt: 4, discarded: "fork-limit" },
      { action: onHead, generatedAt: 4 },
    ]);
    const b6 = [...run.states[6]!.tree.blocks.values()].filter(isProposed).find((b) => b.slot === 6)!;
    expect(b6.parent).toBe(head);
  });

  it("applies the fork limit to fork creation only: a generated double proposal is never fork-limited", () => {
    // The same saturated tree as above; the attacker's double proposal at
    // its slot 6 adds a sibling block, which 必須 10 leaves unconstrained
    // (forks that arise from equivocation are not fork creation).
    const manual: Intervention[] = [
      { kind: "propose-parent", slot: 2, parent: 0 },
      { kind: "propose-parent", slot: 3, parent: 0 },
      { kind: "propose-parent", slot: 5, parent: 0 },
    ];
    const onAnchor: Action = { kind: "propose-parent", slot: 6, parent: 0 };
    const double: Action = { kind: "double-propose", slot: 6, validator: 2 };
    const run = runScenario(scenario(manual, instance(emitAt(4, [onAnchor, double]), [2])), 6);
    expect(run.generated).toEqual([
      { action: onAnchor, generatedAt: 4, discarded: "fork-limit" },
      { action: double, generatedAt: 4 },
    ]);
    const at6 = [...run.states[6]!.tree.blocks.values()].filter(isProposed).filter((b) => b.slot === 6);
    expect(at6).toHaveLength(2);
  });
});

describe("the delay bound d = 0 (前提の遅延上限の下端)", () => {
  const schedule = scheduleOf(CONFIG);
  const cap = (action: Action) => capabilityOf(action, [1], schedule, 0);

  it("leaves honest messages undelayable but droppable, and own messages freely withheld", () => {
    expect(
      cap({ kind: "delay", message: { kind: "vote", sender: 2, slot: 5 }, untilSlot: 6 }),
    ).toBeUndefined();
    expect(cap({ kind: "drop", message: { kind: "vote", sender: 2, slot: 5 } })).toBe("drop-honest");
    expect(cap({ kind: "partition", fromSlot: 5, toSlot: 5, groups: [[0, 2]] })).toBeUndefined();
    expect(cap({ kind: "partition", fromSlot: 5, groups: [[0, 2]] })).toBe("partition");
    expect(
      cap({ kind: "delay", message: { kind: "vote", sender: 1, slot: 5 }, untilSlot: 9 }),
    ).toBe("withhold");
  });
});
