// Message reference (メッセージ参照) — how a message is named: by its sender,
// its slot and its kind (proposal | vote), plus — once it is published — the
// individual: a block by its index, a vote by its whole content (under
// equivocation the sender's two messages of one slot differ only there). A
// reference without the individual names every message the sender publishes
// in that slot of that kind, so a message can be named ahead of its
// publication — the form an attacker's strategy uses to withhold or
// selectively deliver a message that does not exist yet. Inclusion omissions
// (取り込みの省略) and delay / drop actions refer to messages through this
// type.

import { compareVoteContent } from "./order";
import type { BlockIndex, ProposedBlock, SlotIndex, ValidatorIndex, Vote } from "./types";

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

/** The exact reference of a published block. */
export const blockRef = (block: ProposedBlock): MessageRef => ({
  kind: "proposal",
  sender: block.proposer,
  slot: block.slot,
  block: block.index,
});

/** The exact reference of a published vote. */
export const voteRef = (vote: Vote): MessageRef => ({
  kind: "vote",
  sender: vote.validator,
  slot: vote.slot,
  vote,
});

/** Whether two references name the same thing: same sender, slot and kind,
 * and the same individual (or both without one). */
export function sameRef(a: MessageRef, b: MessageRef): boolean {
  if (a.kind !== b.kind || a.sender !== b.sender || a.slot !== b.slot) return false;
  if (a.kind === "proposal") return a.block === (b as typeof a).block;
  const other = (b as typeof a).vote;
  if (a.vote === undefined || other === undefined) return a.vote === other;
  return compareVoteContent(a.vote, other) === 0;
}

/** Whether `selector` names the published message `message` (an exact
 * reference): the identical reference, or — when the selector carries no
 * individual — any message of that sender, slot and kind. */
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

/** Whether a reference names the individual message (published) rather than
 * everything of its sender, slot and kind. */
export function isExactRef(ref: MessageRef): boolean {
  return (ref.kind === "proposal" ? ref.block : ref.vote) !== undefined;
}
