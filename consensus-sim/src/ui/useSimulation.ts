/**
 * Simulation session for the UI: a scenario (config + interventions) plus a
 * slot cursor. All states are derived by pure recomputation from the anchor
 * (`scenarioStates`), so rewinding is just moving the cursor, and editing
 * the interventions deterministically rewrites the whole displayed history.
 *
 * Advancing while the cursor sits on a past slot truncates the discarded
 * future and continues from the cursor (branch comparison is explicitly out
 * of scope in the Essence).
 *
 * All consensus computation lives in src/domain; this hook only holds the
 * (config, interventions, runSlot, cursor) tuple as React state.
 */

import { useCallback, useMemo, useState } from 'react'
import {
  compileDelivery,
  equalStakes,
  scenarioStates,
  DEFAULT_PARAMS,
  DEFAULT_VALIDATOR_COUNT,
} from '../domain'
import type {
  Delivery,
  Intervention,
  Scenario,
  SimulationConfig,
  SimulationState,
} from '../domain'

export interface SimulationSession {
  readonly config: SimulationConfig
  readonly interventions: readonly Intervention[]
  /** Compiled delivery rule — local views must be filtered through this. */
  readonly delivery: Delivery
  /** states[i] is the state at slot i; the run has advanced to `runSlot`. */
  readonly states: readonly SimulationState[]
  readonly runSlot: number
  /** The slot currently displayed (≤ runSlot). */
  readonly cursor: number
  readonly current: SimulationState
  /** Advance one slot from the cursor; a past cursor truncates the future. */
  advance(): void
  /** Move the displayed slot within [0, runSlot] (巻き戻し). */
  setCursor(slot: number): void
  /** Replace the intervention list; every state recomputes deterministically. */
  setInterventions(next: readonly Intervention[]): void
  /** Replaces the scenario (new validator count ⇒ new run from slot 0). */
  setValidatorCount(count: number): void
  /** Replay a saved scenario: states recompute deterministically and the
   * cursor lands on the saved run's final slot. */
  loadScenario(scenario: Scenario, runSlot: number): void
}

const DEFAULT_SEED = 0

interface SessionCore {
  readonly config: SimulationConfig
  readonly interventions: readonly Intervention[]
  readonly runSlot: number
  readonly cursor: number
}

const freshCore = (validatorCount: number): SessionCore => ({
  config: {
    validatorCount,
    seed: DEFAULT_SEED,
    params: DEFAULT_PARAMS,
    initialStakes: equalStakes(validatorCount),
  },
  interventions: [],
  runSlot: 0,
  cursor: 0,
})

export function useSimulation(): SimulationSession {
  const [core, setCore] = useState<SessionCore>(() =>
    freshCore(DEFAULT_VALIDATOR_COUNT),
  )

  const { config, interventions, runSlot, cursor } = core

  const states = useMemo(
    () => scenarioStates({ config, interventions }, runSlot),
    [config, interventions, runSlot],
  )
  const delivery = useMemo(
    () => compileDelivery(interventions),
    [interventions],
  )

  const advance = useCallback(() => {
    setCore((c) => ({ ...c, runSlot: c.cursor + 1, cursor: c.cursor + 1 }))
  }, [])

  const setCursor = useCallback((slot: number) => {
    setCore((c) => ({
      ...c,
      cursor: Math.min(Math.max(slot, 0), c.runSlot),
    }))
  }, [])

  const setInterventions = useCallback(
    (next: readonly Intervention[]) => {
      setCore((c) => ({ ...c, interventions: next }))
    },
    [],
  )

  const setValidatorCount = useCallback((count: number) => {
    setCore(freshCore(count))
  }, [])

  const loadScenario = useCallback((scenario: Scenario, runSlot: number) => {
    setCore({
      config: scenario.config,
      interventions: scenario.interventions,
      runSlot,
      cursor: runSlot,
    })
  }, [])

  const current = states[cursor]
  if (current === undefined) throw new Error('simulation has no states')

  return useMemo(
    () => ({
      config,
      interventions,
      delivery,
      states,
      runSlot,
      cursor,
      current,
      advance,
      setCursor,
      setInterventions,
      setValidatorCount,
      loadScenario,
    }),
    [
      config,
      interventions,
      delivery,
      states,
      runSlot,
      cursor,
      current,
      advance,
      setCursor,
      setInterventions,
      setValidatorCount,
      loadScenario,
    ],
  )
}
