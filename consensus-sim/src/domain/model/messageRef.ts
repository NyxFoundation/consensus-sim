// メッセージ参照 — メッセージをどう名指すか: 送信者・
// スロット・種別(proposal | vote)に加え、公開済みであれば個体
// — ブロックはその index で、投票はその内容全体で(エクイボケーション下
// では送信者の同一スロットの 2 メッセージはそこでしか違わない)。個体を
// 持たない参照は、その送信者がそのスロット・その種別で公開するあらゆる
// メッセージを名指す。そのため公開前のメッセージも名指すことができ、
// これは攻撃者の戦略がまだ存在しないメッセージを保留したり選択的に配送
// したりする際に用いる形である。取り込みの省略や遅延・欠落の行動は、
// この型を通じてメッセージを参照する。

import { compareVoteContent } from "./order";
import type { BlockIndex, ProposedBlock, SlotIndex, ValidatorIndex, Vote } from "./types";

/** メッセージ参照: 送信者・スロット・種別、および公開済みなら個体を
 * 添えたメッセージの名指し。個体を持たなければ未公開のメッセージも
 * 名指せる。 */
export type MessageRef =
  | {
      readonly kind: "proposal";
      readonly sender: ValidatorIndex;
      readonly slot: SlotIndex;
      readonly block?: BlockIndex;
    }
  | {
      readonly kind: "vote";
      readonly sender: ValidatorIndex;
      readonly slot: SlotIndex;
      readonly vote?: Vote;
    };

/** 公開済みブロックの厳密な参照。 */
export const blockRef = (block: ProposedBlock): MessageRef => ({
  kind: "proposal",
  sender: block.proposer,
  slot: block.slot,
  block: block.index,
});

/** 公開済み投票の厳密な参照。 */
export const voteRef = (vote: Vote): MessageRef => ({
  kind: "vote",
  sender: vote.validator,
  slot: vote.slot,
  vote,
});

/** 2 つの参照が同じものを名指すか否か: 送信者・スロット・種別が同じで、
 * かつ個体も同じである(または両方とも個体を持たない)こと。 */
export function sameRef(a: MessageRef, b: MessageRef): boolean {
  if (a.kind !== b.kind || a.sender !== b.sender || a.slot !== b.slot) return false;
  if (a.kind === "proposal") return a.block === (b as typeof a).block;
  const other = (b as typeof a).vote;
  if (a.vote === undefined || other === undefined) return a.vote === other;
  return compareVoteContent(a.vote, other) === 0;
}

/** `selector` が公開済みメッセージ `message`(厳密な参照)を名指すか
 * 否か: 同一の参照であるか、または selector が個体を持たない場合はその
 * 送信者・スロット・種別のあらゆるメッセージであること。 */
export function coversMessage(selector: MessageRef, message: MessageRef): boolean {
  const individual = selector.kind === "proposal" ? selector.block : selector.vote;
  if (individual === undefined) {
    return (
      selector.kind === message.kind &&
      selector.sender === message.sender &&
      selector.slot === message.slot
    );
  }
  return sameRef(selector, message);
}

/** 参照がその送信者・スロット・種別のすべてではなく、個体(公開済み)の
 * メッセージを名指しているか否か。 */
export function isExactRef(ref: MessageRef): boolean {
  return (ref.kind === "proposal" ? ref.block : ref.vote) !== undefined;
}
