/**
 * Deterministic pseudo-random number generation.
 *
 * Every stochastic decision in the simulator (committee shuffling, network
 * jitter, proposer selection) draws from one of these streams. Given the same
 * seed, a run is bit-for-bit reproducible — which is what makes a recorded
 * scenario replayable and a reported result checkable.
 */

export interface Rng {
  /** Uniform in [0, 1). */
  next(): number
  /** Uniform integer in [0, maxExclusive). Returns 0 when maxExclusive <= 0. */
  int(maxExclusive: number): number
  /** Uniform in [min, max). */
  range(min: number, max: number): number
  /** Standard normal, via Box-Muller. */
  normal(): number
  /** Fisher-Yates copy. The input is left untouched. */
  shuffle<T>(items: readonly T[]): T[]
  /**
   * Derives an independent stream. Subsystems that draw from a forked stream
   * cannot perturb each other's sequence, so adding a draw in one place does
   * not silently change unrelated results.
   */
  fork(label: string): Rng
}

/** mulberry32 — small, fast, and good enough for simulation purposes. */
function mulberry32(seed: number): () => number {
  let a = seed >>> 0
  return () => {
    a = (a + 0x6d2b79f5) >>> 0
    let t = a
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

function mixLabel(seed: number, label: string): number {
  let h = seed >>> 0
  for (let i = 0; i < label.length; i++) {
    h = Math.imul(h ^ label.charCodeAt(i), 0x01000193) >>> 0
  }
  return h >>> 0
}

export function makeRng(seed: number): Rng {
  const next = mulberry32(seed)

  const rng: Rng = {
    next,
    int: (maxExclusive) => (maxExclusive <= 0 ? 0 : Math.floor(next() * maxExclusive)),
    range: (min, max) => min + next() * (max - min),
    normal: () => {
      // Guard against log(0); next() can legitimately return exactly 0.
      const u = 1 - next()
      const v = next()
      return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v)
    },
    shuffle: <T,>(items: readonly T[]): T[] => {
      const out = [...items]
      for (let i = out.length - 1; i > 0; i--) {
        const j = Math.floor(next() * (i + 1))
        const a = out[i] as T
        const b = out[j] as T
        out[i] = b
        out[j] = a
      }
      return out
    },
    fork: (label) => makeRng(mixLabel(seed, label)),
  }

  return rng
}
