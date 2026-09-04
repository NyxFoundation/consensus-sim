// 骨格の全順序(骨格の規則)。BlockIndex 自体は識別のみを担う。プロトコルが
// 解消すべきあらゆるタイブレーク — fork choice における子ブロック間、
// 同一エポックのチェックポイント間、エクイボケーションの両半分の間 — は
// ここで宣言する唯一の順序で解消されるため、結果はメッセージの到着順に
// 依存しない(決定性)。

import type { Checkpoint, Vote } from "./types";

/** BlockIndex 上の順序: 昇順。タイブレークでは小さい方の識別子が優先
 * される。`a` が優先されるとき負値を返す。 */
export function compareBlockIndex(a: number, b: number): number {
  return a - b;
}

/** チェックポイントはまずエポックで順序付け(後のエポックほど高い)、
 * 次にブロックの順序で順序付ける(優先されるブロックが高い)。`a` が
 * 高いとき負値を返す。 */
export function compareCheckpoints(a: Checkpoint, b: Checkpoint): number {
  return b.epoch - a.epoch || compareBlockIndex(a.block, b.block);
}

export function sameCheckpoint(a: Checkpoint, b: Checkpoint): boolean {
  return a.epoch === b.epoch && a.block === b.block;
}

/** 2 つのチェックポイントのうち高い方(両者が等しければ `a`)。 */
export function higherCheckpoint(a: Checkpoint, b: Checkpoint): Checkpoint {
  return compareCheckpoints(a, b) <= 0 ? a : b;
}

/** map のキーとして用いるチェックポイントの識別子。 */
export function checkpointKey(c: Checkpoint): string {
  return `${c.epoch}:${c.block}`;
}

/** チェックポイントの昇順(低い方が先): エポック、次いでブロック。 */
function ascendingCheckpoints(a: Checkpoint, b: Checkpoint): number {
  return a.epoch - b.epoch || compareBlockIndex(a.block, b.block);
}

/** 同一バリデータ・同一スロットの投票の内容順: head、次いで source、
 * 次いで target の順に、それぞれ上記の順序で昇順に比較する。`a` が
 * 先に来るとき負値を返す。 */
export function compareVoteContent(a: Vote, b: Vote): number {
  return (
    compareBlockIndex(a.head, b.head) ||
    ascendingCheckpoints(a.source, b.source) ||
    ascendingCheckpoints(a.target, b.target)
  );
}

/** 同一バリデータの複数スロットにまたがる投票の順序: 早いスロットが先、
 * 次いで内容順。`a` が先に来るとき負値を返す。 */
export function compareVotes(a: Vote, b: Vote): number {
  return a.slot - b.slot || compareVoteContent(a, b);
}
