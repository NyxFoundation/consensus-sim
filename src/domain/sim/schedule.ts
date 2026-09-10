// The simulator's schedule (予定表の具体的導出) — the seeded permutation the
// model's committee structure is drawn with. A simulation constraint: the
// essential specification only requires a deterministic permutation, this
// module picks one (a 32-bit hash of (seed, key) driving mulberry32 through
// a Fisher–Yates shuffle).

import type { InitialConditions } from "../model/initialConditions";
import { deriveSchedule, type Permutation, type Schedule } from "../model/schedule";
import type { ValidatorIndex } from "../model/types";

/** 32-bit integer hash of two integers (deterministic, order-sensitive). */
function hash32(a: number, b: number): number {
  let h = (a ^ 0x9e3779b9) >>> 0;
  h = Math.imul(h ^ (h >>> 16), 0x85ebca6b) >>> 0;
  h = (h ^ b) >>> 0;
  h = Math.imul(h ^ (h >>> 13), 0xc2b2ae35) >>> 0;
  return (h ^ (h >>> 16)) >>> 0;
}

/** mulberry32: a small deterministic generator over [0, 1). */
function generator(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** Fisher–Yates shuffle of `validators` seeded from (seed, key). */
export const seededPermutation: Permutation = (
  validators: readonly ValidatorIndex[],
  seed: number,
  key: number,
) => {
  const next = generator(hash32(seed | 0, key | 0));
  const pool = [...validators];
  for (let i = 0; i < pool.length - 1; i++) {
    const j = i + Math.floor(next() * (pool.length - i));
    [pool[i], pool[j]] = [pool[j]!, pool[i]!];
  }
  return pool;
};

/** The schedule of a run. */
export function scheduleOf(config: InitialConditions): Schedule {
  return deriveSchedule(config, seededPermutation);
}
