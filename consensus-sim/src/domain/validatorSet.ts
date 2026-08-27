// Validator set (バリデータ) — participants of the simulation.
// The count is configurable between 4 and 10, defaulting to 4 (ESSENCE.md).

import type { ValidatorIndex } from "./types";

export const MIN_VALIDATOR_COUNT = 4;
export const MAX_VALIDATOR_COUNT = 10;
export const DEFAULT_VALIDATOR_COUNT = 4;

export function isValidValidatorCount(count: number): boolean {
  return (
    Number.isInteger(count) &&
    count >= MIN_VALIDATOR_COUNT &&
    count <= MAX_VALIDATOR_COUNT
  );
}

/** Throws unless `count` is an integer within [4, 10]. */
export function assertValidatorCount(count: number): void {
  if (!isValidValidatorCount(count)) {
    throw new Error(
      `validator count must be an integer in [${MIN_VALIDATOR_COUNT}, ` +
        `${MAX_VALIDATOR_COUNT}], got ${count}`,
    );
  }
}

/** Indices 0..count-1, the identity of every validator in the run. */
export function validatorIndices(count: number): ValidatorIndex[] {
  assertValidatorCount(count);
  return Array.from({ length: count }, (_, i) => i);
}
