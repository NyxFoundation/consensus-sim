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
  type Action,
  type Attack,
  type AttackInstance,
  type AttackerObservation,
  type Intervention,
  type Scenario,
  type SimulationConfig,
  type SimulationState,
  type Strategy,
} from "../../src/domain";

const CONFIG: SimulationConfig = {
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
    expect(at3.view.slot).toBe(3);
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

  it("classifies each action by the capability it exercises", () => {
    expect(cap({ kind: "double-propose", slot: 5, validator: 1 })).toBe("equivocation");
    expect(cap({ kind: "double-vote", slot: 5, validator: 1 })).toBe("equivocation");
    expect(cap({ kind: "vote-target", slot: 5, validator: 1, head: 0 })).toBe("vote-target");
    expect(cap({ kind: "stop", fromSlot: 5, validators: [1] })).toBe("silence");
    // Slot 5 is proposed by validator 1.
    expect(cap({ kind: "propose-parent", slot: 5, parent: 0 })).toBe("propose-parent");
    expect(cap({ kind: "omit-inclusion", slot: 5, votes: [] })).toBe("omit-inclusion");
    expect(
      cap({ kind: "delay", message: { kind: "proposal", proposer: 1, slot: 5 }, untilSlot: 7 }),
    ).toBe("withhold");
    expect(
      cap({ kind: "drop", message: { kind: "attestation", validator: 1, slot: 5 }, observers: [2] }),
    ).toBe("withhold");
    expect(
      cap({ kind: "delay", message: { kind: "proposal", proposer: 2, slot: 6 }, untilSlot: 8 }),
    ).toBe("delay-honest");
    expect(cap({ kind: "drop", message: { kind: "attestation", validator: 0, slot: 6 } })).toBe(
      "drop-honest",
    );
    expect(cap({ kind: "partition", fromSlot: 5, groups: [[0, 2]] })).toBe("partition");
  });

  it("puts acting as an honest validator, honest proposals and long delays outside", () => {
    expect(cap({ kind: "double-vote", slot: 5, validator: 2 })).toBeUndefined();
    expect(cap({ kind: "stop", fromSlot: 5, validators: [1, 2] })).toBeUndefined();
    expect(cap({ kind: "vote-target", slot: 5, validator: 0, head: 0 })).toBeUndefined();
    // Slot 6 is proposed by validator 2.
    expect(cap({ kind: "propose-parent", slot: 6, parent: 0 })).toBeUndefined();
    expect(cap({ kind: "omit-inclusion", slot: 6 })).toBeUndefined();
    // d = 2: a delay may hold a message at most 2 slots past its slot.
    expect(
      cap({ kind: "delay", message: { kind: "proposal", proposer: 1, slot: 5 }, untilSlot: 8 }),
    ).toBeUndefined();
    // Messages are named ahead of publication; a block index names a block
    // already published, and an honest vote's head is not the attacker's to
    // know in advance.
    expect(cap({ kind: "delay", message: { kind: "block", block: 3 }, untilSlot: 6 })).toBeUndefined();
    expect(
      cap({ kind: "drop", message: { kind: "vote", validator: 0, slot: 5, head: 4 } }),
    ).toBeUndefined();
  });

  it("lets the attacker name one half of its own double vote by its designated head (selective delivery)", () => {
    expect(
      cap({ kind: "delay", message: { kind: "vote", validator: 1, slot: 5, head: 4 }, untilSlot: 7 }),
    ).toBe("withhold");
    expect(
      cap({ kind: "drop", message: { kind: "vote", validator: 1, slot: 5, head: 4 }, observers: [0] }),
    ).toBe("withhold");
  });

  it("names messages ahead of publication: proposal / attestation references cover what the sender publishes in the slot", () => {
    const proposal = { kind: "proposal", proposer: 1, slot: 5 } as const;
    expect(coversMessage(proposal, { kind: "block", block: 9 }, 1, 5)).toBe(true);
    expect(coversMessage(proposal, { kind: "block", block: 9 }, 2, 5)).toBe(false);
    expect(coversMessage(proposal, { kind: "block", block: 9 }, 1, 6)).toBe(false);
    expect(coversMessage(proposal, { kind: "vote", validator: 1, slot: 5, head: 9 }, 1, 5)).toBe(
      false,
    );
    const attestation = { kind: "attestation", validator: 1, slot: 5 } as const;
    expect(coversMessage(attestation, { kind: "vote", validator: 1, slot: 5, head: 9 }, 1, 5)).toBe(
      true,
    );
    expect(coversMessage(attestation, { kind: "vote", validator: 1, slot: 5, head: 4 }, 1, 5)).toBe(
      true,
    );
    expect(coversMessage(attestation, { kind: "vote", validator: 1, slot: 6, head: 9 }, 1, 6)).toBe(
      false,
    );
    expect(sameRef(proposal, { kind: "proposal", proposer: 1, slot: 5 })).toBe(true);
    expect(sameRef(proposal, attestation)).toBe(false);
    expect(sameRef(attestation, { kind: "attestation", validator: 1, slot: 4 })).toBe(false);
  });

  it("withholds the attacker's own proposal by reference before it exists (保留と選択配送)", () => {
    // Validator 1 proposes at slot 1 and holds the block back from everyone
    // until slot 2: honest validators vote for the anchor at slot 1, and
    // see the block at slot 2.
    const hold: Action = {
      kind: "delay",
      message: { kind: "proposal", proposer: 1, slot: 1 },
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
      message: { kind: "attestation", validator: 1, slot: 7 },
      untilSlot: 8,
    };
    const manualPartition: Intervention = { kind: "partition", fromSlot: 4, toSlot: 5, groups: [[0, 1]] };
    const equivocate: Action = { kind: "double-vote", slot: 3, validator: 1 };
    const parent: Action = { kind: "propose-parent", slot: 5, parent: 0 };
    const withhold: Action = {
      kind: "delay",
      message: { kind: "attestation", validator: 1, slot: 7 },
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
});
