// プロトコルパラメータとプロトコルプリセット。
// ESSENCE.md の参照型:
//   ProtocolParams = {committee, boost, forkChoice, equivocationDiscount,
//                     checkpointSwitch: {window, unrealized}, slashing,
//                     inactivityLeak: {delayEpochs, rate} | off}
// プロトコルプリセットは Ethereum の実在時点に対応する名前付きの束であり、
// 攻撃はその前提をプリセット名+個別上書きとして宣言する。既定は `merge`。

/** あるスロットで誰が投票するか: 全員;シードから決定的にスロットごとに
 * 引かれる `size` 人のバリデータ;またはエポック分割 — Ethereum の
 * committee 構造であり、各バリデータがエポックごとにシードで決まる
 * ちょうど 1 スロットで投票する(schedule.ts)。 */
export type CommitteeAssignment =
  | { readonly kind: "all" }
  | { readonly kind: "sized"; readonly size: number }
  | { readonly kind: "epoch-split" };

/** GHOST はすべての投票を数え、LMD-GHOST は各バリデータの最新のみを
 * 数える。 */
export type ForkChoiceRule = "GHOST" | "LMD-GHOST";

/** justified チェックポイント切替: fork choice の起点に対する 2 つの
 * 独立したスイッチ。`window`: 起点はエポックの先頭区間に限り、競合する
 * justified チェックポイントへ移動できる。`unrealized`: 取り込まれた
 * 投票が起点より古いチェックポイントしか justify できない枝を候補から
 * 除外する。Ethereum は前者を先に、後者を後に導入し、いずれも
 * バウンシングへの対策である。 */
export interface CheckpointSwitch {
  readonly window: boolean;
  readonly unrealized: boolean;
}

/** inactivity leak の発動条件: finality が `delayEpochs` エポック(N)
 * を超えて遅れると、その枝に取り込まれたそのエポックの target 投票を
 * 持たない各バリデータは、そのエポック分のステークの `rate`(r)の
 * 割合を失う。 */
export interface LeakSchedule {
  readonly delayEpochs: number;
  readonly rate: number;
}

/** inactivity leak: その発動条件、または off。 */
export type InactivityLeak = LeakSchedule | "off";

/** プロトコルパラメータ: committee 割当方式・サイズ、proposer boost、
 * fork choice 規則、エクイボケーション割引、justified チェックポイント
 * 切替、スラッシング、inactivity leak。初期条件の一部。 */
export interface ProtocolParams {
  readonly committee: CommitteeAssignment;
  /** proposer boost。スロットの committee の総重みに対する割合(0–1)。 */
  readonly boost: number;
  readonly forkChoice: ForkChoiceRule;
  readonly equivocationDiscount: boolean;
  readonly checkpointSwitch: CheckpointSwitch;
  readonly slashing: boolean;
  readonly inactivityLeak: InactivityLeak;
}

/** プロトコルプリセットの名前。Ethereum の実在時点に対応する。 */
export type PresetName = "phase0" | "merge" | "current";

export const PRESET_NAMES: readonly PresetName[] = ["phase0", "merge", "current"];

export const DEFAULT_PRESET: PresetName = "merge";

/** inactivity leak の既定値: N = 4 エポック(ESSENCE 準拠)、r = エポック
 * 当たり 1/4(裁量による設定 — 枝が停滞したときに数エポックのうちに
 * 可視になる程度に粗くしてある)。 */
export const DEFAULT_INACTIVITY_LEAK: LeakSchedule = {
  delayEpochs: 4,
  rate: 0.25,
};

export const PRESETS: Readonly<Record<PresetName, ProtocolParams>> = {
  /** Beacon chain のジェネシス(2020-12): boost なし、割引なし、window
   * のみ。 */
  phase0: {
    committee: { kind: "all" },
    boost: 0,
    forkChoice: "LMD-GHOST",
    equivocationDiscount: false,
    checkpointSwitch: { window: true, unrealized: false },
    slashing: true,
    inactivityLeak: DEFAULT_INACTIVITY_LEAK,
  },
  /** The Merge(2022-09): proposer boost 0.4 とエクイボケーション割引。 */
  merge: {
    committee: { kind: "all" },
    boost: 0.4,
    forkChoice: "LMD-GHOST",
    equivocationDiscount: true,
    checkpointSwitch: { window: true, unrealized: false },
    slashing: true,
    inactivityLeak: DEFAULT_INACTIVITY_LEAK,
  },
  /** 2023 年の fork choice 修正以降: unrealized justification が window
   * に置き換わる。 */
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

/** `params` とフィールドごとに等しいプロトコルプリセット。なければ
 * undefined。 */
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
