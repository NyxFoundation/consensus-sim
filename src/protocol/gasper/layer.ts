/**
 * Gasper as a consensus layer.
 *
 * Duties per slot: propose at the slot boundary, attest one third of the way
 * in. An honest validator runs the fork choice immediately before each duty, so
 * whatever it has heard by that instant is what it votes on — which is why
 * latency and partitions change the outcome rather than merely the timing.
 */

import { digest, ZERO_HASH } from '../../core/hash'
import type { Hash } from '../../core/hash'
import type { Checkpoint, ValidatorInfo } from '../../core/types'
import type { ConsensusLayer, LayerContext, LayerView, TimerRequest } from '../layer'
import type { Envelope, ProtocolMessage } from '../messages'
import { ForkChoice } from './forkChoice'
import { GasperStore } from './store'
import type { GasperSchedule } from './schedule'
import type { Attestation, Block, GasperConfig, GasperSnapshot } from './types'
import { epochOf, firstSlotOf } from './types'

export const SLOT_START = 'slot-start'
export const ATTEST = 'attest'

export interface GasperState {
  readonly validator: ValidatorInfo
  readonly store: GasperStore
  readonly forkChoice: ForkChoice
}

export interface GasperDeps {
  readonly config: GasperConfig
  readonly schedule: GasperSchedule
}

export function genesisBlock(): Block {
  return { root: digest('genesis'), slot: 0, parent: ZERO_HASH, proposer: 0 }
}

function blockRoot(slot: number, parent: Hash, proposer: number): Hash {
  return digest(`block|${slot}|${parent}|${proposer}`)
}

function buildBlock(slot: number, parent: Hash, proposer: number): Block {
  return { root: blockRoot(slot, parent, proposer), slot, parent, proposer }
}

function buildAttestation(state: GasperState, ctx: LayerContext, config: GasperConfig): Attestation {
  const head = state.forkChoice.head()
  const epochStart = firstSlotOf(ctx.epoch, config.slotsPerEpoch)
  const target: Checkpoint = {
    root: state.store.ancestorAtOrBefore(head, epochStart),
    epoch: ctx.epoch,
  }
  return {
    validator: state.validator.index,
    slot: ctx.slot,
    head,
    source: state.store.justified,
    target,
  }
}

/** Blocks that arrive on time for their own slot earn proposer boost. */
function isBoostEligible(block: Block, ctx: LayerContext, config: GasperConfig): boolean {
  if (block.slot !== ctx.slot) return false
  const slotStart = block.slot * config.slotDurationMs
  return ctx.time < slotStart + config.attestationOffsetMs
}

function onSlotStart(
  state: GasperState,
  ctx: LayerContext,
  deps: GasperDeps,
): readonly ProtocolMessage[] {
  const { config, schedule } = deps
  state.store.clearProposerBoost()

  if (ctx.slot % config.slotsPerEpoch === 0) {
    state.store.processEpochTransition(ctx.epoch)
  }

  // Slot 0 is occupied by the genesis block; proposals start at slot 1.
  if (ctx.slot === 0) return []
  if (state.validator.role === 'offline') return []
  if (schedule.proposerAt(ctx.slot) !== state.validator.index) return []

  const parent = state.forkChoice.head()
  const block = buildBlock(ctx.slot, parent, state.validator.index)
  return [{ layer: 'gasper', kind: 'block', block }]
}

function onAttest(
  state: GasperState,
  ctx: LayerContext,
  deps: GasperDeps,
): readonly ProtocolMessage[] {
  if (state.validator.role === 'offline') return []
  if (!deps.schedule.isAttester(ctx.slot, state.validator.index)) return []

  const attestation = buildAttestation(state, ctx, deps.config)
  return [{ layer: 'gasper', kind: 'attestation', attestation }]
}

export function createGasperLayer(deps: GasperDeps): ConsensusLayer<GasperState> {
  const { config } = deps
  const genesis = genesisBlock()

  const timers: readonly TimerRequest[] = [
    { label: SLOT_START, offsetMs: 0 },
    { label: ATTEST, offsetMs: config.attestationOffsetMs },
  ]

  return {
    id: 'gasper',
    displayName: 'Gasper (LMD-GHOST + Casper FFG)',
    // One committee per slot: Gasper's 1/32-at-a-time structure, which is the
    // very coupling Decoupled Consensus sets out to remove.
    participants: { kind: 'committee', size: Math.ceil(config.validatorCount / config.slotsPerEpoch) },
    standalone: true,

    createState(validator: ValidatorInfo): GasperState {
      const store = new GasperStore(config, genesis)
      return { validator, store, forkChoice: new ForkChoice(store) }
    },

    slotTimers: () => timers,

    onTimer(ctx, state, label) {
      if (label === SLOT_START) return onSlotStart(state, ctx, deps)
      if (label === ATTEST) return onAttest(state, ctx, deps)
      return []
    },

    onMessage(ctx, state, envelope: Envelope) {
      const { message } = envelope
      if (message.kind === 'block') {
        const added = state.store.addBlock(message.block)
        if (added && isBoostEligible(message.block, ctx, config)) {
          state.store.setProposerBoost(message.block.root)
        }
        return
      }
      state.store.addAttestation(message.attestation)
    },

    view(state): LayerView {
      return {
        head: state.forkChoice.head(),
        justified: state.store.justified,
        finalized: state.store.finalized,
      }
    },

    snapshot(state): GasperSnapshot {
      const { head, weights } = state.forkChoice.get()
      return {
        layer: 'gasper',
        head,
        justified: state.store.justified,
        finalized: state.store.finalized,
        weights,
        proposerBoostRoot: state.store.proposerBoostRoot,
        knownBlockCount: state.store.blocks.size,
        attestationCount: state.store.attestationCount,
      }
    },
  }
}

export { epochOf }
