/**
 * The pluggable consensus layer.
 *
 * A protocol stack is an ordered list of layers, bottom (most available) to top
 * (most final). Three properties of the interface come straight from what the
 * Decoupled Consensus literature demands and a naive "one layer per protocol"
 * design cannot express:
 *
 *  1. `participants` — layers do NOT share a validator set. Block production
 *     runs on a small sampled committee while finality runs over everyone.
 *  2. `standalone` — a layer that produces a ledger on its own can be run as a
 *     one-element stack, which is how an individual protocol gets simulated in
 *     isolation.
 *  3. `LayerContext.below` — layers read each other's output explicitly, rather
 *     than through hidden shared state. The three-tier fork choice
 *     (FFG -> stabilization -> available chain) is a composition over this.
 */

import type { Hash } from '../core/hash'
import type { Checkpoint, Epoch, Slot, Time, ValidatorInfo } from '../core/types'
import type { Rng } from '../core/rng'
import type { Envelope, LayerId, ProtocolMessage } from './messages'
import type { GasperSnapshot } from './gasper/types'

/** Who takes part in a layer. */
export type ParticipantSet =
  | { readonly kind: 'all' }
  /** A fixed-size subset resampled each slot — Decoupled's "512 validators". */
  | { readonly kind: 'committee'; readonly size: number }
  /** Each validator self-elects with probability `threshold` — Goldfish's VRF. */
  | { readonly kind: 'vrf'; readonly threshold: number }

/** The output a layer publishes to the layer above it and to the views. */
export interface LayerView {
  readonly head: Hash
  readonly justified: Checkpoint
  readonly finalized: Checkpoint
}

export interface TimerRequest {
  readonly label: string
  /** Milliseconds after the start of the slot. */
  readonly offsetMs: Time
}

export interface LayerContext {
  readonly time: Time
  readonly slot: Slot
  readonly epoch: Epoch
  readonly validator: ValidatorInfo
  readonly rng: Rng
  /** Views of the layers below this one, bottom-first. Empty for the bottom layer. */
  readonly below: readonly LayerView[]
}

/** Renderable per-node state. The union grows as layers are added. */
export type LayerSnapshot = GasperSnapshot

export interface ConsensusLayer<S> {
  readonly id: LayerId
  readonly displayName: string
  readonly participants: ParticipantSet
  /** Whether this layer alone yields a usable ledger. */
  readonly standalone: boolean

  createState(validator: ValidatorInfo): S
  /** Duties this layer schedules inside every slot. */
  slotTimers(): readonly TimerRequest[]
  onTimer(ctx: LayerContext, state: S, label: string): readonly ProtocolMessage[]
  onMessage(ctx: LayerContext, state: S, envelope: Envelope): void
  view(state: S): LayerView
  snapshot(state: S): LayerSnapshot
}

/**
 * A layer bound to one node's state.
 *
 * The state type is hidden behind the closure rather than surfacing as a type
 * parameter, so a heterogeneous stack stays typed without `any`.
 */
export interface LayerInstance {
  readonly id: LayerId
  readonly displayName: string
  readonly participants: ParticipantSet
  readonly timers: readonly TimerRequest[]
  onTimer(ctx: LayerContext, label: string): readonly ProtocolMessage[]
  onMessage(ctx: LayerContext, envelope: Envelope): void
  view(): LayerView
  snapshot(): LayerSnapshot
}

export function instantiateLayer<S>(
  layer: ConsensusLayer<S>,
  validator: ValidatorInfo,
): LayerInstance {
  const state = layer.createState(validator)
  return {
    id: layer.id,
    displayName: layer.displayName,
    participants: layer.participants,
    timers: layer.slotTimers(),
    onTimer: (ctx, label) => layer.onTimer(ctx, state, label),
    onMessage: (ctx, envelope) => layer.onMessage(ctx, state, envelope),
    view: () => layer.view(state),
    snapshot: () => layer.snapshot(state),
  }
}

/** Binds a layer definition to a node, hiding the state type. */
export type LayerFactory = (validator: ValidatorInfo) => LayerInstance

export function layerFactory<S>(layer: ConsensusLayer<S>): LayerFactory {
  return (validator) => instantiateLayer(layer, validator)
}

/**
 * An ordered stack, bottom-first. A stack must contain at least one standalone
 * layer, otherwise nothing in it can produce a ledger.
 */
export interface ProtocolStack {
  readonly name: string
  readonly layers: readonly LayerFactory[]
}
