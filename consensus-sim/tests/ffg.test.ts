import { describe, expect, it } from 'vitest'
import { GasperStore } from '../src/protocol/gasper/store'
import { genesisBlock } from '../src/protocol/gasper/layer'
import type { Attestation, Block, GasperConfig } from '../src/protocol/gasper/types'
import type { Checkpoint } from '../src/core/types'

const CONFIG: GasperConfig = {
  slotsPerEpoch: 4,
  slotDurationMs: 1200,
  attestationOffsetMs: 400,
  proposerBoostPercent: 40,
  validatorCount: 16,
  effectiveBalanceGwei: 32_000_000_000,
}

/** ceil(2/3 * 16) = 11 validators carry a supermajority here. */
const SUPERMAJORITY = 11

const GENESIS = genesisBlock()
const EPOCH_1_ROOT: Block = { root: 'e100000000000001', slot: 4, parent: GENESIS.root, proposer: 0 }
const EPOCH_2_ROOT: Block = {
  root: 'e200000000000002',
  slot: 8,
  parent: EPOCH_1_ROOT.root,
  proposer: 1,
}

function checkpoint(root: string, epoch: number): Checkpoint {
  return { root, epoch }
}

function ffgVote(validator: number, source: Checkpoint, target: Checkpoint): Attestation {
  return { validator, slot: target.epoch * CONFIG.slotsPerEpoch, head: target.root, source, target }
}

function freshStore(): GasperStore {
  const store = new GasperStore(CONFIG, GENESIS)
  store.addBlock(EPOCH_1_ROOT)
  store.addBlock(EPOCH_2_ROOT)
  return store
}

function castLink(store: GasperStore, source: Checkpoint, target: Checkpoint, voters: number): void {
  for (let validator = 0; validator < voters; validator++) {
    store.addAttestation(ffgVote(validator, source, target))
  }
}

describe('Casper FFG justification and finalization', () => {
  it('should start with genesis justified and finalized', () => {
    const store = freshStore()
    expect(store.justified.epoch).toBe(0)
    expect(store.finalized.epoch).toBe(0)
  })

  it('should not justify a target that fell short of a supermajority', () => {
    const store = freshStore()
    castLink(
      store,
      checkpoint(GENESIS.root, 0),
      checkpoint(EPOCH_1_ROOT.root, 1),
      SUPERMAJORITY - 1,
    )
    store.processEpochTransition(2)

    expect(store.justified.epoch).toBe(0)
  })

  it('should withhold justification until the target epoch has passed', () => {
    const store = freshStore()
    castLink(store, checkpoint(GENESIS.root, 0), checkpoint(EPOCH_1_ROOT.root, 1), SUPERMAJORITY)

    // Still inside epoch 1: attesters must keep voting the same source.
    store.processEpochTransition(1)
    expect(store.justified.epoch).toBe(0)

    store.processEpochTransition(2)
    expect(store.justified.epoch).toBe(1)
  })

  it('should justify the target once a supermajority links it to a justified source', () => {
    const store = freshStore()
    castLink(store, checkpoint(GENESIS.root, 0), checkpoint(EPOCH_1_ROOT.root, 1), SUPERMAJORITY)
    store.processEpochTransition(2)

    expect(store.justified).toEqual(checkpoint(EPOCH_1_ROOT.root, 1))
  })

  it('should finalize the source after two consecutive justified epochs', () => {
    const store = freshStore()
    castLink(store, checkpoint(GENESIS.root, 0), checkpoint(EPOCH_1_ROOT.root, 1), SUPERMAJORITY)
    store.processEpochTransition(2)

    castLink(
      store,
      checkpoint(EPOCH_1_ROOT.root, 1),
      checkpoint(EPOCH_2_ROOT.root, 2),
      SUPERMAJORITY,
    )
    store.processEpochTransition(3)

    expect(store.justified).toEqual(checkpoint(EPOCH_2_ROOT.root, 2))
    expect(store.finalized).toEqual(checkpoint(EPOCH_1_ROOT.root, 1))
  })

  it('should not justify a target whose source was never justified', () => {
    const store = freshStore()
    castLink(
      store,
      checkpoint('deadbeefdeadbeef', 1),
      checkpoint(EPOCH_2_ROOT.root, 2),
      SUPERMAJORITY,
    )
    store.processEpochTransition(3)

    expect(store.justified.epoch).toBe(0)
  })

  it('should count a validator only once per link however often it repeats', () => {
    const store = freshStore()
    const source = checkpoint(GENESIS.root, 0)
    const target = checkpoint(EPOCH_1_ROOT.root, 1)
    for (let i = 0; i < 50; i++) store.addAttestation(ffgVote(0, source, target))
    store.processEpochTransition(2)

    expect(store.justified.epoch).toBe(0)
  })
})
