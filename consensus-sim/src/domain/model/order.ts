// Total orders of the skeleton (骨格の規則). BlockIndex itself carries only
// identity; every tie the protocol has to break — between children in fork
// choice, between checkpoints of one epoch, between the two halves of an
// equivocation — is broken by the one order declared here, so the result
// never depends on message arrival (決定性).

import type { Checkpoint, Vote } from "./types";

/** The order on BlockIndex: ascending. The smaller index is preferred at
 * every tie. Negative when `a` is preferred. */
export function compareBlockIndex(a: number, b: number): number {
  return a - b;
}

/** Checkpoints order by epoch first (the later epoch is higher), then by
 * the block order (the preferred block is higher). Negative when `a` is
 * higher. */
export function compareCheckpoints(a: Checkpoint, b: Checkpoint): number {
  return b.epoch - a.epoch || compareBlockIndex(a.block, b.block);
}

export function sameCheckpoint(a: Checkpoint, b: Checkpoint): boolean {
  return a.epoch === b.epoch && a.block === b.block;
}

/** The higher of two checkpoints (`a` when they are equal). */
export function higherCheckpoint(a: Checkpoint, b: Checkpoint): Checkpoint {
  return compareCheckpoints(a, b) <= 0 ? a : b;
}

/** Identity of a checkpoint as a map key. */
export function checkpointKey(c: Checkpoint): string {
  return `${c.epoch}:${c.block}`;
}

/** Checkpoints in ascending order (the lower first): epoch, then block. */
function ascendingCheckpoints(a: Checkpoint, b: Checkpoint): number {
  return a.epoch - b.epoch || compareBlockIndex(a.block, b.block);
}

/** The content order on votes of one validator and slot: by head, then
 * source, then target — each ascending through the orders above. Negative
 * when `a` comes first. */
export function compareVoteContent(a: Vote, b: Vote): number {
  return (
    compareBlockIndex(a.head, b.head) ||
    ascendingCheckpoints(a.source, b.source) ||
    ascendingCheckpoints(a.target, b.target)
  );
}

/** The order on votes of one validator across slots: the earlier slot
 * first, then the content order. Negative when `a` comes first. */
export function compareVotes(a: Vote, b: Vote): number {
  return a.slot - b.slot || compareVoteContent(a, b);
}
