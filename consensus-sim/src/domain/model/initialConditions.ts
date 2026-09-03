// シナリオの初期条件 — シナリオの識別のうちプロトコルが読む
// 部分: バリデータ数・シード・プロトコルパラメータ・各バリデータの初期
// ステーク。(スロット, パラメータ, シード)から導出されるすべて — 予定表
// (プロポーザー)と committee — は全バリデータが知る公開情報である。

import type { ProtocolParams } from "./protocolParams";
import type { Stake, ValidatorIndex } from "./types";

/** 初期条件: バリデータ数・初期ステーク・プロトコルパラメータ・シードの
 * 組。シナリオの一部であり、プロトコルが読む入力。 */
export interface InitialConditions {
  readonly validatorCount: number;
  /** シードを用いるあらゆる導出(サイズ指定 committee など)を駆動する。
   * シナリオの識別の一部であるため、同じシナリオは常に同一に再現される。 */
  readonly seed: number;
  readonly params: ProtocolParams;
  /** バリデータごとの初期ステーク、ValidatorIndex で添字付け。既定では
   * 全員で等しい。チェーン状態はこれとその枝が取り込んだ内容から以降の
   * すべてのステークを導出する。 */
  readonly initialStakes: readonly Stake[];
}

/** 0..count-1 の識別子、この実行の全バリデータの識別。モデル自体は
 * バリデータ数に依存しない。シミュレータ側の上下限(4〜10)は sim
 * モジュールで課される制約である。 */
export function validatorIndices(count: number): ValidatorIndex[] {
  return Array.from({ length: count }, (_, i) => i);
}

/** シナリオが別段の指定をしない限り全員が持つ初期ステーク。 */
export const DEFAULT_STAKE: Stake = 32;

export function equalStakes(validatorCount: number): readonly Stake[] {
  return validatorIndices(validatorCount).map(() => DEFAULT_STAKE);
}
