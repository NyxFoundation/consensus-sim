// Scenario (シナリオ) — initial conditions, the manual intervention list and
// at most one attack: the complete, persistable identity of a run. Every
// state of a scenario is a pure recomputation from the anchor, which is
// simultaneously the rewind path (巻き戻し) and the determinism guarantee
// (決定性): the same scenario always reproduces the same states — and, with
// an attack, the same generated actions.

import { evaluateGoal, type GoalTrace } from "../model/attackGoal";
import type { SimulationConfig } from "../model/config";
import { generateActions, type AttackInstance, type GeneratedAction } from "./attackRun";
import { compileDelivery, directivesForSlot, type Intervention } from "./intervention";
import type { Delivery } from "./localView";
import { advanceSlot, initialState, type SimulationState } from "./simulation";
import { START_SLOT, type SlotIndex } from "../model/types";

export interface Scenario {
  readonly config: SimulationConfig;
  /** The manual interventions (手動介入の列). */
  readonly interventions: readonly Intervention[];
  /** 高々 1 つの攻撃. */
  readonly attack?: AttackInstance;
}

/** The delivery rule the scenario's manual interventions compile into. */
export function scenarioDelivery(scenario: Scenario): Delivery {
  return compileDelivery(scenario.interventions);
}

/** Advance one slot under the scenario's manual interventions alone (an
 * attack's actions come from `runScenario`). */
export function advanceScenario(
  scenario: Scenario,
  state: SimulationState,
  delivery: Delivery = scenarioDelivery(scenario),
): SimulationState {
  return advanceSlot(
    scenario.config,
    state,
    delivery,
    directivesForSlot(scenario.interventions, state.slot + 1, scenario.config),
  );
}

/** A scenario computed through some slot: its states, every action the
 * attack's strategy generated (accepted or discarded), the interventions
 * in effect — the manual ones plus the accepted actions — and, with an
 * attack, the goal's verdict at every slot (攻撃目標の判定推移). */
export interface ScenarioRun {
  readonly states: readonly SimulationState[];
  readonly generated: readonly GeneratedAction[];
  readonly interventions: readonly Intervention[];
  readonly goal?: GoalTrace;
}

/**
 * Run the scenario from slot 0 through `throughSlot`, recomputed from the
 * anchor: `states[i]` is the state at slot i. With an attack, the strategy
 * runs at every boundary before the next slot is computed, observing the
 * attackers' views under the interventions in effect so far; its accepted
 * actions join the interventions for the slots ahead. Runs through
 * different slots agree on their common prefix.
 */
export function runScenario(scenario: Scenario, throughSlot: SlotIndex): ScenarioRun {
  if (!Number.isInteger(throughSlot) || throughSlot < START_SLOT) {
    throw new Error(
      `throughSlot must be an integer ≥ ${START_SLOT}, got ${throughSlot}`,
    );
  }
  const { config, attack } = scenario;
  const effective: Intervention[] = [...scenario.interventions];
  const generated: GeneratedAction[] = [];
  const states: SimulationState[] = [initialState(config)];
  let delivery = compileDelivery(effective);
  while (states.length <= throughSlot) {
    const last = states[states.length - 1]!;
    if (attack !== undefined) {
      const fresh = generateActions(
        last,
        attack,
        config,
        scenario.interventions,
        effective,
        delivery,
      );
      generated.push(...fresh);
      if (fresh.some((g) => g.discarded === undefined)) {
        delivery = compileDelivery(effective);
      }
    }
    states.push(
      advanceSlot(config, last, delivery, directivesForSlot(effective, last.slot + 1, config)),
    );
  }
  return {
    states,
    generated,
    interventions: effective,
    ...(attack === undefined
      ? {}
      : { goal: evaluateGoal(attack.attack.goal, states, attack.attackers, config) }),
  };
}

/** All states of the scenario from slot 0 through `throughSlot`. */
export function scenarioStates(
  scenario: Scenario,
  throughSlot: SlotIndex,
): SimulationState[] {
  return [...runScenario(scenario, throughSlot).states];
}
