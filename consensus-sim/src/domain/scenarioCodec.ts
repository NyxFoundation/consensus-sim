// Scenario (de)serialization — the persistable form of a run's identity.
// A serialized scenario carries a format tag and version so future additive
// fields stay loadable; parsing validates everything (tagged union kinds,
// integer fields, validator ranges) and throws on anything unknown, so a
// loaded scenario is exactly as trustworthy as a built one. Pure data in,
// pure data out: no DOM, no storage — I/O belongs to the UI layer.

import type { Intervention } from "./intervention";
import type { MessageRef } from "./messages";
import type { Scenario } from "./scenario";
import { START_SLOT } from "./types";
import {
  MAX_VALIDATOR_COUNT,
  MIN_VALIDATOR_COUNT,
} from "./validatorSet";

export const SCENARIO_FORMAT = "consensus-sim.scenario";
export const SCENARIO_VERSION = 1;

/** A saved run: the scenario plus how far it had advanced. */
export interface SavedRun {
  readonly scenario: Scenario;
  readonly runSlot: number;
}

export interface SerializedScenario {
  readonly format: typeof SCENARIO_FORMAT;
  readonly version: number;
  readonly config: { readonly validatorCount: number; readonly seed: number };
  readonly runSlot: number;
  readonly interventions: readonly Intervention[];
}

export function serializeScenario(
  scenario: Scenario,
  runSlot: number,
): SerializedScenario {
  return {
    format: SCENARIO_FORMAT,
    version: SCENARIO_VERSION,
    config: scenario.config,
    runSlot,
    interventions: scenario.interventions,
  };
}

class ParseError extends Error {}

const isRecord = (x: unknown): x is Record<string, unknown> =>
  typeof x === "object" && x !== null && !Array.isArray(x);

function integer(x: unknown, what: string): number {
  if (typeof x !== "number" || !Number.isInteger(x)) {
    throw new ParseError(`${what} must be an integer`);
  }
  return x;
}

function slotOf(x: unknown, what: string): number {
  const n = integer(x, what);
  if (n < START_SLOT) throw new ParseError(`${what} must be ≥ ${START_SLOT}`);
  return n;
}

function validatorOf(
  x: unknown,
  validatorCount: number,
  what: string,
): number {
  const n = integer(x, what);
  if (n < 0 || n >= validatorCount) {
    throw new ParseError(`${what} must be in [0, ${validatorCount - 1}]`);
  }
  return n;
}

function validatorsOf(
  x: unknown,
  validatorCount: number,
  what: string,
): number[] {
  if (!Array.isArray(x) || x.length === 0) {
    throw new ParseError(`${what} must be a non-empty array`);
  }
  return x.map((v, i) => validatorOf(v, validatorCount, `${what}[${i}]`));
}

function spanOf(
  raw: Record<string, unknown>,
  what: string,
): { fromSlot: number; toSlot?: number } {
  const fromSlot = slotOf(raw.fromSlot, `${what}.fromSlot`);
  if (raw.toSlot === undefined) return { fromSlot };
  const toSlot = slotOf(raw.toSlot, `${what}.toSlot`);
  if (toSlot < fromSlot) {
    throw new ParseError(`${what}.toSlot must be ≥ fromSlot`);
  }
  return { fromSlot, toSlot };
}

function messageRefOf(
  x: unknown,
  validatorCount: number,
  what: string,
): MessageRef {
  if (!isRecord(x)) throw new ParseError(`${what} must be an object`);
  if (x.kind === "block") {
    const block = integer(x.block, `${what}.block`);
    if (block <= 0) throw new ParseError(`${what}.block must be positive`);
    return { kind: "block", block };
  }
  if (x.kind === "vote") {
    return {
      kind: "vote",
      validator: validatorOf(x.validator, validatorCount, `${what}.validator`),
      slot: slotOf(x.slot, `${what}.slot`),
      head: integer(x.head, `${what}.head`),
    };
  }
  throw new ParseError(`${what}.kind must be "block" or "vote"`);
}

function observersOf(
  raw: Record<string, unknown>,
  validatorCount: number,
  what: string,
): { observers?: readonly number[] } {
  if (raw.observers === undefined) return {};
  return {
    observers: validatorsOf(raw.observers, validatorCount, `${what}.observers`),
  };
}

function interventionOf(
  x: unknown,
  validatorCount: number,
  what: string,
): Intervention {
  if (!isRecord(x)) throw new ParseError(`${what} must be an object`);
  switch (x.kind) {
    case "partition": {
      if (!Array.isArray(x.groups) || x.groups.length === 0) {
        throw new ParseError(`${what}.groups must be a non-empty array`);
      }
      const groups = x.groups.map((g, i) =>
        validatorsOf(g, validatorCount, `${what}.groups[${i}]`),
      );
      const seen = new Set<number>();
      for (const g of groups) {
        for (const v of g) {
          if (seen.has(v)) {
            throw new ParseError(`${what}.groups list V${v} twice`);
          }
          seen.add(v);
        }
      }
      return { kind: "partition", ...spanOf(x, what), groups };
    }
    case "stop":
    case "offline":
      return {
        kind: x.kind,
        ...spanOf(x, what),
        validators: validatorsOf(x.validators, validatorCount, `${what}.validators`),
      };
    case "double-propose":
    case "double-vote":
      return {
        kind: x.kind,
        slot: slotOf(x.slot, `${what}.slot`),
        validator: validatorOf(x.validator, validatorCount, `${what}.validator`),
      };
    case "delay":
      return {
        kind: "delay",
        message: messageRefOf(x.message, validatorCount, `${what}.message`),
        untilSlot: slotOf(x.untilSlot, `${what}.untilSlot`),
        ...observersOf(x, validatorCount, what),
      };
    case "drop":
      return {
        kind: "drop",
        message: messageRefOf(x.message, validatorCount, `${what}.message`),
        ...observersOf(x, validatorCount, what),
      };
    case "propose-parent": {
      const parent = integer(x.parent, `${what}.parent`);
      if (parent < 0) throw new ParseError(`${what}.parent must be ≥ 0`);
      return { kind: "propose-parent", slot: slotOf(x.slot, `${what}.slot`), parent };
    }
    default:
      throw new ParseError(`${what}.kind is unknown: ${String(x.kind)}`);
  }
}

/**
 * Parse and validate a serialized scenario (an already-JSON.parsed value).
 * Throws an Error with a specific message on any structural violation.
 */
export function parseScenario(data: unknown): SavedRun {
  if (!isRecord(data)) throw new ParseError("scenario must be an object");
  if (data.format !== SCENARIO_FORMAT) {
    throw new ParseError(`format must be "${SCENARIO_FORMAT}"`);
  }
  if (data.version !== SCENARIO_VERSION) {
    throw new ParseError(`unsupported version: ${String(data.version)}`);
  }
  if (!isRecord(data.config)) throw new ParseError("config must be an object");
  const validatorCount = integer(
    data.config.validatorCount,
    "config.validatorCount",
  );
  if (
    validatorCount < MIN_VALIDATOR_COUNT ||
    validatorCount > MAX_VALIDATOR_COUNT
  ) {
    throw new ParseError(
      `config.validatorCount must be in [${MIN_VALIDATOR_COUNT}, ${MAX_VALIDATOR_COUNT}]`,
    );
  }
  const seed = integer(data.config.seed, "config.seed");
  const runSlot = slotOf(data.runSlot, "runSlot");
  if (!Array.isArray(data.interventions)) {
    throw new ParseError("interventions must be an array");
  }
  const interventions = data.interventions.map((x, i) =>
    interventionOf(x, validatorCount, `interventions[${i}]`),
  );
  return {
    scenario: { config: { validatorCount, seed }, interventions },
    runSlot,
  };
}
