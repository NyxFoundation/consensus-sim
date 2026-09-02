// Protocol parameters (プロトコルパラメータ) and presets (プロトコルプリセット).
// Reference type from ESSENCE.md:
//   ProtocolParams = {committee, boost, forkChoice, equivocationDiscount,
//                     checkpointSwitch, slashing, inactivityLeak}
// A preset is a named bundle corresponding to a real point in Ethereum's
// history; an attack declares its premise as a preset name plus overrides.
// The default is `merge`.

/** Who attests in a slot: everyone, or `size` validators drawn per slot
 * deterministically from the seed (schedule.ts). */
export type CommitteeAssignment =
  | { readonly kind: "all" }
  | { readonly kind: "sized"; readonly size: number };

/** GHOST counts every vote; LMD-GHOST only each validator's latest. */
export type ForkChoiceRule = "GHOST" | "LMD-GHOST";

/** How the fork-choice root may move to a newer justified checkpoint
 * (justified チェックポイント切替): only in the head slots of an epoch
 * (`window`), by unrealized justification (`unrealized`), or freely (`off`). */
export type CheckpointSwitch = "window" | "unrealized" | "off";

export interface InactivityLeak {
  readonly enabled: boolean;
  /** Epochs without finality progress before the leak starts (N). */
  readonly delayEpochs: number;
  /** Fraction of stake removed per epoch from validators whose target vote
   * the branch has not included (r). */
  readonly rate: number;
}

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
export const DEFAULT_INACTIVITY_LEAK: InactivityLeak = {
  enabled: true,
  delayEpochs: 4,
  rate: 0.25,
};

export const PRESETS: Readonly<Record<PresetName, ProtocolParams>> = {
  /** Beacon chain genesis (2020-12): no boost, no discount, window switch. */
  phase0: {
    committee: { kind: "all" },
    boost: 0,
    forkChoice: "LMD-GHOST",
    equivocationDiscount: false,
    checkpointSwitch: "window",
    slashing: true,
    inactivityLeak: DEFAULT_INACTIVITY_LEAK,
  },
  /** The Merge (2022-09): proposer boost 0.4 and equivocation discount. */
  merge: {
    committee: { kind: "all" },
    boost: 0.4,
    forkChoice: "LMD-GHOST",
    equivocationDiscount: true,
    checkpointSwitch: "window",
    slashing: true,
    inactivityLeak: DEFAULT_INACTIVITY_LEAK,
  },
  /** After the 2023 fork-choice fixes: unrealized justification. */
  current: {
    committee: { kind: "all" },
    boost: 0.4,
    forkChoice: "LMD-GHOST",
    equivocationDiscount: true,
    checkpointSwitch: "unrealized",
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

export function sameParams(a: ProtocolParams, b: ProtocolParams): boolean {
  return (
    a.committee.kind === b.committee.kind &&
    (a.committee.kind !== "sized" ||
      b.committee.kind !== "sized" ||
      a.committee.size === b.committee.size) &&
    a.boost === b.boost &&
    a.forkChoice === b.forkChoice &&
    a.equivocationDiscount === b.equivocationDiscount &&
    a.checkpointSwitch === b.checkpointSwitch &&
    a.slashing === b.slashing &&
    a.inactivityLeak.enabled === b.inactivityLeak.enabled &&
    a.inactivityLeak.delayEpochs === b.inactivityLeak.delayEpochs &&
    a.inactivityLeak.rate === b.inactivityLeak.rate
  );
}
