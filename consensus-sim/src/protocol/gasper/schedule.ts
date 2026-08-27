/**
 * Duty assignment: who proposes, and who attests, in each slot.
 *
 * This is shared, read-only state. Every node must derive the same committees
 * from the same seed — a node that disagreed about who is in a committee would
 * be simulating a different protocol, not a different view. RANDAO is out of
 * scope (it changes who is selected, never how the fork choice weighs them), so
 * selection comes straight from the run seed.
 */

import type { Rng } from '../../core/rng'
import type { Epoch, Slot, ValidatorIndex } from '../../core/types'
import { epochOf } from './types'
import type { GasperConfig } from './types'

interface EpochDuties {
  /** One committee per slot of the epoch. */
  readonly committees: readonly (readonly ValidatorIndex[])[]
  readonly membership: readonly ReadonlySet<ValidatorIndex>[]
}

export class GasperSchedule {
  private readonly duties = new Map<Epoch, EpochDuties>()
  private readonly proposers = new Map<Slot, ValidatorIndex>()

  constructor(
    private readonly config: GasperConfig,
    private readonly rng: Rng,
  ) {}

  /** The committee attesting in `slot`. */
  committeeAt(slot: Slot): readonly ValidatorIndex[] {
    const { committees } = this.dutiesFor(epochOf(slot, this.config.slotsPerEpoch))
    return committees[slot % this.config.slotsPerEpoch] ?? []
  }

  isAttester(slot: Slot, validator: ValidatorIndex): boolean {
    const { membership } = this.dutiesFor(epochOf(slot, this.config.slotsPerEpoch))
    return membership[slot % this.config.slotsPerEpoch]?.has(validator) ?? false
  }

  proposerAt(slot: Slot): ValidatorIndex {
    const cached = this.proposers.get(slot)
    if (cached !== undefined) return cached

    const picked = this.rng.fork(`proposer:${slot}`).int(this.config.validatorCount)
    this.proposers.set(slot, picked)
    return picked
  }

  private dutiesFor(epoch: Epoch): EpochDuties {
    const cached = this.duties.get(epoch)
    if (cached !== undefined) return cached

    const computed = this.computeDuties(epoch)
    this.duties.set(epoch, computed)
    return computed
  }

  private computeDuties(epoch: Epoch): EpochDuties {
    const { validatorCount, slotsPerEpoch } = this.config
    const indices = Array.from({ length: validatorCount }, (_, i) => i)
    const shuffled = this.rng.fork(`committee:${epoch}`).shuffle(indices)

    const committees: ValidatorIndex[][] = Array.from({ length: slotsPerEpoch }, () => [])
    // Round-robin rather than contiguous chunks: with N < slotsPerEpoch this
    // still spreads validators across slots instead of leaving most empty.
    shuffled.forEach((validator, position) => {
      const committee = committees[position % slotsPerEpoch]
      if (committee !== undefined) committee.push(validator)
    })

    return {
      committees,
      membership: committees.map((committee) => new Set(committee)),
    }
  }
}
