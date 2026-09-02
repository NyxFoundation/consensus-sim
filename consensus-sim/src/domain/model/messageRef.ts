// Message identity (メッセージの同一性) — how a single published message is
// named: a block by its index, a vote by (validator, slot, head). Under
// equivocation the two votes of one validator in one slot differ in head,
// so each stays addressable. Inclusion omissions (取り込みの省略) and the
// attacker's delay / drop actions refer to messages through this type.

import type { BlockIndex, SlotIndex, ValidatorIndex, Vote } from "./types";

export type MessageRef =
  | { readonly kind: "block"; readonly block: BlockIndex }
  | {
      readonly kind: "vote";
      readonly validator: ValidatorIndex;
      readonly slot: SlotIndex;
      readonly head: BlockIndex;
    };

export const voteRef = (vote: Vote): MessageRef => ({
  kind: "vote",
  validator: vote.validator,
  slot: vote.slot,
  head: vote.head,
});

export function sameRef(a: MessageRef, b: MessageRef): boolean {
  if (a.kind === "block" && b.kind === "block") return a.block === b.block;
  if (a.kind === "vote" && b.kind === "vote") {
    return a.validator === b.validator && a.slot === b.slot && a.head === b.head;
  }
  return false;
}
