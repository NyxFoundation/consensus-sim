// Attack library metadata and registry (攻撃ライブラリ) — the catalog the
// attack-list page (攻撃一覧, 必須 22) is derived from, and the registry the
// scenario codec resolves saved attacks through. This is a simulator concern
// (each entry carries a default run, a source id and a Japanese summary for the
// UI), so it lives in the sim module; the strategies and attack triples it
// references are the essential specification (model/attackLibrary.ts).
//
// A library attack declares its premise as a preset name plus overrides
// (プリセット名+上書き); `premiseParams` resolves that to the ProtocolParams a
// run uses. The default run (既定実行構成) satisfies the attacker-set condition
// and is proposed as a scenario's initial conditions when the row is chosen.

import type { Attack } from "../model/attack";
import {
  ATTACK_A01,
  ATTACK_A02,
  ATTACK_A07,
  ATTACK_A09,
  ATTACK_A10,
  ATTACK_A11,
  ATTACK_A12,
  ATTACK_A14,
} from "../model/attackLibrary";
import type { AttackGoal } from "../model/attackGoal";
import type { AttackerCondition, AttackParams, Capability } from "../model/attack";
import type { AttackRegistry } from "./scenarioCodec";
import { PRESETS, type PresetName, type ProtocolParams } from "../model/protocolParams";
import { equalStakes } from "../model/config";
import type { SlotIndex, Stake, ValidatorIndex } from "../model/types";

/** An attack's premise: a preset with optional field overrides. */
export interface AttackPremise {
  readonly preset: PresetName;
  readonly overrides?: Partial<ProtocolParams>;
}

/** The ProtocolParams a premise resolves to. */
export function premiseParams(premise: AttackPremise): ProtocolParams {
  return { ...PRESETS[premise.preset], ...premise.overrides };
}

/** The concrete run proposed when an attack is selected (既定実行構成). */
export interface AttackDefaultRun {
  readonly validatorCount: number;
  readonly initialStakes: readonly Stake[];
  readonly attackers: readonly ValidatorIndex[];
  readonly params: AttackParams;
  /** How far the default run is carried for the goal to be reached. */
  readonly throughSlot: SlotIndex;
}

/** One row of the attack library: its identity, premise, the formal-system
 * fields (attacker condition, goal, strategy) and everything the UI shows. */
export interface LibraryAttack {
  readonly id: string;
  readonly name: string;
  /** Provenance: the attack id in the review report (出典). */
  readonly source: string;
  readonly premise: AttackPremise;
  readonly attackers: AttackerCondition;
  readonly capabilities: readonly Capability[];
  readonly goal: readonly AttackGoal[];
  readonly strategySummary: string;
  readonly strategy: Attack["strategy"];
  readonly defaultRun: AttackDefaultRun;
}

const REPORT = "essences/deep-research-report.md";

export const ATTACK_LIBRARY: readonly LibraryAttack[] = [
  {
    id: "A01",
    name: "Ex-Ante リオーグ(保留+時機)",
    source: `${REPORT}#A01`,
    premise: { preset: "phase0" },
    attackers: ATTACK_A01.attackers,
    capabilities: ["withhold", "delay-honest"],
    goal: ATTACK_A01.goal,
    strategySummary:
      "攻撃者は自分の提案ブロックと投票をスロット 3 まで保留し、その間の正直投票を遅延させて" +
      "正直チェーンを proposer boost だけで支えさせる。スロット 3 で公開すると、boost の無い" +
      "phase0 では正直 head が攻撃者ブロックへ移りリオーグとなる(merge では boost が防ぐ)。",
    strategy: ATTACK_A01.strategy,
    defaultRun: {
      validatorCount: 4,
      initialStakes: equalStakes(4),
      attackers: [1],
      params: { maxDelay: 2 },
      throughSlot: 6,
    },
  },
  {
    id: "A02",
    name: "proposer boost 逆用リオーグ",
    source: `${REPORT}#A02`,
    premise: { preset: "merge" },
    attackers: ATTACK_A02.attackers,
    capabilities: ["propose-parent", "vote-target", "delay-honest"],
    goal: ATTACK_A02.goal,
    strategySummary:
      "攻撃者はスロット 5 で祖父ブロック B3 の上に提案して正直 B4 を飛ばし、自分の B4 への投票を" +
      "外し他の正直 B4 投票を遅延させて B4 を 1 票だけにする。proposer boost が攻撃者ブロックに付き" +
      "正直 head が B4 から攻撃者ブロックへ移る(boost がこのリオーグを可能にする)。",
    strategy: ATTACK_A02.strategy,
    defaultRun: {
      validatorCount: 4,
      initialStakes: equalStakes(4),
      attackers: [1],
      params: { maxDelay: 2 },
      throughSlot: 8,
    },
  },
  {
    id: "A07",
    name: "アバランチ(秘匿エクイボケーションブロック列)",
    source: `${REPORT}#A07`,
    premise: { preset: "phase0", overrides: { forkChoice: "GHOST" } },
    attackers: ATTACK_A07.attackers,
    capabilities: ["withhold", "equivocation", "vote-target", "propose-parent", "delay-honest"],
    goal: ATTACK_A07.goal,
    strategySummary:
      "攻撃者はスロット 1・5 の自ブロック列を秘匿し、毎スロットそれへ投票(スロット 5 は二重投票)" +
      "しつつ投票も保留、正直投票を遅延させる。スロット 6 に一斉公開すると、GHOST は古い票・" +
      "相反票をすべて数えるため秘匿枝が正直枝を上回り正直 head が移る(リオーグ)。LMD-GHOST は" +
      "最新票しか数えず、割引が相反票を除くため merge では未達。",
    strategy: ATTACK_A07.strategy,
    defaultRun: {
      validatorCount: 4,
      initialStakes: equalStakes(4),
      attackers: [1],
      params: { maxDelay: 5 },
      throughSlot: 10,
    },
  },
  {
    id: "A09",
    name: "1/3 超の棄権による finality 停止",
    source: `${REPORT}#A09`,
    premise: { preset: "merge" },
    attackers: ATTACK_A09.attackers,
    capabilities: ["silence"],
    goal: ATTACK_A09.goal,
    strategySummary:
      "攻撃者(全ステークの半分)がスロット 1 以降に沈黙(オンライン停止)する。投票者が" +
      "残り 2 体では source→target リンクが 2/3 supermajority に届かず、finalized が錨から進まず" +
      "活性が停止する。",
    strategy: ATTACK_A09.strategy,
    defaultRun: {
      validatorCount: 4,
      initialStakes: equalStakes(4),
      attackers: [2, 3],
      params: { maxDelay: 2 },
      throughSlot: 16,
    },
  },
  {
    id: "A10",
    name: "34% 二重投票による二重 finality",
    source: `${REPORT}#A10`,
    premise: { preset: "merge" },
    attackers: ATTACK_A10.attackers,
    capabilities: ["propose-parent", "vote-target", "withhold", "drop-honest"],
    goal: ATTACK_A10.goal,
    strategySummary:
      "攻撃者(ステークの 1/3 以上)は正直 2 体の視界を分割し(一方は攻撃者のスロット 3 " +
      "ブロックを、他方は正直スロット 4 ブロックを見ない)、各正直者に別々の枝を伸ばさせる。" +
      "同一エポックの target 投票を時機をずらして両枝へ投じ、自分の提案スロットで両枝を延ばすと、" +
      "各枝が正直 1 体+攻撃者で 2/3 に達して両方が finalize し、相反する finalized " +
      "チェックポイントが並ぶ(安全性違反)。",
    strategy: ATTACK_A10.strategy,
    defaultRun: {
      validatorCount: 4,
      initialStakes: equalStakes(4),
      attackers: [2, 3],
      params: { maxDelay: 2 },
      throughSlot: 12,
    },
  },
  {
    id: "A11",
    name: "51% 多数派 fork choice 支配リオーグ",
    source: `${REPORT}#A11`,
    premise: { preset: "merge" },
    attackers: ATTACK_A11.attackers,
    capabilities: ["propose-parent", "vote-target"],
    goal: ATTACK_A11.goal,
    strategySummary:
      "多数派の攻撃者(ステークの過半)がスロット 4 で錨上に分岐ブロックを提案し、全員が" +
      "スロット 4・5 の投票をそこへ向ける。LMD fork choice を票数で支配し、正直 head が直前" +
      "スロットの子孫でない分岐へ移る(リオーグ)。検閲は取引を扱わないため多数派支配として扱う。",
    strategy: ATTACK_A11.strategy,
    defaultRun: {
      validatorCount: 4,
      initialStakes: equalStakes(4),
      attackers: [0, 1, 2],
      params: { maxDelay: 2 },
      throughSlot: 8,
    },
  },
  {
    id: "A12",
    name: "66% 履歴支配",
    source: `${REPORT}#A12`,
    premise: { preset: "merge" },
    attackers: ATTACK_A12.attackers,
    capabilities: ["propose-parent", "vote-target"],
    goal: ATTACK_A12.goal,
    strategySummary:
      "攻撃者(ステークの 2/3 以上)はまず正直に振る舞い、正直チェーンの B4 を finalize させる。" +
      "スロット 12 に錨ブロック上へ分岐を提案し、以後の投票をその枝へ向けて自分の提案スロットで" +
      "延ばすと、supermajority が分岐側のチェックポイントを justify・finalize し、finalized 済みの" +
      "履歴と相反するチェックポイントが finalize される(安全性違反)。",
    strategy: ATTACK_A12.strategy,
    defaultRun: {
      validatorCount: 4,
      initialStakes: equalStakes(4),
      attackers: [0, 1, 2],
      params: { maxDelay: 2 },
      throughSlot: 20,
    },
  },
  {
    id: "A14",
    name: "inactivity leak 増幅",
    source: `${REPORT}#A14`,
    premise: { preset: "merge" },
    attackers: ATTACK_A14.attackers,
    capabilities: ["drop-honest", "vote-target"],
    goal: ATTACK_A14.goal,
    strategySummary:
      "攻撃者(ステークの 1/3 未満)は正直 1 体を他の正直者から分断し(分断を始める 2 提案を" +
      "互いに欠落させる)、両枝に毎エポック投票する。孤立枝では finality が停止して他の正直者が" +
      "leak し、攻撃者は leak しないため、孤立正直者の head の枝で攻撃者比率が 1/3 に達する" +
      "(第 1 段)。同じ侵食で孤立正直者+攻撃者が 2/3 に達して孤立枝が独自に finalize し、攻撃者が" +
      "finalize させ続けた他枝と相反する(第 2 段: 安全性違反)。",
    strategy: ATTACK_A14.strategy,
    defaultRun: {
      validatorCount: 4,
      initialStakes: equalStakes(4),
      attackers: [3],
      params: { maxDelay: 2 },
      throughSlot: 44,
    },
  },
];

/** The library keyed by attack id, as the codec resolves a saved attack. */
export const ATTACK_REGISTRY: AttackRegistry = new Map(
  ATTACK_LIBRARY.map((entry): [string, Attack] => [
    entry.id,
    { attackers: entry.attackers, goal: entry.goal, strategy: entry.strategy },
  ]),
);
