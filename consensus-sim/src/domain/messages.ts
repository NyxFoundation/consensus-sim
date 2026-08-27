// Message log — everything ever published, with publication metadata.
// Local views (局所視点) are pure filters over this log; the log itself is
// the god view's (神視点) source of truth and is append-only, so rewind can
// re-derive any past view.

import type {
  Block,
  BlockIndex,
  SlotIndex,
  ValidatorIndex,
  Vote,
} from "./types";

export interface PublishedBlock {
  readonly block: Block;
  /** Slot at which the proposer published this block (= block.slot here). */
  readonly publishedAt: SlotIndex;
}

export interface PublishedVote {
  readonly vote: Vote;
  /** Slot at which the voter published this vote (= vote.slot here). */
  readonly publishedAt: SlotIndex;
}

export interface MessageLog {
  readonly blocks: readonly PublishedBlock[];
  readonly votes: readonly PublishedVote[];
}

export const senderOfBlock = (m: PublishedBlock): ValidatorIndex =>
  m.block.proposer;
export const senderOfVote = (m: PublishedVote): ValidatorIndex =>
  m.vote.validator;

/**
 * Identity of a single published message, so a delivery rule can target one
 * message specifically (遅延・欠落). A block is unique by index; a vote is
 * identified by (validator, slot, head) — under equivocation the two votes of
 * one validator in one slot differ in head, so each stays addressable.
 */
export type MessageRef =
  | { readonly kind: "block"; readonly block: BlockIndex }
  | {
      readonly kind: "vote";
      readonly validator: ValidatorIndex;
      readonly slot: SlotIndex;
      readonly head: BlockIndex;
    };

export const refOfBlock = (m: PublishedBlock): MessageRef => ({
  kind: "block",
  block: m.block.index,
});

export const refOfVote = (m: PublishedVote): MessageRef => ({
  kind: "vote",
  validator: m.vote.validator,
  slot: m.vote.slot,
  head: m.vote.head,
});

export function sameRef(a: MessageRef, b: MessageRef): boolean {
  if (a.kind === "block" && b.kind === "block") return a.block === b.block;
  if (a.kind === "vote" && b.kind === "vote") {
    return a.validator === b.validator && a.slot === b.slot && a.head === b.head;
  }
  return false;
}

export function emptyLog(): MessageLog {
  return { blocks: [], votes: [] };
}

export function publishBlock(
  log: MessageLog,
  block: Block,
  publishedAt: SlotIndex,
): MessageLog {
  return { blocks: [...log.blocks, { block, publishedAt }], votes: log.votes };
}

export function publishVotes(
  log: MessageLog,
  votes: readonly Vote[],
  publishedAt: SlotIndex,
): MessageLog {
  return {
    blocks: log.blocks,
    votes: [...log.votes, ...votes.map((vote) => ({ vote, publishedAt }))],
  };
}
