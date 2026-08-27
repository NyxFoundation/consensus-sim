/**
 * The flat, UI-shaped view of the parameters, and its translation into engine
 * config.
 *
 * Keeping this separate from `GasperParams` means the panel can expose a
 * partition as "slots 8 to 20, two groups" while the engine keeps receiving
 * absolute milliseconds, and neither has to know about the other's units.
 */

import type { DelayDistribution } from '../core/network'
import type { GasperParams } from '../setup'

export interface Settings {
  readonly seed: number
  readonly validatorCount: number
  readonly offlineRatio: number
  readonly slotDurationMs: number
  readonly slotsPerEpoch: number
  readonly proposerBoostPercent: number
  readonly baseDelayMs: number
  readonly jitterMs: number
  readonly distribution: DelayDistribution
  readonly partitionEnabled: boolean
  readonly partitionStartSlot: number
  readonly partitionEndSlot: number
  readonly partitionGroups: number
}

export const DEFAULT_SETTINGS: Settings = {
  seed: 1,
  validatorCount: 64,
  offlineRatio: 0,
  slotDurationMs: 12_000,
  slotsPerEpoch: 8,
  proposerBoostPercent: 40,
  baseDelayMs: 400,
  jitterMs: 200,
  distribution: 'normal',
  partitionEnabled: false,
  partitionStartSlot: 8,
  partitionEndSlot: 16,
  partitionGroups: 2,
}

export function toParams(settings: Settings): GasperParams {
  const partitions = settings.partitionEnabled
    ? [
        {
          startMs: settings.partitionStartSlot * settings.slotDurationMs,
          endMs: settings.partitionEndSlot * settings.slotDurationMs,
          groupCount: settings.partitionGroups,
        },
      ]
    : []

  return {
    seed: settings.seed,
    validatorCount: settings.validatorCount,
    offlineRatio: settings.offlineRatio,
    slotDurationMs: settings.slotDurationMs,
    slotsPerEpoch: settings.slotsPerEpoch,
    proposerBoostPercent: settings.proposerBoostPercent,
    network: {
      baseDelayMs: settings.baseDelayMs,
      jitterMs: settings.jitterMs,
      distribution: settings.distribution,
      partitions,
    },
  }
}
