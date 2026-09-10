// Local view (局所視点) — what one validator has observed at one instant,
// computed as a pure filter over the message log. The default delivery is
// instant broadcast, so with no interventions every local view equals the
// god view; partitions, delays and drops (introduced later as interventions)
// are stricter Delivery rules, not engine changes.

import { addBlock, createBlockTree, type BlockTree } from "../model/blockTree";
import type { ChainState } from "../model/chainState";
import type { InitialConditions } from "../model/initialConditions";
import { blockRef, voteRef, type MessageRef } from "../model/messageRef";
import type { MessageLog, PublishedBlock } from "./messages";
import { resolveView } from "../model/protocol";
import { scheduleOf } from "./schedule";
import { atEnd, type BlockIndex, type Instant, type SlotIndex, type ValidatorIndex } from "../model/types";
import type { View } from "../model/view";

/**
 * Whether a message published by `sender` at `publishedAt` has reached
 * `observer` by `atSlot`. Must be a pure function of its arguments so that
 * views stay recomputable (決定性). `message` identifies the concrete
 * message, so a rule can target one specifically (遅延・欠落); rules that
 * only depend on sender/observer/time may simply ignore it.
 */
export type Delivery = (
  sender: ValidatorIndex,
  publishedAt: SlotIndex,
  observer: ValidatorIndex,
  atSlot: SlotIndex,
  message: MessageRef,
) => boolean;

/** Instant broadcast: everything published up to `atSlot` is visible. */
export const instantDelivery: Delivery = (_sender, publishedAt, _observer, atSlot) =>
  publishedAt <= atSlot;

/**
 * The blocks of `observer`'s view: visible blocks inserted in ascending
 * (slot, index) order. A block whose parent is not visible is skipped —
 * together with its descendants — until the parent arrives.
 */
function visibleTree(
  visible: readonly PublishedBlock[],
): BlockTree {
  const ordered = [...visible].sort(
    (a, b) => a.block.slot - b.block.slot || a.block.index - b.block.index,
  );
  let tree = createBlockTree();
  for (const { block } of ordered) {
    if (!tree.blocks.has(block.parent)) continue;
    tree = addBlock(tree, block);
  }
  return tree;
}

/**
 * `observer`'s view at `instant` (reference type View; the observer and the
 * instant are its coordinates). Blocks are published at the proposal
 * instant and votes at the vote instant, and each shows up from the next
 * instant on: at (s, proposal) the view holds everything through the end
 * of s−1; at (s, vote) also the blocks of s — so the timely proposal is
 * there to vote on — but still only the votes through s−1, so every
 * attester of a slot votes simultaneously and order-independently; at
 * (s, end) everything through s. Delivery decides what has arrived.
 */
export function viewOf(
  log: MessageLog,
  observer: ValidatorIndex,
  instant: Instant,
  delivery: Delivery = instantDelivery,
): View {
  const { slot, phase } = instant;
  const arrivedBy = phase === "proposal" ? slot - 1 : slot;
  const votesThrough = phase === "end" ? slot : slot - 1;
  const blocks = log.blocks.filter(
    (m) =>
      m.publishedAt <= arrivedBy &&
      delivery(m.block.proposer, m.publishedAt, observer, arrivedBy, blockRef(m.block)),
  );
  const votes = log.votes
    .filter(
      (m) =>
        m.publishedAt <= votesThrough &&
        delivery(m.vote.validator, m.publishedAt, observer, arrivedBy, voteRef(m.vote)),
    )
    .map((m) => m.vote);
  return { blockTree: visibleTree(blocks), votes };
}

/**
 * What a validator knows at the end of `slot`, bundled for observation: its
 * view, its fork-choice head, and the chain state of that head — which is
 * what the view's justified / finalized / stakes mean.
 */
export interface LocalObservation {
  readonly view: View;
  readonly head: BlockIndex;
  readonly chainState: ChainState;
}

export function observe(
  log: MessageLog,
  observer: ValidatorIndex,
  slot: SlotIndex,
  config: InitialConditions,
  delivery: Delivery = instantDelivery,
): LocalObservation {
  const view = viewOf(log, observer, atEnd(slot), delivery);
  const { head, chainState } = resolveView(view, config, scheduleOf(config), slot);
  return { view, head, chainState };
}
