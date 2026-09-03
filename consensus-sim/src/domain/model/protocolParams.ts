// Protocol parameters (プロトコルパラメータ) and presets (プロトコルプリセット).
// Reference type from ESSENCE.md:
//   ProtocolParams = {committee, boost, forkChoice, equivocationDiscount,
//                     checkpointSwitch: {window, unrealized}, slashing,
//                     inactivityLeak: {delayEpochs, rate} | off}
// A preset is a named bundle corresponding to a real point in Ethereum's
// history; an attack declares its premise as a preset name plus overrides.
// The default is `merge`.

/** Who attests in a slot: everyone; `size` validators drawn per slot
 * deterministically from the seed; or an epoch split (エポック分割) —
 * Ethereum's committee structure, where every validator attests in exactly
 * one seed-assigned slot of each epoch (schedule.ts). */
export type CommitteeAssignment =
  | { readonly kind: "all" }
  | { readonly kind: "sized"; readonly size: number }
  | { readonly kind: "epoch-split" };

/** GHOST counts every vote; LMD-GHOST only each validator's latest. */
export type ForkChoiceRule = "GHOST" | "LMD-GHOST";

/** Justified-checkpoint switching (justified チェックポイント切替): two
 * independent switches on the fork-choice root. `window`: the root may move
 * to a conflicting justified checkpoint only in the head section of an
 * epoch. `unrealized`: branches whose included votes can only justify a
 * checkpoint older than the root are excluded from the candidates.
 * Ethereum introduced the former first and the latter later, both against
 * bouncing. */
export interface CheckpointSwitch {
  readonly window: boolean;
  readonly unrealized: boolean;
}

/** The inactivity leak's schedule: once finality lags by more than
 * `delayEpochs` epochs (N), every validator without a target vote of an
 * epoch included on the branch loses the fraction `rate` (r) of its stake
 * for that epoch. */
export interface LeakSchedule {
  readonly delayEpochs: number;
  readonly rate: number;
}

/** Inactivity leak (inactivity leak): its schedule, or off. */
export type InactivityLeak = LeakSchedule | "off";

export interface ProtocolParams {
  readonly committee: CommitteeAssignment;
  /** Proposer boost as a fraction of the slot committee's total weight (0–1). */
  readonly boost: number;
  readonly forkChoice: ForkChoiceRule;
  readonly equivocationDiscount: boolean;
  readonly checkpointSwitch: CheckpointSwitch;
  readonly slashing: boolean;
  readonly inactivityLeak: InactivityLeak;
}

export type PresetName = "phase0" | "merge" | "current";

export const PRESET_NAMES: readonly PresetName[] = ["phase0", "merge", "current"];

export const DEFAULT_PRESET: PresetName = "merge";

/** Leak defaults: N = 4 epochs (ESSENCE), r = 1/4 per epoch (discretion —
 * coarse enough to be visible within a few epochs of a stalled branch). */
export const DEFAULT_INACTIVITY_LEAK: LeakSchedule = {
  delayEpochs: 4,
  rate: 0.25,
};

export const PRESETS: Readonly<Record<PresetName, ProtocolParams>> = {
  /** Beacon chain genesis (2020-12): no boost, no discount, the window. */
  phase0: {
    committee: { kind: "all" },
    boost: 0,
    forkChoice: "LMD-GHOST",
    equivocationDiscount: false,
    checkpointSwitch: { window: true, unrealized: false },
    slashing: true,
    inactivityLeak: DEFAULT_INACTIVITY_LEAK,
  },
  /** The Merge (2022-09): proposer boost 0.4 and equivocation discount. */
  merge: {
    committee: { kind: "all" },
    boost: 0.4,
    forkChoice: "LMD-GHOST",
    equivocationDiscount: true,
    checkpointSwitch: { window: true, unrealized: false },
    slashing: true,
    inactivityLeak: DEFAULT_INACTIVITY_LEAK,
  },
  /** After the 2023 fork-choice fixes: unrealized justification replaces
   * the window. */
  current: {
    committee: { kind: "all" },
    boost: 0.4,
    forkChoice: "LMD-GHOST",
    equivocationDiscount: true,
    checkpointSwitch: { window: false, unrealized: true },
    slashing: true,
    inactivityLeak: DEFAULT_INACTIVITY_LEAK,
  },
};

export function presetParams(name: PresetName): ProtocolParams {
  return PRESETS[name];
}

export const DEFAULT_PARAMS: ProtocolParams = PRESETS[DEFAULT_PRESET];

/** The preset `params` equals field by field, if any. */
export function presetOf(params: ProtocolParams): PresetName | undefined {
  return PRESET_NAMES.find((name) => sameParams(PRESETS[name], params));
}

export function sameLeak(a: InactivityLeak, b: InactivityLeak): boolean {
  if (a === "off" || b === "off") return a === b;
  return a.delayEpochs === b.delayEpochs && a.rate === b.rate;
}

export function sameParams(a: ProtocolParams, b: ProtocolParams): boolean {
  return (
    a.committee.kind === b.committee.kind &&
    (a.committee.kind !== "sized" ||
      b.committee.kind !== "sized" ||
      a.committee.size === b.committee.size) &&
    a.boost === b.boost &&
    a.forkChoice === b.forkChoice &&
    a.equivocationDiscount === b.equivocationDiscount &&
    a.checkpointSwitch.window === b.checkpointSwitch.window &&
    a.checkpointSwitch.unrealized === b.checkpointSwitch.unrealized &&
    a.slashing === b.slashing &&
    sameLeak(a.inactivityLeak, b.inactivityLeak)
  );
}
