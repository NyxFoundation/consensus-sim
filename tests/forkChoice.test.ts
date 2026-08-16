import { describe, expect, it } from 'vitest'
import { GasperStore } from '../src/protocol/gasper/store'
import { computeForkChoice } from '../src/protocol/gasper/forkChoice'
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

const GENESIS = genesisBlock()
// Roots are chosen so that BRANCH_B sorts above BRANCH_A, making the spec's
// lexicographic tie-break observable.
const BRANCH_A: Block = { root: 'aaaa000000000001', slot: 1, parent: GENESIS.root, proposer: 0 }
const BRANCH_B: Block = { root: 'bbbb000000000002', slot: 1, parent: GENESIS.root, proposer: 1 }

function genesisCheckpoint(): Checkpoint {
  return { root: GENESIS.root, epoch: 0 }
}

/** A head vote with an FFG link the store ignores (target epoch <= source). */
function headVote(validator: number, slot: number, head: string): Attestation {
  return {
    validator,
    slot,
    head,
    source: genesisCheckpoint(),
    target: genesisCheckpoint(),
  }
}

function storeWithBranches(): GasperStore {
  const store = new GasperStore(CONFIG, GENESIS)
  store.addBlock(BRANCH_A)
  store.addBlock(BRANCH_B)
  return store
}

describe('LMD-GHOST fork choice', () => {
  it('should select the heavier subtree when branches have unequal votes', () => {
    const store = storeWithBranches()
    store.addAttestation(headVote(0, 1, BRANCH_A.root))
    store.addAttestation(headVote(1, 1, BRANCH_B.root))
    store.addAttestation(headVote(2, 1, BRANCH_B.root))

    expect(computeForkChoice(store).head).toBe(BRANCH_B.root)
  })

  it('should count only each validator latest vote', () => {
    const store = storeWithBranches()
    store.addAttestation(headVote(0, 1, BRANCH_A.root))
    store.addAttestation(headVote(0, 2, BRANCH_B.root))

    const { head, weights } = computeForkChoice(store)
    expect(weights.get(BRANCH_A.root) ?? 0).toBe(0)
    expect(head).toBe(BRANCH_B.root)
  })

  it('should ignore a vote older than the one already recorded', () => {
    const store = storeWithBranches()
    store.addAttestation(headVote(0, 5, BRANCH_B.root))
    store.addAttestation(headVote(0, 2, BRANCH_A.root))

    expect(computeForkChoice(store).weights.get(BRANCH_A.root) ?? 0).toBe(0)
  })

  it('should accumulate descendant weight into ancestors', () => {
    const store = storeWithBranches()
    const child: Block = {
      root: 'cccc000000000003',
      slot: 2,
      parent: BRANCH_A.root,
      proposer: 2,
    }
    store.addBlock(child)
    store.addAttestation(headVote(0, 2, child.root))

    const { weights } = computeForkChoice(store)
    expect(weights.get(BRANCH_A.root)).toBe(CONFIG.effectiveBalanceGwei)
    expect(weights.get(GENESIS.root)).toBe(CONFIG.effectiveBalanceGwei)
  })

  it('should flip the head toward the boosted branch when proposer boost applies', () => {
    const store = storeWithBranches()
    store.addAttestation(headVote(0, 1, BRANCH_A.root))
    store.addAttestation(headVote(1, 1, BRANCH_B.root))
    store.addAttestation(headVote(2, 1, BRANCH_B.root))
    expect(computeForkChoice(store).head).toBe(BRANCH_B.root)

    // Boost is 40% of one committee's weight: 16 * 32 ETH / 4 slots * 0.4,
    // which outweighs the single-vote deficit on branch A.
    store.setProposerBoost(BRANCH_A.root)
    expect(computeForkChoice(store).head).toBe(BRANCH_A.root)
  })

  it('should return to the heavier branch once the boost is cleared', () => {
    const store = storeWithBranches()
    store.addAttestation(headVote(0, 1, BRANCH_A.root))
    store.addAttestation(headVote(1, 1, BRANCH_B.root))
    store.addAttestation(headVote(2, 1, BRANCH_B.root))

    store.setProposerBoost(BRANCH_A.root)
    store.clearProposerBoost()

    expect(computeForkChoice(store).head).toBe(BRANCH_B.root)
  })

  it('should break an exact tie toward the larger root', () => {
    const store = storeWithBranches()
    store.addAttestation(headVote(0, 1, BRANCH_A.root))
    store.addAttestation(headVote(1, 1, BRANCH_B.root))

    expect(computeForkChoice(store).head).toBe(BRANCH_B.root)
  })
})
