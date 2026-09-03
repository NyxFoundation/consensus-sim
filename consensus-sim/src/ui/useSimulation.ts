/**
 * Simulation session for the UI: a scenario (config + manual interventions
 * + at most one attack) plus a slot cursor. All states are derived by pure
 * recomputation from the anchor (`runScenario`), so rewinding is just moving
 * the cursor, and editing the interventions, the parameters or the attack
 * deterministically rewrites the whole displayed history — including the
 * actions the attack's strategy generates, which are never stored.
 *
 * Advancing while the cursor sits on a past slot truncates the discarded
 * future and continues from the cursor (branch comparison is explicitly out
 * of scope in the Essence).
 *
 * Auto-play (自動再生, 必須 31) is a timer in this hook over the same
 * `advance`: `play` advances one slot per interval (the chosen speed,
 * PLAY_INTERVALS_MS) from the cursor and stops by itself at `playEnd` — with
 * an attack bound, the end slot of the run (`throughSlot`), or earlier at
 * the slot the attack goal is judged achieved; without an attack (任意),
 * FREE_PLAY_SPAN slots past where playback started. `pause` stops it, and
 * playing again from the stop continues. The domain stays deterministic:
 * nothing about the timer or the speed enters the scenario.
 *
 * All consensus computation lives in src/domain; this hook only holds the
 * (config, interventions, attack, runSlot, cursor) tuple as React state,
 * plus the end slot an attack's default run declares for auto-play.
 */

import { useCallback, useEffect, useMemo, useState } from 'react'
import {
  compileDelivery,
  defaultConditions,
  defaultInstance,
  equalStakes,
  findLibraryAttack,
  goalAchievedAt,
  runScenario,
  DEFAULT_PARAMS,
  DEFAULT_VALIDATOR_COUNT,
} from '../domain'
import type {
  AttackInstance,
  Delivery,
  GeneratedAction,
  GoalTrace,
  Intervention,
  LibraryAttack,
  Scenario,
  InitialConditions,
  SimulationState,
} from '../domain'

export interface SimulationSession {
  readonly config: InitialConditions
  /** The manual interventions (手動介入の列) — the editable list. */
  readonly interventions: readonly Intervention[]
  /** The attack bound into the scenario, if any (高々 1 つ). */
  readonly attack: AttackInstance | undefined
  /** The slot the attack's run is carried through when auto-played
   * (既定実行構成の終了スロット); undefined without an attack. */
  readonly throughSlot: number | undefined
  /** Every action the strategy generated so far, accepted or discarded. */
  readonly generated: readonly GeneratedAction[]
  /** The interventions in effect: the manual ones plus the accepted actions. */
  readonly effective: readonly Intervention[]
  /** The goal's verdict at every slot (攻撃目標の判定推移), with an attack. */
  readonly goal: GoalTrace | undefined
  /** Compiled delivery rule of the effective interventions — local views
   * must be filtered through this. */
  readonly delivery: Delivery
  /** states[i] is the state at slot i; the run has advanced to `runSlot`. */
  readonly states: readonly SimulationState[]
  readonly runSlot: number
  /** The slot currently displayed (≤ runSlot). */
  readonly cursor: number
  readonly current: SimulationState
  /** Whether auto-play is running (自動再生中). */
  readonly playing: boolean
  /** The auto-play speed (再生速度); the session's, not the scenario's. */
  readonly speed: PlaySpeed
  /** The slot auto-play stops at (終了): the attack's end slot, or, without
   * an attack, FREE_PLAY_SPAN slots past where playback started (idle:
   * where it would start, the cursor). */
  readonly playEnd: number
  /** Advance one slot from the cursor; a past cursor truncates the future. */
  advance(): void
  /** Start auto-play from the cursor (実行開始 / 再開 / 自動再生): one slot per
   * interval until `playEnd`, or — with an attack — the slot its goal is
   * achieved at. */
  play(): void
  /** Stop auto-play (一時停止); the run stays where it is. */
  pause(): void
  setSpeed(speed: PlaySpeed): void
  /** Move the displayed slot within [0, runSlot] (巻き戻し); pauses auto-play. */
  setCursor(slot: number): void
  /** Replace the manual intervention list; every state recomputes. */
  setInterventions(next: readonly Intervention[]): void
  /** Replace the initial conditions (protocol parameters, seed, initial
   * stakes). With the validator count unchanged the interventions, the
   * attack and the run length stay and the whole history recomputes; a new
   * validator count starts a fresh run from slot 0 and pauses auto-play. */
  setConfig(config: InitialConditions): void
  /** Replaces the scenario (new validator count ⇒ new run from slot 0,
   * keeping the protocol parameters, the seed and the attack); pauses
   * auto-play. */
  setValidatorCount(count: number): void
  /** Replace (or remove) the attack; the whole history recomputes and the
   * strategy's actions regenerate. */
  setAttack(attack: AttackInstance | undefined): void
  /** Propose a library attack's default run as the scenario's initial
   * conditions (既定実行構成の提案): its validator count, stakes, seed and
   * premise parameters, its attacker set and parameters, its end slot — a
   * fresh run from slot 0 with no manual interventions. */
  proposeAttack(entry: LibraryAttack): void
  setThroughSlot(slot: number): void
  /** Replay a saved scenario: states recompute deterministically and the
   * cursor lands on the saved run's final slot. */
  loadScenario(scenario: Scenario, runSlot: number): void
}

const DEFAULT_SEED = 0

/** Auto-play speeds (再生速度): the interval between slots per speed. */
export type PlaySpeed = 'slow' | 'normal' | 'fast'

export const PLAY_INTERVALS_MS: Readonly<Record<PlaySpeed, number>> = {
  slow: 1200,
  normal: 600,
  fast: 300,
}

/** Auto-play interval between slots at the default speed (送りの間隔の既定値). */
export const PLAY_INTERVAL_MS = PLAY_INTERVALS_MS.normal

/** Without an attack, one auto-play advances this many slots (4 epochs) from
 * where it started, then stops; playing again continues from there. */
export const FREE_PLAY_SPAN = 16

/** A running auto-play: the slot it was started from. A goal already
 * achieved at the starting slot does not stop it again, so playing from
 * an achievement stop carries the run on to its end slot; without an
 * attack the stop is FREE_PLAY_SPAN slots past this slot. */
interface Playing {
  readonly from: number
}

interface SessionCore {
  readonly config: InitialConditions
  readonly interventions: readonly Intervention[]
  readonly attack: AttackInstance | undefined
  readonly throughSlot: number | undefined
  readonly runSlot: number
  readonly cursor: number
}

/** An attack carried into a run of `validatorCount` validators: attackers
 * beyond the new count are dropped, and an attack left without attackers
 * is removed (an attacker set is non-empty by definition). */
function clampAttack(
  attack: AttackInstance | undefined,
  validatorCount: number,
): AttackInstance | undefined {
  if (attack === undefined) return undefined
  const attackers = attack.attackers.filter((v) => v < validatorCount)
  return attackers.length === 0 ? undefined : { ...attack, attackers }
}

const freshCore = (
  config: InitialConditions,
  attack: AttackInstance | undefined,
  throughSlot: number | undefined,
): SessionCore => {
  const kept = clampAttack(attack, config.validatorCount)
  return {
    config,
    interventions: [],
    attack: kept,
    throughSlot: kept === undefined ? undefined : throughSlot,
    runSlot: 0,
    cursor: 0,
  }
}

const defaultConfig = (validatorCount: number): InitialConditions => ({
  validatorCount,
  seed: DEFAULT_SEED,
  params: DEFAULT_PARAMS,
  initialStakes: equalStakes(validatorCount),
})

/** The end slot a saved attack's run is proposed with: its library default. */
const libraryThroughSlot = (attack: AttackInstance | undefined): number | undefined =>
  attack === undefined ? undefined : findLibraryAttack(attack.id)?.defaultRun.throughSlot

export function useSimulation(): SimulationSession {
  const [core, setCore] = useState<SessionCore>(() =>
    freshCore(defaultConfig(DEFAULT_VALIDATOR_COUNT), undefined, undefined),
  )

  const [playing, setPlaying] = useState<Playing | undefined>(undefined)
  const [speed, setSpeed] = useState<PlaySpeed>('normal')

  const { config, interventions, attack, throughSlot, runSlot, cursor } = core

  const run = useMemo(
    () =>
      runScenario(
        { config, interventions, ...(attack === undefined ? {} : { attack }) },
        runSlot,
      ),
    [config, interventions, attack, runSlot],
  )
  const delivery = useMemo(
    () => compileDelivery(run.interventions),
    [run.interventions],
  )

  const advance = useCallback(() => {
    setCore((c) => ({ ...c, runSlot: c.cursor + 1, cursor: c.cursor + 1 }))
  }, [])

  const setCursor = useCallback((slot: number) => {
    setPlaying(undefined)
    setCore((c) => ({
      ...c,
      cursor: Math.min(Math.max(slot, 0), c.runSlot),
    }))
  }, [])

  const play = useCallback(() => {
    setPlaying((p) => p ?? { from: cursor })
  }, [cursor])

  const pause = useCallback(() => {
    setPlaying(undefined)
  }, [])

  const achievedAt = run.goal === undefined ? undefined : goalAchievedAt(run.goal)

  const playEnd =
    attack !== undefined && throughSlot !== undefined
      ? throughSlot
      : (playing?.from ?? cursor) + FREE_PLAY_SPAN

  useEffect(() => {
    if (playing === undefined) return
    const achievedHere =
      achievedAt !== undefined && achievedAt === cursor && achievedAt > playing.from
    if (cursor >= playEnd || achievedHere) {
      setPlaying(undefined)
      return
    }
    const timer = setTimeout(advance, PLAY_INTERVALS_MS[speed])
    return () => clearTimeout(timer)
  }, [playing, cursor, playEnd, achievedAt, speed, advance])

  const setInterventions = useCallback(
    (next: readonly Intervention[]) => {
      setCore((c) => ({ ...c, interventions: next }))
    },
    [],
  )

  const setConfig = useCallback((next: InitialConditions) => {
    setCore((c) => {
      if (next.validatorCount === c.config.validatorCount) return { ...c, config: next }
      setPlaying(undefined)
      return freshCore(next, c.attack, c.throughSlot)
    })
  }, [])

  const setValidatorCount = useCallback((count: number) => {
    setPlaying(undefined)
    setCore((c) =>
      freshCore(
        {
          ...c.config,
          validatorCount: count,
          initialStakes: equalStakes(count).map(
            (s, v) => c.config.initialStakes[v] ?? s,
          ),
        },
        c.attack,
        c.throughSlot,
      ),
    )
  }, [])

  const setAttack = useCallback((next: AttackInstance | undefined) => {
    setCore((c) => ({
      ...c,
      attack: next,
      throughSlot:
        next === undefined
          ? undefined
          : c.attack?.id === next.id
            ? c.throughSlot
            : libraryThroughSlot(next),
    }))
  }, [])

  const proposeAttack = useCallback((entry: LibraryAttack) => {
    setPlaying(undefined)
    setCore(
      freshCore(defaultConditions(entry), defaultInstance(entry), entry.defaultRun.throughSlot),
    )
  }, [])

  const setThroughSlot = useCallback((slot: number) => {
    setCore((c) => (c.attack === undefined ? c : { ...c, throughSlot: slot }))
  }, [])

  const loadScenario = useCallback((scenario: Scenario, runSlot: number) => {
    setPlaying(undefined)
    setCore({
      config: scenario.config,
      interventions: scenario.interventions,
      attack: scenario.attack,
      throughSlot: libraryThroughSlot(scenario.attack),
      runSlot,
      cursor: runSlot,
    })
  }, [])

  const current = run.states[cursor]
  if (current === undefined) throw new Error('simulation has no states')

  return useMemo(
    () => ({
      config,
      interventions,
      attack,
      throughSlot,
      generated: run.generated,
      effective: run.interventions,
      goal: run.goal,
      delivery,
      states: run.states,
      runSlot,
      cursor,
      current,
      playing: playing !== undefined,
      speed,
      playEnd,
      advance,
      play,
      pause,
      setSpeed,
      setCursor,
      setInterventions,
      setConfig,
      setValidatorCount,
      setAttack,
      proposeAttack,
      setThroughSlot,
      loadScenario,
    }),
    [
      config,
      interventions,
      attack,
      throughSlot,
      run,
      delivery,
      runSlot,
      cursor,
      current,
      playing,
      speed,
      playEnd,
      advance,
      play,
      pause,
      setSpeed,
      setCursor,
      setInterventions,
      setConfig,
      setValidatorCount,
      setAttack,
      proposeAttack,
      setThroughSlot,
      loadScenario,
    ],
  )
}
