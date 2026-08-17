/**
 * The discrete-event driver.
 *
 * Three event kinds and nothing else:
 *
 *   slot    — a slot boundary; schedules every node's duties for that slot
 *   timer   — one node's duty firing (propose, attest, ...)
 *   deliver — one message arriving at one node
 *
 * There is no global "current state of the chain" anywhere in here. The only
 * chain-shaped thing the driver keeps is `blocks`, an explicitly-labelled
 * god view used solely for drawing the fork tree; no node ever reads it.
 */

import { EventQueue } from './eventQueue'
import type { Hash } from './hash'
import { Network } from './network'
import type { NetworkConfig } from './network'
import { makeRng } from './rng'
import type { Rng } from './rng'
import type { NodeId, NodeRole, Slot, Time, ValidatorInfo } from './types'
import type { LayerContext, LayerFactory, LayerInstance, LayerSnapshot, LayerView } from '../protocol/layer'
import type { Envelope, LayerId, MessageKind, ProtocolMessage } from '../protocol/messages'
import type { Block, GasperConfig } from '../protocol/gasper/types'
import { epochOf } from '../protocol/gasper/types'

export interface SimulationConfig {
  readonly seed: number
  readonly validatorCount: number
  /** Share of validators that take no part. Byzantine strategies arrive in M2. */
  readonly offlineRatio: number
  readonly network: NetworkConfig
  readonly gasper: GasperConfig
}

export interface NodeRuntime {
  readonly validator: ValidatorInfo
  readonly layers: readonly LayerInstance[]
}

type EventPayload =
  | { readonly kind: 'slot'; readonly slot: Slot }
  | {
      readonly kind: 'timer'
      readonly node: NodeId
      readonly slot: Slot
      readonly layerIndex: number
      readonly label: string
    }
  | { readonly kind: 'deliver'; readonly to: NodeId; readonly envelope: Envelope }

const NO_LOWER_LAYERS: readonly LayerView[] = []

/**
 * One broadcast and how far it has spread.
 *
 * Without this the views could only show outcomes — a block exists, a head
 * changed — and the slot would read as nothing happening followed by a sudden
 * jump. Propagation is the part of a slot that is actually continuous, and it
 * is where latency and partitions become visible rather than merely inferable.
 */
interface MutablePublication {
  readonly id: number
  readonly time: Time
  readonly slot: Slot
  readonly from: NodeId
  readonly layer: LayerId
  readonly kind: MessageKind
  /** How many nodes it is addressed to. */
  readonly audience: number
  /** Nodes that hold it so far, counting the sender. */
  delivered: number
  /**
   * When each tenth of the audience was first reached, so the spread can be
   * plotted against the slot's clock rather than as a bare fraction. Storing
   * deciles rather than every delivery keeps this eleven numbers per broadcast
   * instead of one per node.
   */
  readonly milestones: (Time | null)[]
  nextMilestone: number
}

export type Publication = Readonly<MutablePublication>

const MILESTONE_STEPS = 10

/** Bounds the log; a few slots of history is all any view asks for. */
const PUBLICATION_HISTORY = 4096

/** Assigns roles over a shuffled index list so offline nodes are not clustered. */
function assignRoles(count: number, offlineRatio: number, rng: Rng): readonly NodeRole[] {
  const offlineCount = Math.min(count, Math.floor(count * offlineRatio))
  const order = rng.shuffle(Array.from({ length: count }, (_, i) => i))
  const roles: NodeRole[] = Array.from({ length: count }, () => 'honest')

  for (let i = 0; i < offlineCount; i++) {
    const target = order[i]
    if (target !== undefined) roles[target] = 'offline'
  }
  return roles
}

export class Simulation {
  readonly nodes: readonly NodeRuntime[]
  /** Every block ever broadcast. Rendering only — not a node's view. */
  readonly blocks = new Map<Hash, Block>()

  private readonly queue = new EventQueue<EventPayload>()
  private readonly network: Network
  private readonly rng: Rng
  private currentTime: Time = 0
  private currentSlot: Slot = 0
  private messagesInFlight = 0
  private readonly publications: MutablePublication[] = []
  private readonly publicationsById = new Map<number, MutablePublication>()
  private nextPublicationId = 0

  constructor(
    readonly config: SimulationConfig,
    layerFactories: readonly LayerFactory[],
    genesis: Block,
  ) {
    this.rng = makeRng(config.seed)
    this.network = new Network(config.network, config.validatorCount, this.rng.fork('network'))
    this.blocks.set(genesis.root, genesis)

    const roles = assignRoles(config.validatorCount, config.offlineRatio, this.rng.fork('roles'))
    this.nodes = Array.from({ length: config.validatorCount }, (_, index) => {
      const validator: ValidatorInfo = {
        index,
        nodeId: index,
        role: roles[index] ?? 'honest',
      }
      return { validator, layers: layerFactories.map((make) => make(validator)) }
    })

    this.queue.push(0, { kind: 'slot', slot: 0 })
  }

  get time(): Time {
    return this.currentTime
  }

  get slot(): Slot {
    return this.currentSlot
  }

  get pendingMessages(): number {
    return this.messagesInFlight
  }

  /** Processes one event. Returns false when the queue has drained. */
  step(): boolean {
    const event = this.queue.pop()
    if (event === null) return false

    this.currentTime = event.time
    this.handle(event.payload)
    return true
  }

  /**
   * Runs until `target`. `maxEvents` bounds the work done in one call so a slow
   * configuration degrades into a lagging simulation rather than a frozen tab.
   */
  advanceTo(target: Time, maxEvents = 200_000): void {
    let processed = 0
    for (;;) {
      const next = this.queue.peekTime()
      if (next === null || next > target || processed >= maxEvents) break
      this.step()
      processed += 1
    }
    if (this.currentTime < target) this.currentTime = target
  }

  /** Per-node consensus view, used by the validator grid. */
  viewOf(nodeId: NodeId): LayerView | null {
    const node = this.nodes[nodeId]
    const top = node?.layers[node.layers.length - 1]
    return top === undefined ? null : top.view()
  }

  snapshotOf(nodeId: NodeId): LayerSnapshot | null {
    const node = this.nodes[nodeId]
    const top = node?.layers[node.layers.length - 1]
    return top === undefined ? null : top.snapshot()
  }

  /** Everything broadcast during `slot`, with its current delivery count. */
  publicationsInSlot(slot: Slot): readonly Publication[] {
    return this.publications.filter((publication) => publication.slot === slot)
  }

  private handle(payload: EventPayload): void {
    switch (payload.kind) {
      case 'slot':
        this.handleSlot(payload.slot)
        return
      case 'timer':
        this.handleTimer(payload)
        return
      case 'deliver':
        this.messagesInFlight -= 1
        this.applyToNode(payload.to, payload.envelope)
        return
    }
  }

  private handleSlot(slot: Slot): void {
    this.currentSlot = slot
    const slotStart = slot * this.config.gasper.slotDurationMs

    for (const node of this.nodes) {
      node.layers.forEach((layer, layerIndex) => {
        for (const timer of layer.timers) {
          this.queue.push(slotStart + timer.offsetMs, {
            kind: 'timer',
            node: node.validator.nodeId,
            slot,
            layerIndex,
            label: timer.label,
          })
        }
      })
    }

    this.queue.push(slotStart + this.config.gasper.slotDurationMs, { kind: 'slot', slot: slot + 1 })
  }

  private handleTimer(payload: Extract<EventPayload, { kind: 'timer' }>): void {
    const node = this.nodes[payload.node]
    const layer = node?.layers[payload.layerIndex]
    if (node === undefined || layer === undefined) return

    const ctx = this.contextFor(node, payload.slot, payload.layerIndex)
    for (const message of layer.onTimer(ctx, payload.label)) {
      this.broadcast(node.validator.nodeId, message)
    }
  }

  private openPublication(from: NodeId, message: ProtocolMessage): MutablePublication {
    const publication: MutablePublication = {
      id: this.nextPublicationId++,
      time: this.currentTime,
      slot: this.currentSlot,
      from,
      layer: message.layer,
      kind: message.kind,
      audience: this.nodes.length,
      delivered: 0,
      milestones: Array.from({ length: MILESTONE_STEPS + 1 }, () => null),
      nextMilestone: 0,
    }

    this.publications.push(publication)
    this.publicationsById.set(publication.id, publication)
    if (this.publications.length > PUBLICATION_HISTORY) {
      const evicted = this.publications.shift()
      if (evicted !== undefined) this.publicationsById.delete(evicted.id)
    }
    return publication
  }

  private recordDelivery(publication: MutablePublication): void {
    publication.delivered += 1

    while (
      publication.nextMilestone <= MILESTONE_STEPS &&
      publication.delivered >=
        Math.ceil((publication.nextMilestone * publication.audience) / MILESTONE_STEPS)
    ) {
      publication.milestones[publication.nextMilestone] = this.currentTime
      publication.nextMilestone += 1
    }
  }

  private broadcast(from: NodeId, message: ProtocolMessage): void {
    if (message.kind === 'block') this.blocks.set(message.block.root, message.block)

    const publication = this.openPublication(from, message)
    const envelope: Envelope = { from, message, publicationId: publication.id }
    // The sender applies its own message with no delay, as gossip clients do.
    this.applyToNode(from, envelope)

    for (const node of this.nodes) {
      const to = node.validator.nodeId
      if (to === from) continue
      this.messagesInFlight += 1
      this.queue.push(this.network.arrivalTime(from, to, this.currentTime), {
        kind: 'deliver',
        to,
        envelope,
      })
    }
  }

  private applyToNode(to: NodeId, envelope: Envelope): void {
    const node = this.nodes[to]
    if (node === undefined) return

    const publication = this.publicationsById.get(envelope.publicationId)
    if (publication !== undefined) this.recordDelivery(publication)

    const slot = Math.floor(this.currentTime / this.config.gasper.slotDurationMs)
    node.layers.forEach((layer, layerIndex) => {
      if (layer.id !== envelope.message.layer) return
      layer.onMessage(this.contextFor(node, slot, layerIndex), envelope)
    })
  }

  private contextFor(node: NodeRuntime, slot: Slot, layerIndex: number): LayerContext {
    return {
      time: this.currentTime,
      slot,
      epoch: epochOf(slot, this.config.gasper.slotsPerEpoch),
      validator: node.validator,
      rng: this.rng,
      below:
        layerIndex === 0
          ? NO_LOWER_LAYERS
          : node.layers.slice(0, layerIndex).map((layer) => layer.view()),
    }
  }
}
