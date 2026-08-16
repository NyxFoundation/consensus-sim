/**
 * Domain vocabulary shared by the engine, the protocol layers and the views.
 *
 * A note on mutability: everything that crosses a boundary — configuration,
 * messages, the snapshots the UI reads — is `readonly`. The one deliberate
 * exception is a node's own local store, which its handlers mutate in place.
 * Rebuilding a validator's whole view on every received attestation would
 * dominate the run time at N=1000 without buying any safety, since that store
 * is reachable from exactly one node.
 */

import type { Hash } from './hash'

/** Simulated wall-clock, in milliseconds since genesis. */
export type Time = number

/** Index of a network participant. In M1 there is one validator per node. */
export type NodeId = number

/** Index into the validator registry. */
export type ValidatorIndex = number

export type Slot = number
export type Epoch = number

/** Gwei. Effective balances drive both fork-choice weight and FFG quorums. */
export type Gwei = number

/** How a validator behaves. M1 ships the two non-adversarial cases. */
export type NodeRole = 'honest' | 'offline'

export interface ValidatorInfo {
  readonly index: ValidatorIndex
  readonly nodeId: NodeId
  readonly role: NodeRole
}

/** A checkpoint is the (epoch boundary block, epoch) pair Casper FFG votes on. */
export interface Checkpoint {
  readonly root: Hash
  readonly epoch: Epoch
}

export function checkpointKey(checkpoint: Checkpoint): string {
  return `${checkpoint.root}:${checkpoint.epoch}`
}

export function sameCheckpoint(a: Checkpoint, b: Checkpoint): boolean {
  return a.epoch === b.epoch && a.root === b.root
}
