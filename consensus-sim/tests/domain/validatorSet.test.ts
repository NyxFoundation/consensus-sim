import { describe, expect, it } from "vitest";
import {
  DEFAULT_VALIDATOR_COUNT,
  MAX_VALIDATOR_COUNT,
  MIN_VALIDATOR_COUNT,
  VALIDATOR_NAMES,
  assertValidatorCount,
  isValidValidatorCount,
  validatorIndices,
  validatorInitial,
  validatorName,
} from "../../src/domain";

describe("validator count bounds", () => {
  it("defaults to 4 within [4, 10]", () => {
    expect(DEFAULT_VALIDATOR_COUNT).toBe(4);
    expect(MIN_VALIDATOR_COUNT).toBe(4);
    expect(MAX_VALIDATOR_COUNT).toBe(10);
    expect(isValidValidatorCount(DEFAULT_VALIDATOR_COUNT)).toBe(true);
  });

  it("accepts every integer in [4, 10] and nothing else", () => {
    for (let n = MIN_VALIDATOR_COUNT; n <= MAX_VALIDATOR_COUNT; n++) {
      expect(isValidValidatorCount(n)).toBe(true);
    }
    expect(isValidValidatorCount(3)).toBe(false);
    expect(isValidValidatorCount(11)).toBe(false);
    expect(isValidValidatorCount(4.5)).toBe(false);
    expect(() => assertValidatorCount(3)).toThrow(/\[4, 10\]/);
  });

  it("enumerates validator indices deterministically", () => {
    expect(validatorIndices(4)).toEqual([0, 1, 2, 3]);
    expect(() => assertValidatorCount(2)).toThrow();
  });
});

describe("validator names (カタカナ人名)", () => {
  it("covers the maximum validator count with distinct names", () => {
    expect(VALIDATOR_NAMES).toHaveLength(MAX_VALIDATOR_COUNT);
    expect(new Set(VALIDATOR_NAMES).size).toBe(MAX_VALIDATOR_COUNT);
    expect(validatorName(0)).toBe("アリス");
    expect(validatorName(1)).toBe("ボブ");
  });

  it("keeps every initial distinct so the initial alone identifies a validator", () => {
    const initials = validatorIndices(MAX_VALIDATOR_COUNT).map(validatorInitial);
    expect(new Set(initials).size).toBe(MAX_VALIDATOR_COUNT);
  });
});
