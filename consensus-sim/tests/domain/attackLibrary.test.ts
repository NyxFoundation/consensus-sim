// Attack library (攻撃ライブラリ) — every library attack reaches its goal under
// its declared premise and default run (成功条件 19), the mitigation-sensitive
// attacks (A01, A03, A04, A07) miss under the merge preset with the overrides
// removed, the bouncing (A05) is stopped by the switching window and runs
// identically to both switches off under `current`, the safety violations
// (A10, A12) are accountable (成功条件 27), and a saved attack round-trips
// through the codec and replays identically (成功条件 20).

import { describe, expect, it } from "vitest";
import {
  ANCHOR_CHECKPOINT,
  ATTACK_LIBRARY,
  ATTACK_REGISTRY,
  PRESETS,
  attackerStakeRatio,
  bodyOf,
  compareCheckpoints,
  defaultInstance,
  defaultParams,
  equivocationsIn,
  equivocatorOf,
  goalAchievedAt,
  isAncestor,
  latestFinalized,
  parseScenario,
  premiseParams,
  runScenario,
  satisfiesCondition,
  serializeScenario,
  type Block,
  type LibraryAttack,
  type ProposedBlock,
  type ProtocolParams,
  type Scenario,
  type InitialConditions,
} from "../../src/domain";

/** Narrow a tree block to its proposed shape, for tests that already know
 * the index in question is not the anchor. */
function asProposed(block: Block): ProposedBlock {
  if (block.kind !== "proposed") throw new Error(`block ${block.index} is the anchor`);
  return block;
}

function configFor(a: LibraryAttack, params: ProtocolParams): InitialConditions {
  return {
    validatorCount: a.defaultRun.validatorCount,
    seed: a.defaultRun.seed,
    params,
    initialStakes: a.defaultRun.initialStakes,
  };
}

function scenarioFor(a: LibraryAttack, params = premiseParams(a.premise)): Scenario {
  return { config: configFor(a, params), interventions: [], attack: defaultInstance(a) };
}

describe("attack library", () => {
  it("every attack reaches its goal under its default run (成功条件 19)", () => {
    for (const a of ATTACK_LIBRARY) {
      const achieved = goalAchievedAt(runScenario(scenarioFor(a), a.defaultRun.throughSlot).goal!);
      expect(achieved, `${a.id} never achieves its goal`).toBeTypeOf("number");
    }
  });

  it("every default run satisfies the attacker-set condition and binds the premise's d", () => {
    for (const a of ATTACK_LIBRARY) {
      expect(
        satisfiesCondition(a.attackers, a.defaultRun.attackers, configFor(a, premiseParams(a.premise))),
        `${a.id} default run violates its attacker condition`,
      ).toBe(true);
      expect(defaultParams(a).maxDelay).toBe(a.premise.maxDelay);
      expect(a.premise.maxDelay).toBeGreaterThanOrEqual(0);
    }
  });

  it("accepts every generated action of every default run (能力範囲)", () => {
    for (const a of ATTACK_LIBRARY) {
      const run = runScenario(scenarioFor(a), a.defaultRun.throughSlot);
      const discarded = run.generated.filter((g) => g.discarded !== undefined);
      expect(discarded, `${a.id} discards ${JSON.stringify(discarded[0])}`).toEqual([]);
    }
  });

  it("the mitigation-sensitive attacks (A01, A03, A04, A07) miss under the merge preset (成功条件 19)", () => {
    for (const id of ["A01", "A03", "A04", "A07"]) {
      const a = ATTACK_LIBRARY.find((x) => x.id === id)!;
      // Under its declared premise the goal is reached…
      expect(goalAchievedAt(runScenario(scenarioFor(a), a.defaultRun.throughSlot).goal!)).toBeTypeOf(
        "number",
      );
      // …but with the overrides removed (the merge preset) it is not.
      const merged = runScenario(scenarioFor(a, PRESETS.merge), a.defaultRun.throughSlot);
      expect(goalAchievedAt(merged.goal!), `${id} reaches its goal under merge`).toBeUndefined();
    }
  });

  it("the avalanche (A07) is stopped by the fork-choice rule alone: phase0 with LMD-GHOST", () => {
    const a07 = ATTACK_LIBRARY.find((a) => a.id === "A07")!;
    expect(premiseParams(a07.premise).forkChoice).toBe("GHOST");
    const lmd = runScenario(scenarioFor(a07, PRESETS.phase0), a07.defaultRun.throughSlot);
    expect(goalAchievedAt(lmd.goal!)).toBeUndefined();
  });

  it("the balancing attacks (A03, A04) keep two honest camps on two branches with nothing justified", () => {
    for (const id of ["A03", "A04"]) {
      const a = ATTACK_LIBRARY.find((x) => x.id === id)!;
      const run = runScenario(scenarioFor(a), a.defaultRun.throughSlot);
      const last = run.states[run.states.length - 1]!;
      // Branch A is rooted at the attacker's slot-1 block B1, branch B at the
      // honest slot-2 block B2 built beside it; camp {0, 4} stays on A and
      // camp {2, 3} on B through the whole run.
      expect(asProposed(last.tree.blocks.get(2)!).parent).toBe(0);
      for (const v of [0, 4]) expect(isAncestor(last.tree, 1, last.heads.get(v)!)).toBe(true);
      for (const v of [2, 3]) expect(isAncestor(last.tree, 2, last.heads.get(v)!)).toBe(true);
      for (const state of last.chainStates.values()) expect(state.justified).toEqual(ANCHOR_CHECKPOINT);
      expect(run.generated.every((g) => g.discarded === undefined)).toBe(true);
    }
  });

  it("the LMD balancing (A04) is broken by the equivocation discount alone", () => {
    const a04 = ATTACK_LIBRARY.find((a) => a.id === "A04")!;
    expect(premiseParams(a04.premise).equivocationDiscount).toBe(false);
    const discounted = { ...premiseParams(a04.premise), equivocationDiscount: true };
    const run = runScenario(scenarioFor(a04, discounted), a04.defaultRun.throughSlot);
    expect(goalAchievedAt(run.goal!)).toBeUndefined();
    // Every honest validator ends on the same branch (the attacker's head is
    // its own still-withheld block).
    const last = run.states[run.states.length - 1]!;
    expect(new Set([0, 2, 3, 4].map((v) => last.heads.get(v))).size).toBe(1);
  });

  it("the finality delay (A06) splits the epoch-1 targets and defers the first finalization by one epoch", () => {
    const a06 = ATTACK_LIBRARY.find((a) => a.id === "A06")!;
    const run = runScenario(scenarioFor(a06), a06.defaultRun.throughSlot);
    const targets = new Set(run.states[4]!.votes.filter((v) => v.slot === 4).map((v) => v.target.block));
    expect(targets).toEqual(new Set([3, 4]));
    const firstFinalization = (states: typeof run.states) =>
      states.findIndex((s) => latestFinalized(s.chainStates).block !== 0);
    expect(firstFinalization(run.states)).toBe(13);
    expect(goalAchievedAt(run.goal!)).toBe(10);
    // The honest run finalizes at slot 9, below the threshold L = 10.
    const { attack: _attack, ...honestScenario } = scenarioFor(a06);
    expect(firstFinalization(runScenario(honestScenario, 16).states)).toBe(9);
  });

  it("the bouncing (A05) alternates the justified checkpoint between two branches and finalizes nothing", () => {
    const a05 = ATTACK_LIBRARY.find((a) => a.id === "A05")!;
    const params = premiseParams(a05.premise);
    expect(params.checkpointSwitch).toEqual({ window: false, unrealized: false });
    expect(params.committee.kind).toBe("epoch-split");
    const run = runScenario(scenarioFor(a05), 36);
    expect(run.generated.every((g) => g.discarded === undefined)).toBe(true);
    // The two branches fork at the anchor: Y under the attacker's slot-1
    // block B1, X under the honest slot-2 block B2.
    const last = run.states[run.states.length - 1]!;
    expect(asProposed(last.tree.blocks.get(1)!).parent).toBe(0);
    expect(asProposed(last.tree.blocks.get(2)!).parent).toBe(0);
    // From the first bounce on, each epoch's justified checkpoint (the
    // highest over the god view) lies on the other branch than the last.
    const highest = (s: (typeof run.states)[number]) =>
      [...s.chainStates.values()].reduce(
        (best, c) =>
          s.tree.blocks.get(c.justified.block)!.slot > s.tree.blocks.get(best)!.slot ? c.justified.block : best,
        0,
      );
    const sequence = [13, 17, 21, 25, 29, 33].map((slot) => highest(run.states[slot]!));
    expect(sequence).toEqual([8, 12, 16, 20, 24, 28]);
    const branchOf = (b: number) => (isAncestor(last.tree, 1, b) ? "Y" : "X");
    expect(sequence.map(branchOf)).toEqual(["X", "Y", "X", "Y", "X", "Y"]);
    // Every state keeps the anchor as the latest finalized block.
    for (const s of run.states) expect(latestFinalized(s.chainStates)).toEqual(ANCHOR_CHECKPOINT);
    expect(goalAchievedAt(run.goal!)).toBe(12);
  });

  // The A05 mitigation observations of 成功条件 19: the switching window stops
  // the bounce, unrealized justification does not act on it.
  const bouncingUnder = (checkpointSwitch: "off" | "window" | "unrealized", throughSlot: number) => {
    const a05 = ATTACK_LIBRARY.find((a) => a.id === "A05")!;
    const premise = premiseParams(a05.premise);
    // `off` is the premise itself; `window` / `unrealized` keep the committee
    // override (epoch split) and drop only the switching one.
    const params =
      checkpointSwitch === "off"
        ? premise
        : { ...(checkpointSwitch === "unrealized" ? PRESETS.current : PRESETS.merge), committee: premise.committee };
    expect(params.checkpointSwitch).toEqual({
      window: checkpointSwitch === "window",
      unrealized: checkpointSwitch === "unrealized",
    });
    return runScenario(scenarioFor(a05, params), throughSlot);
  };
  const honestTargetsByEpoch = (run: ReturnType<typeof runScenario>) => {
    const last = run.states[run.states.length - 1]!;
    const targets = new Map<number, Set<number>>();
    for (const v of last.votes) {
      if (v.validator === 1) continue;
      const epoch = Math.floor(v.slot / 4);
      targets.set(epoch, (targets.get(epoch) ?? new Set()).add(v.target.block));
    }
    return targets;
  };

  it("the bouncing (A05) is stopped by the switching window: honest targets converge and finalized advances", () => {
    const run = bouncingUnder("window", 60);
    expect(run.generated.every((g) => g.discarded === undefined)).toBe(true);
    // The opening bounces (epochs 1–3) still split the honest targets, but
    // from epoch 4 on the root only switches at the epoch's first slot, so
    // every honest validator votes the same target in each epoch…
    const targets = honestTargetsByEpoch(run);
    expect([1, 2, 3].every((e) => targets.get(e)!.size > 1)).toBe(true);
    for (let epoch = 4; epoch <= 14; epoch++) expect(targets.get(epoch)!.size, `epoch ${epoch}`).toBe(1);
    // …and finalized, stuck at the anchor under `off`, moves forward.
    const finalized = run.states.map((s) => latestFinalized(s.chainStates));
    expect(finalized.findIndex((f) => f.block !== 0)).toBe(48);
    expect(compareCheckpoints(finalized[60]!, finalized[48]!)).toBeLessThan(0);
    // The default L = 12 is still reached before the mitigation bites.
    expect(goalAchievedAt(run.goal!)).toBe(12);
  });

  it("the bouncing (A05) under unrealized justification (current) runs identically to `off`", () => {
    const off = bouncingUnder("off", 60);
    const unrealized = bouncingUnder("unrealized", 60);
    expect(unrealized.generated).toEqual(off.generated);
    expect(goalAchievedAt(unrealized.goal!)).toBe(goalAchievedAt(off.goal!));
    off.states.forEach((s, slot) => {
      const u = unrealized.states[slot]!;
      expect([...u.heads.entries()]).toEqual([...s.heads.entries()]);
      expect(latestFinalized(u.chainStates)).toEqual(latestFinalized(s.chainStates));
    });
    // Unrealized only prunes candidates below the root; it never moves the
    // root, so the anchor stays finalized through the whole run.
    for (const s of unrealized.states) expect(latestFinalized(s.chainStates)).toEqual(ANCHOR_CHECKPOINT);
  });

  // 成功条件 27 (可罰性): by the slot the violation is judged, the god view
  // holds FFG evidence (double or surround votes) of attackers worth at
  // least a third of the stake, and a branch that includes it slashes them
  // while a branch that does not keeps their stake.
  const accountability = (id: string, evidenceKind: "double-vote" | "surround-vote") => {
    const a = ATTACK_LIBRARY.find((x) => x.id === id)!;
    const scenario = scenarioFor(a);
    const run = runScenario(scenario, a.defaultRun.throughSlot);
    const at = goalAchievedAt(run.goal!)!;
    const verdict = run.goal![at]![0]!.evidence;
    expect(verdict.kind).toBe("safety-violation");
    if (verdict.kind !== "safety-violation") throw new Error("unreachable");
    expect(verdict.conflicting, `${id} reports no conflicting pair`).toBeDefined();
    const god = run.states[at]!;
    const ffgEvidence = equivocationsIn(god.tree, god.votes).filter((e) => e.kind !== "double-proposal");
    expect(ffgEvidence.map((e) => e.kind)).toContain(evidenceKind);
    const accused = [...new Set(ffgEvidence.map(equivocatorOf))];
    for (const v of accused) expect(scenario.attack!.attackers).toContain(v);
    expect(attackerStakeRatio(accused, scenario.config)).toBeGreaterThanOrEqual(1 / 3);
    // The branches at the end of the run: one carries the evidence and zeroes
    // the accused, one does not and keeps their stake.
    const last = run.states[run.states.length - 1]!;
    const carrying = [...last.tree.blocks.values()].filter((b) => bodyOf(b).evidence.length > 0);
    expect(carrying.length, `${id}: no block includes the evidence`).toBeGreaterThan(0);
    const slashedOn = carrying[0]!.index;
    for (const v of accused) expect(last.chainStates.get(slashedOn)!.stakes.get(v)).toBe(0);
    // The other branch — a block neither above nor below the carrying one.
    const spared = [...last.tree.blocks.values()]
      .filter((b) => !isAncestor(last.tree, slashedOn, b.index) && !isAncestor(last.tree, b.index, slashedOn))
      .sort((x, y) => y.slot - x.slot)[0];
    expect(spared, `${id}: no branch without the evidence`).toBeDefined();
    expect(bodyOf(spared!).evidence).toEqual([]);
    for (const v of accused) expect(last.chainStates.get(spared!.index)!.stakes.get(v)).toBe(32);
    return { run, at, carrying: carrying[0]! };
  };

  it("the double finality (A10) is accountable: FFG double votes, slashed once the split heals", () => {
    const { at, carrying } = accountability("A10", "double-vote");
    expect(at).toBe(11);
    // The honest slot-13 proposal, after both honest validators see everything
    // at slot 12, carries the evidence.
    expect(carrying.slot).toBe(13);
  });

  it("the history domination (A12) is accountable: surround votes, slashed on the honest chain only", () => {
    const { run, at, carrying } = accountability("A12", "surround-vote");
    expect(at).toBe(17);
    // The honest validator's slot-15 block on the finalized history carries
    // the evidence; the attackers' branch (B12 onward) omits it throughout.
    expect(carrying.slot).toBe(15);
    expect(isAncestor(run.states[at]!.tree, 4, carrying.index)).toBe(true);
    const last = run.states[run.states.length - 1]!;
    for (const block of last.tree.blocks.values()) {
      if (isAncestor(last.tree, 12, block.index)) expect(bodyOf(block).evidence).toEqual([]);
    }
  });

  it("the leak amplification (A14) reaches its two stages in order", () => {
    const a14 = ATTACK_LIBRARY.find((a) => a.id === "A14")!;
    const run = runScenario(scenarioFor(a14), a14.defaultRun.throughSlot);
    const final = run.goal![run.goal!.length - 1]!;
    const [ratio, safety] = final as [(typeof final)[number], (typeof final)[number]];
    expect(ratio.status).toBe("achieved");
    expect(safety.status).toBe("achieved");
    expect(ratio.achievedAt!).toBeLessThan(safety.achievedAt!);
    // Before the first stage holds, the second is not judged.
    expect(run.goal![ratio.achievedAt! - 1]![1]!.status).toBe("pending");
    // The attacker never leaks: its stake is intact on the isolated branch.
    const evidence = run.goal![ratio.achievedAt!]![0]!.evidence;
    if (evidence.kind !== "attacker-stake-ratio") throw new Error("unreachable");
    const head = run.states[ratio.achievedAt!]!.chainStates.get(evidence.head!)!;
    expect(head.stakes.get(3)).toBe(32);
    expect(head.stakes.get(1)!).toBeLessThan(32);
    // Its two votes per epoch are FFG double votes in the god view, but the
    // selective delivery keeps every honest view — and every block — free of
    // the pair: nobody ever slashes it.
    const last = run.states[run.states.length - 1]!;
    expect(equivocationsIn(last.tree, last.votes).length).toBeGreaterThan(0);
    for (const block of last.tree.blocks.values()) expect(bodyOf(block).evidence).toEqual([]);
  });

  it("resolves and replays a saved attack through the registry (成功条件 20)", () => {
    for (const a of ATTACK_LIBRARY) {
      const scenario = scenarioFor(a);
      const wire = JSON.parse(JSON.stringify(serializeScenario(scenario, a.defaultRun.throughSlot)));
      const restored = parseScenario(wire, ATTACK_REGISTRY);
      const before = runScenario(scenario, a.defaultRun.throughSlot);
      const after = runScenario(restored.scenario, a.defaultRun.throughSlot);
      expect(goalAchievedAt(after.goal!)).toBe(goalAchievedAt(before.goal!));
      expect(after.generated).toEqual(before.generated);
    }
  });

  it("keeps the registry in step with the library", () => {
    expect([...ATTACK_REGISTRY.keys()].sort()).toEqual(ATTACK_LIBRARY.map((a) => a.id).sort());
  });
});
