// Message log — everything ever published, with publication metadata.
// Local views (局所視点) are pure filters over this log; the log itself is
// the god view's (神視点) source of truth and is append-only, so rewind can
// re-derive any past view.

import type { Block, SlotIndex, ValidatorIndex, Vote } from "./types";

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
