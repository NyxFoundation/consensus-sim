/**
 * Gasper's data model: blocks, attestations, and the configuration that shapes
 * both.
 *
 * The single attestation carrying *both* a head vote and an FFG source/target
 * pair is the defining feature of Gasper — the block-production and finality
 * pipelines are coupled through one message. Decoupled Consensus exists to
 * break exactly this, so keeping it visible in the type is deliberate.
 */

import type { Hash } from '../../core/hash'
import type { Checkpoint, Epoch, Gwei, Slot, ValidatorIndex } from '../../core/types'

export interface Block {
  readonly root: Hash
  readonly slot: Slot
  readonly parent: Hash
  readonly proposer: ValidatorIndex
}

export interface Attestation {
  readonly validator: ValidatorIndex
  readonly slot: Slot
  /** LMD-GHOST head vote. */
  readonly head: Hash
  /** Casper FFG link — justified checkpoint the voter builds from. */
  readonly source: Checkpoint
  /** Casper FFG link — epoch boundary block the voter justifies. */
  readonly target: Checkpoint
}

export type GasperMessage =
  | { readonly layer: 'gasper'; readonly kind: 'block'; readonly block: Block }
  | { readonly layer: 'gasper'; readonly kind: 'attestation'; readonly attestation: Attestation }

export interface GasperConfig {
  readonly slotsPerEpoch: number
  readonly slotDurationMs: number
  /** Offset within the slot at which committee members attest (spec: 1/3). */
  readonly attestationOffsetMs: number
  /**
   * Proposer boost, as a percentage of one committee's weight. The current
   * mainnet value is 40. This is Gasper's answer to ex-ante reorgs — the same
   * problem Goldfish solves with view-merge — so it is a first-class parameter,
   * not a constant.
   */
  readonly proposerBoostPercent: number
  readonly validatorCount: number
  readonly effectiveBalanceGwei: number
}

export const MAINNET_LIKE: Omit<GasperConfig, 'validatorCount'> = {
  slotsPerEpoch: 32,
  slotDurationMs: 12_000,
  attestationOffsetMs: 4_000,
  proposerBoostPercent: 40,
  effectiveBalanceGwei: 32_000_000_000,
}

export function epochOf(slot: Slot, slotsPerEpoch: number): Epoch {
  return Math.floor(slot / slotsPerEpoch)
}

export function firstSlotOf(epoch: Epoch, slotsPerEpoch: number): Slot {
  return epoch * slotsPerEpoch
}

export function totalActiveBalance(config: GasperConfig): Gwei {
  return config.validatorCount * config.effectiveBalanceGwei
}

/** One committee's share of the stake — the unit proposer boost is measured in. */
export function committeeWeight(config: GasperConfig): Gwei {
  return Math.floor(totalActiveBalance(config) / config.slotsPerEpoch)
}

export function proposerBoostWeight(config: GasperConfig): Gwei {
  return Math.floor((committeeWeight(config) * config.proposerBoostPercent) / 100)
}

/**
 * What one node's Gasper store exposes to the views. Built on demand for the
 * observed node only — computing subtree weights for all N nodes every frame
 * would dominate the frame budget and nothing renders it.
 */
export interface GasperSnapshot {
  readonly layer: 'gasper'
  readonly head: Hash
  readonly justified: Checkpoint
  readonly finalized: Checkpoint
  /** Subtree weight per known block, as this node currently computes it. */
  readonly weights: ReadonlyMap<Hash, Gwei>
  readonly proposerBoostRoot: Hash | null
  readonly knownBlockCount: number
  readonly attestationCount: number
}
