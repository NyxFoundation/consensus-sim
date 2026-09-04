// Validator set (バリデータ) — the simulator's constraints on the participants:
// the count is configurable between 4 and 10, defaulting to 4, and each
// validator carries a katakana display name (ESSENCE.md). The identity of a
// validator (its index) belongs to the model.

import type { ValidatorIndex } from "../model/types";

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

/**
 * Katakana display names (カタカナ人名), one per validator index. The
 * standard cryptography cast keeps them recognizable (ESSENCE.md), and every
 * name starts with a distinct kana so the initial alone still identifies a
 * validator where space is tight.
 */
export const VALIDATOR_NAMES: readonly string[] = [
  "アリス",
  "ボブ",
  "キャロル",
  "デイブ",
  "イヴ",
  "フランク",
  "グレース",
  "ハイジ",
  "オスカー",
  "ペギー",
];

export function validatorName(validator: ValidatorIndex): string {
  return VALIDATOR_NAMES[validator] ?? `V${validator}`;
}

/** First kana of the name — the compact identity used on tree chips. */
export function validatorInitial(validator: ValidatorIndex): string {
  return validatorName(validator).slice(0, 1);
}
