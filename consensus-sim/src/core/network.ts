/**
 * The network layer of the discrete-event engine.
 *
 * Two knobs, kept separate on purpose:
 *
 *  - the *delay distribution*, which models ordinary latency, and
 *  - the *delivery schedule*, which models an adversary that controls when
 *    messages arrive (partitions today; targeted delivery from M2).
 *
 * A partition here defers cross-group messages until the partition heals; it
 * does not drop them. That matches the model the papers reason in — asynchrony
 * is unbounded delay under adversarial control, not loss — and it is what makes
 * "the pre-partition votes are still in everyone's hands" fall out naturally
 * rather than having to be special-cased.
 */

import type { NodeId, Time } from './types'
import type { Rng } from './rng'

export type DelayDistribution = 'uniform' | 'normal' | 'pareto'

/** Nodes are split into `groupCount` contiguous groups for the window's duration. */
export interface PartitionWindow {
  readonly startMs: Time
  readonly endMs: Time
  readonly groupCount: number
}

export interface NetworkConfig {
  /** Median one-hop delay. */
  readonly baseDelayMs: number
  /** Spread of the distribution around the base delay. */
  readonly jitterMs: number
  readonly distribution: DelayDistribution
  readonly partitions: readonly PartitionWindow[]
}

export const DEFAULT_NETWORK: NetworkConfig = {
  baseDelayMs: 120,
  jitterMs: 60,
  distribution: 'normal',
  partitions: [],
}

const PARETO_ALPHA = 1.5
const MIN_DELAY_MS = 1

export class Network {
  constructor(
    private readonly config: NetworkConfig,
    private readonly nodeCount: number,
    private readonly rng: Rng,
  ) {}

  /**
   * Absolute time at which a message broadcast by `from` at `at` reaches `to`.
   * Never returns a time earlier than `at`.
   */
  arrivalTime(from: NodeId, to: NodeId, at: Time): Time {
    const releaseAt = this.releaseTime(from, to, at)
    return releaseAt + this.sampleDelay()
  }

  /** The partition window covering `at`, if any. */
  activePartition(at: Time): PartitionWindow | null {
    for (const window of this.config.partitions) {
      if (at >= window.startMs && at < window.endMs) return window
    }
    return null
  }

  /** Which partition group a node falls into at `at`; 0 when not partitioned. */
  groupOf(node: NodeId, at: Time): number {
    const window = this.activePartition(at)
    if (window === null || window.groupCount < 2) return 0
    return this.groupIndex(node, window.groupCount)
  }

  /**
   * When the message becomes eligible for transmission. Inside a partition,
   * cross-group traffic waits for the window to close.
   */
  private releaseTime(from: NodeId, to: NodeId, at: Time): Time {
    const window = this.activePartition(at)
    if (window === null || window.groupCount < 2) return at

    const sameGroup =
      this.groupIndex(from, window.groupCount) === this.groupIndex(to, window.groupCount)
    return sameGroup ? at : window.endMs
  }

  private groupIndex(node: NodeId, groupCount: number): number {
    const perGroup = Math.ceil(this.nodeCount / groupCount)
    return Math.min(Math.floor(node / perGroup), groupCount - 1)
  }

  private sampleDelay(): Time {
    const { baseDelayMs, jitterMs, distribution } = this.config
    const raw = this.sampleRaw(baseDelayMs, jitterMs, distribution)
    return Math.max(MIN_DELAY_MS, Math.round(raw))
  }

  private sampleRaw(base: number, jitter: number, distribution: DelayDistribution): number {
    switch (distribution) {
      case 'uniform':
        return this.rng.range(base - jitter, base + jitter)
      case 'normal':
        return base + this.rng.normal() * jitter
      case 'pareto': {
        // Heavy tail: most messages near `base`, a few dramatically late.
        const u = 1 - this.rng.next()
        return base + jitter * (Math.pow(u, -1 / PARETO_ALPHA) - 1)
      }
    }
  }
}
