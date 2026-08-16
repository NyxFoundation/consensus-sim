/**
 * One node's local view: the blocks it has seen, the latest head vote of every
 * validator it has heard from, and the FFG bookkeeping that follows.
 *
 * There is one of these per node and no shared copy. That is the whole point of
 * simulating individuals — under delay or partition these stores legitimately
 * disagree, and the disagreement is the phenomenon under study.
 *
 * Justification is *applied* at epoch boundaries, not the instant a
 * supermajority link appears. Real validators read the justified checkpoint out
 * of a state that only changes at epoch processing, so applying it immediately
 * would let attesters within one epoch vote with different sources and quietly
 * break the source/target invariants.
 */

import type { Hash } from '../../core/hash'
import { ZERO_HASH } from '../../core/hash'
import type { Checkpoint, Epoch, Gwei, Slot, ValidatorIndex } from '../../core/types'
import { checkpointKey } from '../../core/types'
import type { Attestation, Block, GasperConfig } from './types'
import { proposerBoostWeight, totalActiveBalance } from './types'

interface LatestMessage {
  readonly root: Hash
  readonly slot: Slot
}

interface FfgLink {
  readonly source: Checkpoint
  readonly target: Checkpoint
}

export class GasperStore {
  readonly blocks = new Map<Hash, Block>()
  private readonly children = new Map<Hash, Hash[]>()
  private readonly latestMessages = new Map<ValidatorIndex, LatestMessage>()

  /** validator sets per "source -> target" link, for quorum counting. */
  private readonly ffgVotes = new Map<string, Set<ValidatorIndex>>()
  /** Links that reached a supermajority but have not been applied yet. */
  private readonly pendingLinks = new Map<string, FfgLink>()
  private readonly justifiedKeys = new Set<string>()

  justified: Checkpoint
  finalized: Checkpoint
  proposerBoostRoot: Hash | null = null
  attestationCount = 0

  /**
   * Bumped by every mutation. The fork choice memoises against it, so a node
   * that receives a hundred attestations between two head lookups recomputes
   * once rather than a hundred times.
   */
  private revision = 0

  get version(): number {
    return this.revision
  }

  constructor(
    private readonly config: GasperConfig,
    readonly genesis: Block,
  ) {
    this.blocks.set(genesis.root, genesis)
    const genesisCheckpoint: Checkpoint = { root: genesis.root, epoch: 0 }
    this.justified = genesisCheckpoint
    this.finalized = genesisCheckpoint
    this.justifiedKeys.add(checkpointKey(genesisCheckpoint))
  }

  hasBlock(root: Hash): boolean {
    return this.blocks.has(root)
  }

  addBlock(block: Block): boolean {
    if (this.blocks.has(block.root)) return false
    this.blocks.set(block.root, block)

    const siblings = this.children.get(block.parent)
    if (siblings === undefined) this.children.set(block.parent, [block.root])
    else siblings.push(block.root)

    this.revision += 1
    return true
  }

  addAttestation(attestation: Attestation): void {
    this.attestationCount += 1
    this.recordLatestMessage(attestation)
    this.recordFfgVote(attestation)
    this.revision += 1
  }

  /** Applies any supermajority links whose target epoch is already past. */
  processEpochTransition(currentEpoch: Epoch): void {
    const ready = [...this.pendingLinks.values()]
      .filter((link) => link.target.epoch < currentEpoch)
      .sort((a, b) => a.target.epoch - b.target.epoch)

    for (const link of ready) {
      this.applyLink(link)
    }
  }

  /**
   * Proposer boost: a block that arrives on time for its own slot is credited
   * with a slice of committee weight until the slot ends. This is what stops an
   * adversary from reorging an honest proposal that simply has not collected
   * its votes yet.
   */
  setProposerBoost(root: Hash): void {
    if (this.proposerBoostRoot === root) return
    this.proposerBoostRoot = root
    this.revision += 1
  }

  clearProposerBoost(): void {
    if (this.proposerBoostRoot === null) return
    this.proposerBoostRoot = null
    this.revision += 1
  }

  /** Walks back from `root` to the newest ancestor at or before `slot`. */
  ancestorAtOrBefore(root: Hash, slot: Slot): Hash {
    let current = root
    for (;;) {
      const block = this.blocks.get(current)
      if (block === undefined || block.slot <= slot) return current
      if (block.parent === ZERO_HASH) return current
      current = block.parent
    }
  }

  childrenOf(root: Hash): readonly Hash[] {
    return this.children.get(root) ?? []
  }

  /**
   * Subtree weight for every known block, in one pass.
   *
   * Own weight comes from each validator's single latest head vote; the pass
   * over blocks in descending slot order folds each block's total into its
   * parent, so a block's value ends up being the stake voting anywhere in its
   * subtree. O(V + B log B), against O(V x depth) for the naive per-block walk.
   */
  computeWeights(): Map<Hash, Gwei> {
    const weights = new Map<Hash, Gwei>()
    const balance = this.config.effectiveBalanceGwei

    for (const message of this.latestMessages.values()) {
      if (!this.blocks.has(message.root)) continue
      weights.set(message.root, (weights.get(message.root) ?? 0) + balance)
    }

    const boostRoot = this.proposerBoostRoot
    if (boostRoot !== null && this.blocks.has(boostRoot)) {
      weights.set(boostRoot, (weights.get(boostRoot) ?? 0) + proposerBoostWeight(this.config))
    }

    const bySlotDesc = [...this.blocks.values()].sort((a, b) => b.slot - a.slot)
    for (const block of bySlotDesc) {
      const weight = weights.get(block.root)
      if (weight === undefined || weight === 0) continue
      if (!this.blocks.has(block.parent)) continue
      weights.set(block.parent, (weights.get(block.parent) ?? 0) + weight)
    }

    return weights
  }

  private recordLatestMessage(attestation: Attestation): void {
    const previous = this.latestMessages.get(attestation.validator)
    if (previous !== undefined && previous.slot >= attestation.slot) return
    this.latestMessages.set(attestation.validator, {
      root: attestation.head,
      slot: attestation.slot,
    })
  }

  private recordFfgVote(attestation: Attestation): void {
    const { source, target } = attestation
    if (target.epoch <= source.epoch) return

    const key = `${checkpointKey(source)}->${checkpointKey(target)}`
    let voters = this.ffgVotes.get(key)
    if (voters === undefined) {
      voters = new Set()
      this.ffgVotes.set(key, voters)
    }
    if (voters.has(attestation.validator)) return
    voters.add(attestation.validator)

    const weight = voters.size * this.config.effectiveBalanceGwei
    if (weight * 3 >= totalActiveBalance(this.config) * 2) {
      this.pendingLinks.set(key, { source, target })
    }
  }

  private applyLink(link: FfgLink): void {
    const { source, target } = link
    if (!this.justifiedKeys.has(checkpointKey(source))) return

    this.justifiedKeys.add(checkpointKey(target))
    if (target.epoch > this.justified.epoch) this.justified = target

    // The k=1 rule: two consecutive justified epochs finalize the earlier one.
    if (source.epoch + 1 === target.epoch && source.epoch > this.finalized.epoch) {
      this.finalized = source
    }

    this.revision += 1
  }
}
