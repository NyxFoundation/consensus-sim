// Scenario (de)serialization — the persistable form of a run's identity.
// A serialized scenario carries a format tag and version so future additive
// fields stay loadable; parsing validates everything (tagged union kinds,
// integer fields, validator ranges) and throws on anything unknown, so a
// loaded scenario is exactly as trustworthy as a built one. Pure data in,
// pure data out: no DOM, no storage — I/O belongs to the UI layer.

import { equalStakes, type SimulationConfig } from "../model/config";
import type { EvidenceRef } from "../model/inclusion";
import type { Intervention } from "./intervention";
import type { MessageRef } from "../model/messageRef";
import {
  DEFAULT_PARAMS,
  type CheckpointSwitch,
  type CommitteeAssignment,
  type ForkChoiceRule,
  type ProtocolParams,
} from "../model/protocolParams";
import type { Scenario } from "./scenario";
import { START_SLOT } from "../model/types";
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
  readonly config: SimulationConfig;
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

function booleanOf(x: unknown, what: string): boolean {
  if (typeof x !== "boolean") throw new ParseError(`${what} must be a boolean`);
  return x;
}

function fractionOf(x: unknown, what: string): number {
  if (typeof x !== "number" || !Number.isFinite(x) || x < 0 || x > 1) {
    throw new ParseError(`${what} must be a number in [0, 1]`);
  }
  return x;
}

function oneOf<T extends string>(
  x: unknown,
  options: readonly T[],
  what: string,
): T {
  if (typeof x !== "string" || !(options as readonly string[]).includes(x)) {
    throw new ParseError(`${what} must be one of ${options.join(" | ")}`);
  }
  return x as T;
}

function committeeOf(
  x: unknown,
  validatorCount: number,
  what: string,
): CommitteeAssignment {
  if (!isRecord(x)) throw new ParseError(`${what} must be an object`);
  if (x.kind === "all") return { kind: "all" };
  if (x.kind === "sized") {
    const size = integer(x.size, `${what}.size`);
    if (size < 1 || size > validatorCount) {
      throw new ParseError(`${what}.size must be in [1, ${validatorCount}]`);
    }
    return { kind: "sized", size };
  }
  throw new ParseError(`${what}.kind must be "all" or "sized"`);
}

const FORK_CHOICE_RULES: readonly ForkChoiceRule[] = ["GHOST", "LMD-GHOST"];
const CHECKPOINT_SWITCHES: readonly CheckpointSwitch[] = [
  "window",
  "unrealized",
  "off",
];

/** Validate protocol parameters; absent means the default preset (merge),
 * so scenarios saved before parameters existed stay loadable. */
function paramsOf(
  x: unknown,
  validatorCount: number,
  what: string,
): ProtocolParams {
  if (x === undefined) return DEFAULT_PARAMS;
  if (!isRecord(x)) throw new ParseError(`${what} must be an object`);
  const leak = x.inactivityLeak;
  if (!isRecord(leak)) {
    throw new ParseError(`${what}.inactivityLeak must be an object`);
  }
  const delayEpochs = integer(leak.delayEpochs, `${what}.inactivityLeak.delayEpochs`);
  if (delayEpochs < 1) {
    throw new ParseError(`${what}.inactivityLeak.delayEpochs must be ≥ 1`);
  }
  return {
    committee: committeeOf(x.committee, validatorCount, `${what}.committee`),
    boost: fractionOf(x.boost, `${what}.boost`),
    forkChoice: oneOf(x.forkChoice, FORK_CHOICE_RULES, `${what}.forkChoice`),
    equivocationDiscount: booleanOf(
      x.equivocationDiscount,
      `${what}.equivocationDiscount`,
    ),
    checkpointSwitch: oneOf(
      x.checkpointSwitch,
      CHECKPOINT_SWITCHES,
      `${what}.checkpointSwitch`,
    ),
    slashing: booleanOf(x.slashing, `${what}.slashing`),
    inactivityLeak: {
      enabled: booleanOf(leak.enabled, `${what}.inactivityLeak.enabled`),
      delayEpochs,
      rate: fractionOf(leak.rate, `${what}.inactivityLeak.rate`),
    },
  };
}

/** Validate initial stakes: one positive integer per validator; absent
 * means equal stakes, so scenarios saved before stakes existed stay
 * loadable. */
function initialStakesOf(
  x: unknown,
  validatorCount: number,
  what: string,
): readonly number[] {
  if (x === undefined) return equalStakes(validatorCount);
  if (!Array.isArray(x) || x.length !== validatorCount) {
    throw new ParseError(`${what} must list one stake per validator`);
  }
  return x.map((s, v) => {
    const stake = integer(s, `${what}[${v}]`);
    if (stake <= 0) throw new ParseError(`${what}[${v}] must be positive`);
    return stake;
  });
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

function listOf(x: unknown, what: string): unknown[] {
  if (!Array.isArray(x)) throw new ParseError(`${what} must be an array`);
  return x;
}

const EVIDENCE_KINDS: readonly EvidenceRef["kind"][] = [
  "double-proposal",
  "double-vote",
];

function evidenceRefOf(
  x: unknown,
  validatorCount: number,
  what: string,
): EvidenceRef {
  if (!isRecord(x)) throw new ParseError(`${what} must be an object`);
  return {
    kind: oneOf(x.kind, EVIDENCE_KINDS, `${what}.kind`),
    validator: validatorOf(x.validator, validatorCount, `${what}.validator`),
    slot: slotOf(x.slot, `${what}.slot`),
  };
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
    case "vote-target": {
      const block = (key: "head" | "source" | "target") => {
        if (x[key] === undefined) return {};
        const b = integer(x[key], `${what}.${key}`);
        if (b < 0) throw new ParseError(`${what}.${key} must be ≥ 0`);
        return { [key]: b };
      };
      return {
        kind: "vote-target",
        slot: slotOf(x.slot, `${what}.slot`),
        validator: validatorOf(x.validator, validatorCount, `${what}.validator`),
        ...block("head"),
        ...block("source"),
        ...block("target"),
      };
    }
    case "omit-inclusion": {
      const votes =
        x.votes === undefined
          ? {}
          : {
              votes: listOf(x.votes, `${what}.votes`).map((v, i) => {
                const ref = messageRefOf(v, validatorCount, `${what}.votes[${i}]`);
                if (ref.kind !== "vote") {
                  throw new ParseError(`${what}.votes[${i}] must be a vote`);
                }
                return ref;
              }),
            };
      const evidence =
        x.evidence === undefined
          ? {}
          : {
              evidence: listOf(x.evidence, `${what}.evidence`).map((e, i) =>
                evidenceRefOf(e, validatorCount, `${what}.evidence[${i}]`),
              ),
            };
      return {
        kind: "omit-inclusion",
        slot: slotOf(x.slot, `${what}.slot`),
        ...votes,
        ...evidence,
      };
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
  const params = paramsOf(data.config.params, validatorCount, "config.params");
  const initialStakes = initialStakesOf(
    data.config.initialStakes,
    validatorCount,
    "config.initialStakes",
  );
  const runSlot = slotOf(data.runSlot, "runSlot");
  if (!Array.isArray(data.interventions)) {
    throw new ParseError("interventions must be an array");
  }
  const interventions = data.interventions.map((x, i) =>
    interventionOf(x, validatorCount, `interventions[${i}]`),
  );
  return {
    scenario: {
      config: { validatorCount, seed, params, initialStakes },
      interventions,
    },
    runSlot,
  };
}
