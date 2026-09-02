// Schedule (プロポーザー予定表・committee) — who proposes and who attests in
// a slot, derived deterministically from (slot, ProtocolParams, seed). Both
// are public information: every validator, attackers included, computes the
// same schedule from the same inputs.

import { validatorIndices, type SimulationConfig } from "./config";
import type { SlotIndex, ValidatorIndex } from "./types";

/** Round-robin proposer schedule: slot s is proposed by validator s mod n.
 * The seed does not enter (discretion: a readable default schedule). */
export function proposerForSlot(
  slot: SlotIndex,
  config: SimulationConfig,
): ValidatorIndex {
  const n = config.validatorCount;
  return ((slot % n) + n) % n;
}

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

/**
 * The committee of `slot`: everyone, or `size` distinct validators drawn by
 * a partial Fisher–Yates shuffle seeded from (seed, slot). Returned in
 * ascending index order.
 */
export function committeeForSlot(
  slot: SlotIndex,
  config: SimulationConfig,
): ReadonlySet<ValidatorIndex> {
  const all = validatorIndices(config.validatorCount);
  const { committee } = config.params;
  if (committee.kind === "all") return new Set(all);
  const size = committee.size;
  if (!Number.isInteger(size) || size < 1 || size > all.length) {
    throw new Error(
      `committee size must be an integer in [1, ${all.length}], got ${size}`,
    );
  }
  const next = generator(hash32(config.seed | 0, slot | 0));
  const pool = [...all];
  for (let i = 0; i < size; i++) {
    const j = i + Math.floor(next() * (pool.length - i));
    [pool[i], pool[j]] = [pool[j]!, pool[i]!];
  }
  return new Set(pool.slice(0, size).sort((a, b) => a - b));
}

/** Whether `validator` attests in `slot`. */
export function inCommittee(
  validator: ValidatorIndex,
  slot: SlotIndex,
  config: SimulationConfig,
): boolean {
  return committeeForSlot(slot, config).has(validator);
}
