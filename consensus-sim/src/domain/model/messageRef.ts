// Message identity (メッセージの同一性) — how a message is named. A published
// message is named exactly: a block by its index, a vote by
// (validator, slot, head) — under equivocation the two votes of one validator
// in one slot differ in head, so each stays addressable. A message can also
// be named ahead of its publication, by who publishes it and when: the
// proposal(s) of `proposer` at `slot`, or the attestation(s) of `validator`
// at `slot` — the form an attacker's strategy uses to hold back or delay a
// message that does not exist yet (under equivocation it names both halves).
// Inclusion omissions (取り込みの省略) and delay / drop actions refer to
// messages through this type.

import type { BlockIndex, SlotIndex, ValidatorIndex, Vote } from "./types";

export type MessageRef =
  | { readonly kind: "block"; readonly block: BlockIndex }
  | {
      readonly kind: "vote";
      readonly validator: ValidatorIndex;
      readonly slot: SlotIndex;
      readonly head: BlockIndex;
    }
  | { readonly kind: "proposal"; readonly proposer: ValidatorIndex; readonly slot: SlotIndex }
  | { readonly kind: "attestation"; readonly validator: ValidatorIndex; readonly slot: SlotIndex };

export const voteRef = (vote: Vote): MessageRef => ({
  kind: "vote",
  validator: vote.validator,
  slot: vote.slot,
  head: vote.head,
});

/** Whether two references name the same thing, form for form. */
export function sameRef(a: MessageRef, b: MessageRef): boolean {
  if (a.kind !== b.kind) return false;
  switch (a.kind) {
    case "block":
      return a.block === (b as typeof a).block;
    case "vote": {
      const v = b as typeof a;
      return a.validator === v.validator && a.slot === v.slot && a.head === v.head;
    }
    case "proposal": {
      const p = b as typeof a;
      return a.proposer === p.proposer && a.slot === p.slot;
    }
    case "attestation": {
      const t = b as typeof a;
      return a.validator === t.validator && a.slot === t.slot;
    }
  }
}

/**
 * Whether `selector` names the published message `message` (an exact
 * reference), given who published it and when: an exact selector matches
 * the identical reference, a proposal / attestation selector matches every
 * block / vote its sender published in its slot.
 */
export function coversMessage(
  selector: MessageRef,
  message: MessageRef,
  sender: ValidatorIndex,
  publishedAt: SlotIndex,
): boolean {
  switch (selector.kind) {
    case "block":
    case "vote":
      return sameRef(selector, message);
    case "proposal":
      return (
        message.kind === "block" &&
        sender === selector.proposer &&
        publishedAt === selector.slot
      );
    case "attestation":
      return (
        message.kind === "vote" &&
        message.validator === selector.validator &&
        message.slot === selector.slot
      );
  }
}

/** The slot a reference is published in, when the reference itself says so
 * (votes and ahead-of-publication references); a block index alone does not. */
export function refSlot(ref: MessageRef): SlotIndex | undefined {
  return ref.kind === "block" ? undefined : ref.slot;
}

/** The publisher a reference names, when the reference itself says so. */
export function refSender(ref: MessageRef): ValidatorIndex | undefined {
  switch (ref.kind) {
    case "block":
      return undefined;
    case "proposal":
      return ref.proposer;
    case "vote":
    case "attestation":
      return ref.validator;
  }
}
