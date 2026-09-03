// Schedule (プロポーザー予定表・committee) — who proposes and who attests in
// a slot, derived deterministically from (slot, ProtocolParams, seed). Both
// are public information: every validator, attackers included, computes the
// same schedule from the same inputs.

import { validatorIndices, type SimulationConfig } from "./config";
import { SLOTS_PER_EPOCH, epochOf, slotsSinceEpochStart } from "./finality";
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

/** Fisher–Yates shuffle of `items` driven by `seed`. */
function shuffled(items: readonly ValidatorIndex[], seed: number): ValidatorIndex[] {
  const next = generator(seed);
  const pool = [...items];
  for (let i = 0; i < pool.length - 1; i++) {
    const j = i + Math.floor(next() * (pool.length - i));
    [pool[i], pool[j]] = [pool[j]!, pool[i]!];
  }
  return pool;
}

/**
 * The committee of `slot`, in ascending index order:
 * - `all`: everyone;
 * - `sized`: `size` distinct validators drawn by a shuffle seeded from
 *   (seed, slot);
 * - `epoch-split`: the validators are shuffled once per epoch, seeded from
 *   (seed, epoch), and dealt round-robin over the epoch's slots, so every
 *   validator attests in exactly one slot per epoch and the slot committees
 *   differ in size by at most one.
 */
export function committeeForSlot(
  slot: SlotIndex,
  config: SimulationConfig,
): ReadonlySet<ValidatorIndex> {
  const all = validatorIndices(config.validatorCount);
  const { committee } = config.params;
  if (committee.kind === "all") return new Set(all);
  if (committee.kind === "epoch-split") {
    const order = shuffled(all, hash32(config.seed | 0, epochOf(slot) | 0));
    const offset = slotsSinceEpochStart(slot);
    return new Set(
      order.filter((_, position) => position % SLOTS_PER_EPOCH === offset).sort((a, b) => a - b),
    );
  }
  const size = committee.size;
  if (!Number.isInteger(size) || size < 1 || size > all.length) {
    throw new Error(
      `committee size must be an integer in [1, ${all.length}], got ${size}`,
    );
  }
  const drawn = shuffled(all, hash32(config.seed | 0, slot | 0)).slice(0, size);
  return new Set(drawn.sort((a, b) => a - b));
}

/** Whether `validator` attests in `slot`. */
export function inCommittee(
  validator: ValidatorIndex,
  slot: SlotIndex,
  config: SimulationConfig,
): boolean {
  return committeeForSlot(slot, config).has(validator);
}
