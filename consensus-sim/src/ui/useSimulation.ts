/**
 * Simulation session for the UI: a scenario config plus the list of states
 * the run has passed through, one per slot. Advancing appends
 * `advanceSlot`; every past state stays addressable by slot index, which is
 * exactly the rewind surface the later rewind UI will point at.
 *
 * All consensus computation lives in src/domain; this hook only holds the
 * (config, states, cursor) triple as React state.
 */

import { useCallback, useMemo, useState } from 'react'
import {
  advanceSlot,
  initialState,
  instantDelivery,
  DEFAULT_VALIDATOR_COUNT,
} from '../domain'
import type { Delivery, SimulationConfig, SimulationState } from '../domain'

export interface SimulationSession {
  readonly config: SimulationConfig
  /** states[i] is the state at slot i; the last entry is the current slot. */
  readonly states: readonly SimulationState[]
  readonly current: SimulationState
  advance(): void
  /** Replaces the scenario (new validator count ⇒ new run from slot 0). */
  setValidatorCount(count: number): void
}

const DEFAULT_SEED = 0

export function useSimulation(
  delivery: Delivery = instantDelivery,
): SimulationSession {
  const [config, setConfig] = useState<SimulationConfig>({
    validatorCount: DEFAULT_VALIDATOR_COUNT,
    seed: DEFAULT_SEED,
  })
  const [states, setStates] = useState<readonly SimulationState[]>(() => [
    initialState(config),
  ])

  const advance = useCallback(() => {
    setStates((prev) => {
      const last = prev[prev.length - 1]
      if (last === undefined) return prev
      return [...prev, advanceSlot(config, last, delivery)]
    })
  }, [config, delivery])

  const setValidatorCount = useCallback((count: number) => {
    const next: SimulationConfig = { validatorCount: count, seed: DEFAULT_SEED }
    setConfig(next)
    setStates([initialState(next)])
  }, [])

  const current = states[states.length - 1]
  if (current === undefined) throw new Error('simulation has no states')

  return useMemo(
    () => ({ config, states, current, advance, setValidatorCount }),
    [config, states, current, advance, setValidatorCount],
  )
}
