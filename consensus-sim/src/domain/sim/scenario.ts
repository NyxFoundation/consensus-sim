// Scenario (シナリオ) — initial conditions plus the intervention list: the
// complete, persistable identity of a run. Every state of a scenario is a
// pure recomputation from the anchor, which is simultaneously the rewind
// path (巻き戻し) and the determinism guarantee (決定性): the same scenario
// always reproduces the same states.

import type { SimulationConfig } from "../model/config";
import { compileDelivery, directivesForSlot, type Intervention } from "./intervention";
import type { Delivery } from "./localView";
import { advanceSlot, initialState, type SimulationState } from "./simulation";
import { START_SLOT, type SlotIndex } from "../model/types";

export interface Scenario {
  readonly config: SimulationConfig;
  readonly interventions: readonly Intervention[];
}

/** The delivery rule the scenario's interventions compile into. */
export function scenarioDelivery(scenario: Scenario): Delivery {
  return compileDelivery(scenario.interventions);
}

/** Advance one slot under the scenario's interventions. */
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

/**
 * All states of the scenario from slot 0 through `throughSlot`, recomputed
 * from the anchor: `scenarioStates(s, n)[i]` is the state at slot i.
 */
export function scenarioStates(
  scenario: Scenario,
  throughSlot: SlotIndex,
): SimulationState[] {
  if (!Number.isInteger(throughSlot) || throughSlot < START_SLOT) {
    throw new Error(
      `throughSlot must be an integer ≥ ${START_SLOT}, got ${throughSlot}`,
    );
  }
  const delivery = scenarioDelivery(scenario);
  const states: SimulationState[] = [initialState(scenario.config)];
  while (states.length <= throughSlot) {
    const last = states[states.length - 1];
    if (last === undefined) break;
    states.push(advanceScenario(scenario, last, delivery));
  }
  return states;
}
