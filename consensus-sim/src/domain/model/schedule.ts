// Schedule (予定表) — who proposes and who attests in a slot, derived from
// the initial conditions. Public information: every validator, attackers
// included, computes the same schedule from the same inputs.
//
// The essential specification fixes the proposer rule (round robin — a rule
// of the skeleton, not a parameter) and, per committee assignment, the
// structure of the committees; the concrete seeded permutation they are
// drawn with is the simulator's business (sim/schedule.ts), so the model
// only requires a `Permutation`.

import { SLOTS_PER_EPOCH, epochOf, slotsSinceEpochStart } from "./finality";
import { validatorIndices, type InitialConditions } from "./initialConditions";
import type { SlotIndex, ValidatorIndex } from "./types";

/** Reference type from ESSENCE.md: Schedule = {proposerOf, committeeOf}. */
export interface Schedule {
  proposerOf(slot: SlotIndex): ValidatorIndex;
  committeeOf(slot: SlotIndex): ReadonlySet<ValidatorIndex>;
}

/** A deterministic reordering of the validators keyed by (seed, key): the
 * same inputs always yield the same permutation. */
export type Permutation = (
  validators: readonly ValidatorIndex[],
  seed: number,
  key: number,
) => readonly ValidatorIndex[];

/** Round-robin proposer schedule: slot s is proposed by validator s mod n. */
export function proposerForSlot(
  slot: SlotIndex,
  config: InitialConditions,
): ValidatorIndex {
  const n = config.validatorCount;
  return ((slot % n) + n) % n;
}

/**
 * The committee of `slot`, in ascending index order:
 * - `all`: everyone;
 * - `sized`: `size` distinct validators — the first `size` of the
 *   permutation keyed by the slot;
 * - `epoch-split`: the permutation keyed by the epoch is dealt round-robin
 *   over the epoch's slots, so every validator attests in exactly one slot
 *   per epoch and the slot committees differ in size by at most one.
 */
export function committeeForSlot(
  slot: SlotIndex,
  config: InitialConditions,
  permute: Permutation,
): ReadonlySet<ValidatorIndex> {
  const all = validatorIndices(config.validatorCount);
  const { committee } = config.params;
  if (committee.kind === "all") return new Set(all);
  if (committee.kind === "epoch-split") {
    const order = permute(all, config.seed, epochOf(slot));
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
  const drawn = permute(all, config.seed, slot).slice(0, size);
  return new Set([...drawn].sort((a, b) => a - b));
}

/** The schedule the initial conditions determine, given the permutation. */
export function deriveSchedule(
  config: InitialConditions,
  permute: Permutation,
): Schedule {
  return {
    proposerOf: (slot) => proposerForSlot(slot, config),
    committeeOf: (slot) => committeeForSlot(slot, config, permute),
  };
}
