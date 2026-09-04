// 予定表 — あるスロットで誰が提案し誰が投票するか、初期条件から
// 導出される。公開情報である: 攻撃者を含む全バリデータが同じ入力から同じ
// 予定表を計算する。
//
// 本質的仕様はプロポーザー規則(ラウンドロビン — パラメータではなく骨格の
// 規則)と、committee 割当方式ごとの committee の構造を固定する。それらを
// 実際にどのシードで並べ替えて引くかはシミュレータの仕事(sim/schedule.ts)
// であり、モデルは `Permutation` のみを要求する。

import { SLOTS_PER_EPOCH, epochOf, slotsSinceEpochStart } from "./finality";
import { validatorIndices, type InitialConditions } from "./initialConditions";
import type { SlotIndex, ValidatorIndex } from "./types";

/** ESSENCE.md の参照型: Schedule = {proposerOf, committeeOf}。 */
export interface Schedule {
  proposerOf(slot: SlotIndex): ValidatorIndex;
  committeeOf(slot: SlotIndex): ReadonlySet<ValidatorIndex>;
}

/** (seed, key) で決まる、バリデータの決定的な並べ替え: 同じ入力は常に
 * 同じ並べ替えを生む。 */
export type Permutation = (
  validators: readonly ValidatorIndex[],
  seed: number,
  key: number,
) => readonly ValidatorIndex[];

/** ラウンドロビンのプロポーザー予定表: スロット s はバリデータ s mod n
 * が提案する。 */
export function proposerForSlot(
  slot: SlotIndex,
  config: InitialConditions,
): ValidatorIndex {
  const n = config.validatorCount;
  return ((slot % n) + n) % n;
}

/**
 * `slot` の committee を、識別子の昇順で返す:
 * - `all`: 全員;
 * - `sized`: 相異なる `size` 人のバリデータ — スロットをキーとする
 *   並べ替えの先頭 `size` 人;
 * - `epoch-split`: エポックをキーとする並べ替えをそのエポックの各スロット
 *   にラウンドロビンで配るため、各バリデータはエポックごとにちょうど
 *   1 スロットで投票し、各スロットの committee のサイズの差は高々 1 と
 *   なる。
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

/** 並べ替え方式を与えたとき、初期条件が定める予定表。 */
export function deriveSchedule(
  config: InitialConditions,
  permute: Permutation,
): Schedule {
  return {
    proposerOf: (slot) => proposerForSlot(slot, config),
    committeeOf: (slot) => committeeForSlot(slot, config, permute),
  };
}
