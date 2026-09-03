// Local view (局所視点) — what one validator has observed at one instant,
// computed as a pure filter over the message log. The default delivery is
// instant broadcast, so with no interventions every local view equals the
// god view; partitions, delays and drops (introduced later as interventions)
// are stricter Delivery rules, not engine changes.

import { addBlock, createBlockTree, type BlockTree } from "../model/blockTree";
import type { ChainState } from "../model/chainState";
import type { SimulationConfig } from "../model/config";
import type { MessageRef } from "../model/messageRef";
import {
  refOfBlock,
  refOfVote,
  senderOfBlock,
  senderOfVote,
  type MessageLog,
  type PublishedBlock,
} from "./messages";
import { resolveView } from "../model/protocol";
import type { BlockIndex, SlotIndex, ValidatorIndex } from "../model/types";
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
 * `observer`'s view at the end of `slot` (reference type View). `votesThrough`
 * lets the protocol cut vote visibility earlier than block visibility: an
 * attester at slot s acts on blocks through s but votes through s-1, so all
 * attestations of a slot are simultaneous and order-independent.
 */
export function viewOf(
  log: MessageLog,
  observer: ValidatorIndex,
  slot: SlotIndex,
  delivery: Delivery = instantDelivery,
  votesThrough: SlotIndex = slot,
): View {
  const blocks = log.blocks.filter(
    (m) =>
      m.publishedAt <= slot &&
      delivery(senderOfBlock(m), m.publishedAt, observer, slot, refOfBlock(m)),
  );
  const votes = log.votes
    .filter(
      (m) =>
        m.publishedAt <= votesThrough &&
        delivery(senderOfVote(m), m.publishedAt, observer, slot, refOfVote(m)),
    )
    .map((m) => m.vote);
  return { validator: observer, slot, blockTree: visibleTree(blocks), votes };
}

/**
 * What a validator knows at one instant, bundled for observation: its view,
 * its fork-choice head, and the chain state of that head — which is what the
 * view's justified / finalized / stakes mean.
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
  config: SimulationConfig,
  delivery: Delivery = instantDelivery,
): LocalObservation {
  const view = viewOf(log, observer, slot, delivery);
  const { head, chainState } = resolveView(view, config);
  return { view, head, chainState };
}
