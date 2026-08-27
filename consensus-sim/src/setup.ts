/**
 * Assembles a runnable simulation from plain parameters.
 *
 * This is the seam the browser UI and a headless runner both go through: build
 * a config, get a `Simulation`, drive it. Nothing here touches the DOM.
 */

import { Simulation } from './core/simulation'
import type { SimulationConfig } from './core/simulation'
import { DEFAULT_NETWORK } from './core/network'
import type { NetworkConfig } from './core/network'
import { makeRng } from './core/rng'
import { layerFactory } from './protocol/layer'
import { createGasperLayer, genesisBlock } from './protocol/gasper/layer'
import { GasperSchedule } from './protocol/gasper/schedule'
import { MAINNET_LIKE } from './protocol/gasper/types'
import type { GasperConfig } from './protocol/gasper/types'

export interface GasperParams {
  readonly seed: number
  readonly validatorCount: number
  readonly offlineRatio: number
  readonly slotDurationMs: number
  readonly slotsPerEpoch: number
  readonly proposerBoostPercent: number
  readonly network: NetworkConfig
}

export const DEFAULT_PARAMS: GasperParams = {
  seed: 1,
  validatorCount: 64,
  offlineRatio: 0,
  slotDurationMs: MAINNET_LIKE.slotDurationMs,
  slotsPerEpoch: MAINNET_LIKE.slotsPerEpoch,
  proposerBoostPercent: MAINNET_LIKE.proposerBoostPercent,
  network: DEFAULT_NETWORK,
}

export function toGasperConfig(params: GasperParams): GasperConfig {
  return {
    slotsPerEpoch: params.slotsPerEpoch,
    slotDurationMs: params.slotDurationMs,
    // The spec places the attestation deadline one third into the slot.
    attestationOffsetMs: Math.round(params.slotDurationMs / 3),
    proposerBoostPercent: params.proposerBoostPercent,
    validatorCount: params.validatorCount,
    effectiveBalanceGwei: MAINNET_LIKE.effectiveBalanceGwei,
  }
}

export function toSimulationConfig(params: GasperParams): SimulationConfig {
  return {
    seed: params.seed,
    validatorCount: params.validatorCount,
    offlineRatio: params.offlineRatio,
    network: params.network,
    gasper: toGasperConfig(params),
  }
}

/**
 * The schedule comes back alongside the simulation rather than hiding inside
 * it. Duties are Gasper's business, not the driver's, and the views need to
 * show who proposes and who is on this slot's committee — the 1/32 structure
 * that Decoupled Consensus exists to break, and which is invisible if the only
 * things drawn are blocks and heads.
 */
export interface GasperScenario {
  readonly sim: Simulation
  readonly schedule: GasperSchedule
}

export function createGasperSimulation(params: GasperParams): GasperScenario {
  const config = toSimulationConfig(params)
  // Duty assignment draws from its own stream so that changing, say, the
  // network model does not reshuffle committees and invalidate a comparison.
  const schedule = new GasperSchedule(config.gasper, makeRng(config.seed).fork('duties'))
  const layer = createGasperLayer({ config: config.gasper, schedule })

  return { sim: new Simulation(config, [layerFactory(layer)], genesisBlock()), schedule }
}
