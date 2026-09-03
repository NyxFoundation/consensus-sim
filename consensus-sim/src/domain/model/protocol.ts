// Protocol skeleton (簡約プロトコル骨格) — how a proposal is built (parent by
// fork choice, body by inclusion), how an attester votes, and how a view is
// resolved into a head under the protocol parameters. Pure functions over a
// view; the simulation driver decides when they run, and schedule.ts says
// who (proposer, committee).
//
// Fork choice reads the message layer (the view's votes); the checkpoints a
// vote carries read the chain-state layer (the head's ChainState).

import { type BlockTree } from "./blockTree";
import {
  chainStatesOf,
  forkChoiceRoot,
  viableBlocks,
  type ChainState,
  type ChainStateIndex,
} from "./chainState";
import type { InitialConditions } from "./initialConditions";
import { checkpointFor, epochOf } from "./finality";
import { ghostHead, type ForkChoiceWeights } from "./forkChoice";
import { buildBody, equivocatingVoters, type Omission } from "./inclusion";
import { compareBlockIndex, compareVoteContent } from "./order";
import { proposerForSlot, type Schedule } from "./schedule";
import {
  type BlockIndex,
  type Checkpoint,
  type ProposedBlock,
  type SlotIndex,
  type Stake,
  type ValidatorIndex,
  type Vote,
} from "./types";
import type { View } from "./view";

/** What a validator concludes from its view: chain states, root and head. */
export interface Resolution {
  readonly states: ChainStateIndex;
  /** The justified checkpoint fork choice started from. */
  readonly root: Checkpoint;
  readonly head: BlockIndex;
  /** ChainState(head) — the view's justified / finalized / stakes. */
  readonly chainState: ChainState;
  /** The weights this fork choice ran with (stakes and any proposer boost). */
  readonly weights: ForkChoiceWeights;
}

/**
 * The block that receives the proposer boost in a fork choice run at
 * `atSlot` over `view`: the proposal of `atSlot`'s scheduled proposer that
 * the view holds — received during the slot it was proposed in. A proposal
 * that arrives later (delay) belongs to an earlier slot and never qualifies;
 * under a double proposal the smaller index counts as the one received first.
 */
export function boostedBlock(
  view: View,
  atSlot: SlotIndex,
  config: InitialConditions,
): BlockIndex | undefined {
  if (config.params.boost <= 0) return undefined;
  const proposer = proposerForSlot(atSlot, config);
  let boosted: BlockIndex | undefined;
  for (const block of view.blockTree.blocks.values()) {
    if (block.kind !== "proposed" || block.slot !== atSlot || block.proposer !== proposer) {
      continue;
    }
    if (boosted === undefined || compareBlockIndex(block.index, boosted) < 0) {
      boosted = block.index;
    }
  }
  return boosted;
}

/** Total stake of `slot`'s committee in `stakes`. */
export function committeeWeight(
  slot: SlotIndex,
  schedule: Schedule,
  stakes: ReadonlyMap<ValidatorIndex, Stake>,
): Stake {
  let total = 0;
  for (const v of schedule.committeeOf(slot)) total += stakes.get(v) ?? 0;
  return total;
}

/**
 * Run chain-state derivation and fork choice over a view, as a fork choice
 * computed at `atSlot` (the slot the validator acts in — a proposer acts at
 * its own slot on its view of the slots before it). A vote weighs the
 * voter's stake in the chain state of the head it votes for (ESSENCE 必須
 * 25: a validator's weight is its stake in its head's chain state), so a
 * penalty included on a branch bites exactly there; the timely proposal of
 * `atSlot` gets its committee's weight × boost on top. The mitigations
 * (緩和策, 必須 27) apply here: the fork-choice rule picks the counted
 * votes, the equivocation discount zeroes a voter whose vote evidence this
 * view holds, and the two checkpoint-switching switches choose the root
 * (window) and prune the candidates (unrealized), independently.
 */
export function resolveView(
  view: View,
  config: InitialConditions,
  schedule: Schedule,
  atSlot: SlotIndex,
): Resolution {
  const { params } = config;
  const states = chainStatesOf(view.blockTree, config);
  const root = forkChoiceRoot(view.blockTree, states, params.checkpointSwitch, atSlot);
  const discounted = params.equivocationDiscount
    ? equivocatingVoters(view.votes)
    : undefined;
  const weightOf = (vote: Vote): Stake =>
    discounted?.has(vote.validator)
      ? 0
      : (states.get(vote.head)?.stakes.get(vote.validator) ?? 0);
  const boosted = boostedBlock(view, atSlot, config);
  const weights: ForkChoiceWeights = {
    weightOf,
    boost:
      boosted === undefined
        ? undefined
        : {
            block: boosted,
            weight:
              committeeWeight(atSlot, schedule, states.get(boosted)!.stakes) *
              config.params.boost,
          },
  };
  const head = ghostHead(view.blockTree, view.votes, root.block, {
    weights,
    rule: params.forkChoice,
    candidates: params.checkpointSwitch.unrealized
      ? viableBlocks(view.blockTree, states, root)
      : undefined,
  });
  return { states, root, head, chainState: states.get(head)!, weights };
}

/**
 * Build the block a proposer publishes at `slot`: parent = its fork-choice
 * head (or `parent` when designated and visible — フォーク作成), body = the
 * honest inclusion of everything unincluded on that branch minus `omit`.
 * `index` is assigned by the caller (the simulation keeps the next free one).
 */
export function buildProposal(
  view: View,
  resolution: Resolution,
  slot: SlotIndex,
  proposer: ValidatorIndex,
  index: BlockIndex,
  parent: BlockIndex = resolution.head,
  omit: Omission = {},
): ProposedBlock {
  const tree: BlockTree = view.blockTree;
  const chosen = tree.blocks.has(parent) ? parent : resolution.head;
  return {
    kind: "proposed",
    index,
    parent: chosen,
    slot,
    proposer,
    body: buildBody(tree, view.votes, chosen, omit),
  };
}

/**
 * The FFG part a validator settled on for `epoch`, if it has voted in that
 * epoch already: the (source, target) of its first vote of the epoch in the
 * view (the earliest slot; under a double vote, the content order breaks
 * the tie).
 */
function ffgSettledIn(
  view: View,
  validator: ValidatorIndex,
  epoch: number,
): Pick<Vote, "source" | "target"> | undefined {
  let first: Vote | undefined;
  for (const vote of view.votes) {
    if (vote.validator !== validator || epochOf(vote.slot) !== epoch) continue;
    if (
      first === undefined ||
      vote.slot < first.slot ||
      (vote.slot === first.slot && compareVoteContent(vote, first) < 0)
    ) {
      first = vote;
    }
  }
  return first === undefined ? undefined : { source: first.source, target: first.target };
}

/**
 * The vote an attester casts at `slot` from its view. The head follows fork
 * choice every slot (the LMD part); the FFG part (source, target) is
 * decided once per epoch: in the first slot the validator votes in during
 * the epoch it is read off the head's chain — source = the justified
 * checkpoint of the head's chain state, target = the epoch's checkpoint on
 * the head's chain — and every later vote of the same epoch repeats it (an
 * honest validator never contradicts its own FFG vote, as Ethereum attests
 * once per epoch). `override` (投票先指定) replaces any of the three: a
 * designated head (a block of the view) moves a freshly decided FFG part
 * onto its chain; a designated target is a block of the view standing as
 * the checkpoint of the slot's epoch (the epoch follows from the slot); a
 * designated source is a checkpoint of a branch of the view — a designated
 * FFG part that differs from the one already cast this epoch is evidence.
 * A designation the view does not hold is ignored.
 */
export function buildAttestation(
  view: View,
  resolution: Resolution,
  slot: SlotIndex,
  validator: ValidatorIndex,
  override: VoteOverride = {},
): Vote {
  const tree = view.blockTree;
  const known = (b: BlockIndex | undefined): BlockIndex | undefined =>
    b !== undefined && tree.blocks.has(b) ? b : undefined;
  const head = known(override.head) ?? resolution.head;
  const epoch = epochOf(slot);
  const settled = ffgSettledIn(view, validator, epoch);
  const source =
    override.source !== undefined && known(override.source.block) !== undefined
      ? override.source
      : (settled?.source ?? resolution.states.get(head)!.justified);
  const designatedTarget = known(override.target);
  const target =
    designatedTarget !== undefined
      ? { epoch, block: designatedTarget }
      : (settled?.target ?? checkpointFor(tree, head, epoch));
  return { validator, slot, head, source, target };
}

/** 投票先指定: what an attester's vote is steered to, each optional — the
 * head and target among the blocks of its view, the source among the
 * checkpoints of a branch of its view. */
export interface VoteOverride {
  readonly head?: BlockIndex | undefined;
  readonly source?: Checkpoint | undefined;
  readonly target?: BlockIndex | undefined;
}

/**
 * The second vote of a double vote (二重投票): same validator and slot as the
 * primary, endorsing `head` when it is designated, held by the view and
 * differs from the primary head, otherwise the primary head's parent —
 * deterministic, and a genuine equivocation whenever the two heads differ.
 * The target is the epoch's checkpoint on the alternative head's chain; the
 * source stays the primary's (the justified checkpoint the validator votes
 * from). Returns undefined when no distinct alternative exists (primary
 * head = anchor and nothing designated).
 */
export function buildEquivocalAttestation(
  tree: BlockTree,
  primary: Vote,
  head?: BlockIndex,
): Vote | undefined {
  const headBlock = tree.blocks.get(primary.head);
  if (headBlock === undefined) return undefined;
  const designated =
    head !== undefined && head !== primary.head && tree.blocks.has(head) ? head : undefined;
  if (designated === undefined && headBlock.kind === "anchor") return undefined;
  const altHead = designated ?? (headBlock as ProposedBlock).parent;
  return {
    validator: primary.validator,
    slot: primary.slot,
    head: altHead,
    source: primary.source,
    target: checkpointFor(tree, altHead, epochOf(primary.slot)),
  };
}
