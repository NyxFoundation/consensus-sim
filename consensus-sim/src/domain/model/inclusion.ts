// Inclusion (取り込み) — how a proposer fills a block body, and how evidence
// (証拠) of equivocation arises. Pure functions over a view.
//
// Rule (ESSENCE.md): an honest proposer includes every vote and every piece
// of evidence in its view that no ancestor of the proposed parent has
// included yet. There is no inclusion deadline: the abstract model keeps
// only "not yet included on this branch". Strategies and the 取り込みの省略
// intervention may leave items out.

import { pathToAnchor, type BlockTree } from "./blockTree";
import { coversMessage, voteRef, type MessageRef } from "./messageRef";
import type {
  BlockBody,
  BlockIndex,
  Equivocation,
  SlotIndex,
  ValidatorIndex,
  Vote,
} from "./types";

/** Identity of a vote: same validator, slot and content. */
export function voteKey(vote: Vote): string {
  return `${vote.validator}@${vote.slot}:${vote.head}/${vote.source}/${vote.target}`;
}

export function sameVote(a: Vote, b: Vote): boolean {
  return voteKey(a) === voteKey(b);
}

/** Identity of evidence: the conflicting pair it names. */
export function equivocationKey(e: Equivocation): string {
  return e.kind === "double-proposal"
    ? `P${e.validator}@${e.slot}:${e.blocks[0]},${e.blocks[1]}`
    : `V${e.validator}@${e.slot}:${voteKey(e.votes[0])}|${voteKey(e.votes[1])}`;
}

const voteOrder = (a: Vote, b: Vote): number =>
  a.head - b.head || a.source - b.source || a.target - b.target;

/**
 * Every equivocation visible in a view: two blocks of one proposer in one
 * slot, or two content-different votes of one validator in one slot. A
 * validator with three conflicting messages yields evidence per pair, all
 * in a deterministic order.
 */
export function equivocationsIn(
  tree: BlockTree,
  votes: readonly Vote[],
): Equivocation[] {
  const found: Equivocation[] = [];

  const blocksBy = new Map<string, BlockIndex[]>();
  for (const block of tree.blocks.values()) {
    if (block.proposer < 0) continue;
    const key = `${block.proposer}@${block.slot}`;
    blocksBy.set(key, [...(blocksBy.get(key) ?? []), block.index]);
  }
  for (const [key, indices] of [...blocksBy.entries()].sort()) {
    if (indices.length < 2) continue;
    const [validator, slot] = key.split("@").map(Number) as [number, number];
    const sorted = [...indices].sort((a, b) => a - b);
    for (let i = 0; i < sorted.length; i++) {
      for (let j = i + 1; j < sorted.length; j++) {
        found.push({
          kind: "double-proposal",
          validator,
          slot,
          blocks: [sorted[i]!, sorted[j]!],
        });
      }
    }
  }

  const votesBy = new Map<string, Vote[]>();
  for (const vote of votes) {
    const key = `${vote.validator}@${vote.slot}`;
    const list = votesBy.get(key) ?? [];
    if (!list.some((v) => sameVote(v, vote))) list.push(vote);
    votesBy.set(key, list);
  }
  for (const [key, list] of [...votesBy.entries()].sort()) {
    if (list.length < 2) continue;
    const [validator, slot] = key.split("@").map(Number) as [number, number];
    const sorted = [...list].sort(voteOrder);
    for (let i = 0; i < sorted.length; i++) {
      for (let j = i + 1; j < sorted.length; j++) {
        found.push({
          kind: "double-vote",
          validator,
          slot,
          votes: [sorted[i]!, sorted[j]!],
        });
      }
    }
  }
  return found;
}

/**
 * Validators seen casting two content-different votes in one slot — the
 * equivocation discount (エクイボケーション割引, 必須 27) drops their votes
 * from fork choice the moment a view holds the conflicting pair: immediate,
 * local to that view, and fork choice only (chain state is untouched until a
 * block includes the evidence).
 */
export function equivocatingVoters(
  votes: readonly Vote[],
): ReadonlySet<ValidatorIndex> {
  const first = new Map<string, Vote>();
  const found = new Set<ValidatorIndex>();
  for (const vote of votes) {
    const key = `${vote.validator}@${vote.slot}`;
    const seen = first.get(key);
    if (seen === undefined) first.set(key, vote);
    else if (!sameVote(seen, vote)) found.add(vote.validator);
  }
  return found;
}

/** Keys of everything included on the branch from the anchor to `block`. */
export function includedOn(
  tree: BlockTree,
  block: BlockIndex,
): { readonly votes: ReadonlySet<string>; readonly evidence: ReadonlySet<string> } {
  const votes = new Set<string>();
  const evidence = new Set<string>();
  for (const b of pathToAnchor(tree, block)) {
    for (const v of b.body.votes) votes.add(voteKey(v));
    for (const e of b.body.evidence) evidence.add(equivocationKey(e));
  }
  return { votes, evidence };
}

/** Names evidence by the equivocator, the slot and the kind — every pair of
 * that validator's conflicting messages in that slot. */
export interface EvidenceRef {
  readonly kind: Equivocation["kind"];
  readonly validator: ValidatorIndex;
  readonly slot: SlotIndex;
}

export const evidenceRef = (e: Equivocation): EvidenceRef => ({
  kind: e.kind,
  validator: e.validator,
  slot: e.slot,
});

export function sameEvidenceRef(a: EvidenceRef, b: EvidenceRef): boolean {
  return a.kind === b.kind && a.validator === b.validator && a.slot === b.slot;
}

/** Items a proposer deliberately leaves out (取り込みの省略): votes by
 * message reference (exact, or every attestation of a validator in a slot),
 * evidence by equivocator / slot / kind. */
export interface Omission {
  readonly votes?: readonly MessageRef[];
  readonly evidence?: readonly EvidenceRef[];
}

/**
 * The body an honest proposer builds on `parent` from its view: all visible
 * votes and evidence not yet included on the parent's branch, minus any
 * explicit omission. Votes keep view order; evidence is canonical.
 */
export function buildBody(
  tree: BlockTree,
  votes: readonly Vote[],
  parent: BlockIndex,
  omit: Omission = {},
): BlockBody {
  const already = includedOn(tree, parent);
  const seen = new Set<string>();
  const bodyVotes: Vote[] = [];
  for (const vote of votes) {
    const key = voteKey(vote);
    if (already.votes.has(key) || seen.has(key)) continue;
    if (
      omit.votes?.some((r) => coversMessage(r, voteRef(vote), vote.validator, vote.slot))
    ) {
      continue;
    }
    seen.add(key);
    bodyVotes.push(vote);
  }
  const bodyEvidence = equivocationsIn(tree, votes).filter(
    (e) =>
      !already.evidence.has(equivocationKey(e)) &&
      !omit.evidence?.some((r) => sameEvidenceRef(r, evidenceRef(e))),
  );
  return { votes: bodyVotes, evidence: bodyEvidence };
}
