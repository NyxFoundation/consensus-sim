/**
 * Drives a `Simulation` from requestAnimationFrame.
 *
 * The engine has no notion of real time — it advances to a target simulated
 * instant and stops. This hook is the only place the two clocks meet: each
 * frame converts elapsed wall-clock milliseconds into simulated milliseconds
 * via `speed`. Changing any protocol parameter rebuilds the simulation, because
 * altering the validator set or epoch length mid-run would compare two
 * different experiments.
 */

import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { createGasperSimulation } from '../setup'
import type { GasperParams } from '../setup'
import type { Simulation } from '../core/simulation'
import type { GasperSchedule } from '../protocol/gasper/schedule'

/** Longest wall-clock gap folded into one advance, so a backgrounded tab does
 * not resume by simulating minutes of chain in a single frame. */
const MAX_FRAME_MS = 100

/**
 * Real time. Anything faster runs a slot by before the propagation inside it
 * can be followed, and the point of the slot views is that they can be read.
 */
const DEFAULT_SPEED = 1

export interface SimulationController {
  readonly sim: Simulation
  /** Duty assignment for the run, for showing proposer and committee. */
  readonly schedule: GasperSchedule
  /** Increments on every advance; views depend on it to redraw. */
  readonly frame: number
  readonly running: boolean
  readonly speed: number
  /** Simulated position on the slot axis, including the fraction within a slot. */
  readonly slotPosition: number
  setRunning(running: boolean): void
  setSpeed(speed: number): void
  stepSlot(): void
  reset(): void
}

export function useSimulation(params: GasperParams): SimulationController {
  const [generation, setGeneration] = useState(0)
  const { sim, schedule } = useMemo(() => createGasperSimulation(params), [params, generation])

  const [running, setRunning] = useState(true)
  const [speed, setSpeed] = useState(DEFAULT_SPEED)
  const [frame, setFrame] = useState(0)
  const lastRef = useRef(0)

  useEffect(() => {
    if (!running) return

    let handle = 0
    lastRef.current = performance.now()

    const tick = (now: number) => {
      const elapsed = Math.min(now - lastRef.current, MAX_FRAME_MS)
      lastRef.current = now
      sim.advanceTo(sim.time + elapsed * speed)
      setFrame((value) => value + 1)
      handle = requestAnimationFrame(tick)
    }

    handle = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(handle)
  }, [sim, running, speed])

  const stepSlot = useCallback(() => {
    sim.advanceTo(sim.time + params.slotDurationMs)
    setFrame((value) => value + 1)
  }, [sim, params.slotDurationMs])

  const reset = useCallback(() => {
    setGeneration((value) => value + 1)
    setFrame(0)
  }, [])

  return {
    sim,
    schedule,
    frame,
    running,
    speed,
    slotPosition: sim.time / params.slotDurationMs,
    setRunning,
    setSpeed,
    stepSlot,
    reset,
  }
}
