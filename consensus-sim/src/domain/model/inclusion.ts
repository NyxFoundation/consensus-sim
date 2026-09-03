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
import { checkpointKey, compareBlockIndex, compareVotes, sameCheckpoint } from "./order";
import {
  bodyOf,
  type BlockBody,
  type BlockIndex,
  type Equivocation,
  type SlotIndex,
  type ValidatorIndex,
  type Vote,
} from "./types";

/** Identity of a vote: same validator, slot and content. */
export function voteKey(vote: Vote): string {
  return `${vote.validator}@${vote.slot}:${vote.head}/${checkpointKey(vote.source)}/${checkpointKey(vote.target)}`;
}

export function sameVote(a: Vote, b: Vote): boolean {
  return voteKey(a) === voteKey(b);
}

/** Identity of evidence: its kind and the conflicting pair it names. */
export function equivocationKey(e: Equivocation): string {
  return e.kind === "double-proposal"
    ? `P${e.validator}@${e.slot}:${e.blocks[0]},${e.blocks[1]}`
    : `${e.kind === "double-vote" ? "V" : "S"}${voteKey(e.votes[0])}|${voteKey(e.votes[1])}`;
}

/** The validator the evidence is against (エクイボケータ). */
export function equivocatorOf(e: Equivocation): ValidatorIndex {
  return e.kind === "double-proposal" ? e.validator : e.votes[0].validator;
}

/** The slot the evidence arises in: the later of its two messages' slots
 * (the slot itself for the same-slot forms). */
export function evidenceSlotOf(e: Equivocation): SlotIndex {
  return e.kind === "double-proposal" ? e.slot : e.votes[1].slot;
}

/**
 * The form in which two votes of one validator conflict, if they do (the
 * vote forms of `Equivocation`): a double vote when they share a slot with
 * different content, or share the target epoch with different targets; a
 * surround vote when the later vote's source → target span strictly encloses
 * the earlier one's in epochs. `a` must precede `b` in the vote order.
 */
export function voteConflict(a: Vote, b: Vote): "double-vote" | "surround-vote" | undefined {
  if (a.slot === b.slot) return sameVote(a, b) ? undefined : "double-vote";
  if (a.target.epoch === b.target.epoch) {
    return sameCheckpoint(a.target, b.target) ? undefined : "double-vote";
  }
  return b.source.epoch < a.source.epoch &&
    a.source.epoch < a.target.epoch &&
    a.target.epoch < b.target.epoch
    ? "surround-vote"
    : undefined;
}

/**
 * The votes of one validator that stand for its distinct FFG parts, and the
 * distinct votes of each slot: the same (source, target) cast again in a
 * later slot — how an honest validator votes through an epoch — conflicts
 * with nothing new, so evidence across slots is drawn between the earliest
 * vote of each FFG part only, while a slot's own conflicting votes are
 * evidence pair by pair.
 */
function conflictCandidates(votes: readonly Vote[]): {
  readonly bySlot: ReadonlyMap<SlotIndex, readonly Vote[]>;
  readonly byFfg: readonly Vote[];
} {
  const sorted = [...votes].sort(compareVotes);
  const bySlot = new Map<SlotIndex, Vote[]>();
  const byFfg = new Map<string, Vote>();
  for (const vote of sorted) {
    const list = bySlot.get(vote.slot) ?? [];
    if (list.some((v) => sameVote(v, vote))) continue;
    list.push(vote);
    bySlot.set(vote.slot, list);
    const ffg = `${checkpointKey(vote.source)}->${checkpointKey(vote.target)}`;
    if (!byFfg.has(ffg)) byFfg.set(ffg, vote);
  }
  return { bySlot, byFfg: [...byFfg.values()] };
}

type VoteEvidence = Extract<Equivocation, { readonly votes: unknown }>;

/** Every conflicting pair among one validator's votes, in canonical order. */
function voteEquivocations(votes: readonly Vote[]): VoteEvidence[] {
  const found: VoteEvidence[] = [];
  const { bySlot, byFfg } = conflictCandidates(votes);
  for (const list of bySlot.values()) {
    for (let i = 0; i < list.length; i++) {
      for (let j = i + 1; j < list.length; j++) {
        found.push({ kind: "double-vote", votes: [list[i]!, list[j]!] });
      }
    }
  }
  for (let i = 0; i < byFfg.length; i++) {
    for (let j = i + 1; j < byFfg.length; j++) {
      const a = byFfg[i]!;
      const b = byFfg[j]!;
      if (a.slot === b.slot) continue;
      const kind = voteConflict(a, b);
      if (kind !== undefined) found.push({ kind, votes: [a, b] });
    }
  }
  return found.sort(
    (x, y) => compareVotes(x.votes[1], y.votes[1]) || compareVotes(x.votes[0], y.votes[0]),
  );
}

/** Votes grouped by validator, in validator order. */
function votesByValidator(votes: readonly Vote[]): readonly (readonly Vote[])[] {
  const by = new Map<ValidatorIndex, Vote[]>();
  for (const vote of votes) by.set(vote.validator, [...(by.get(vote.validator) ?? []), vote]);
  return [...by.entries()].sort(([a], [b]) => a - b).map(([, list]) => list);
}

/**
 * Every equivocation visible in a view: two blocks of one proposer in one
 * slot, and every conflicting pair of one validator's votes (double votes
 * and surround votes). A validator with three conflicting messages yields
 * evidence per pair, all in a deterministic order.
 */
export function equivocationsIn(
  tree: BlockTree,
  votes: readonly Vote[],
): Equivocation[] {
  const found: Equivocation[] = [];

  const blocksBy = new Map<string, BlockIndex[]>();
  for (const block of tree.blocks.values()) {
    if (block.kind !== "proposed") continue;
    const key = `${block.proposer}@${block.slot}`;
    blocksBy.set(key, [...(blocksBy.get(key) ?? []), block.index]);
  }
  for (const [key, indices] of [...blocksBy.entries()].sort()) {
    if (indices.length < 2) continue;
    const [validator, slot] = key.split("@").map(Number) as [number, number];
    const sorted = [...indices].sort(compareBlockIndex);
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

  for (const list of votesByValidator(votes)) found.push(...voteEquivocations(list));
  return found;
}

/**
 * Validators whose vote evidence (a double vote or a surround vote) holds
 * among `votes` — the equivocation discount (エクイボケーション割引, 必須
 * 27) drops their votes from fork choice the moment a view holds the
 * conflicting pair: immediate, local to that view, and fork choice only
 * (chain state is untouched until a block includes the evidence).
 */
export function equivocatingVoters(
  votes: readonly Vote[],
): ReadonlySet<ValidatorIndex> {
  const found = new Set<ValidatorIndex>();
  for (const list of votesByValidator(votes)) {
    if (voteEquivocations(list).length > 0) found.add(list[0]!.validator);
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
    const body = bodyOf(b);
    for (const v of body.votes) votes.add(voteKey(v));
    for (const e of body.evidence) evidence.add(equivocationKey(e));
  }
  return { votes, evidence };
}

/** Names evidence by the equivocator, the kind and the slot it arises in —
 * every pair of that validator's conflicting messages of that kind whose
 * later message is of that slot. */
export interface EvidenceRef {
  readonly kind: Equivocation["kind"];
  readonly validator: ValidatorIndex;
  readonly slot: SlotIndex;
}

export const evidenceRef = (e: Equivocation): EvidenceRef => ({
  kind: e.kind,
  validator: equivocatorOf(e),
  slot: evidenceSlotOf(e),
});

export function sameEvidenceRef(a: EvidenceRef, b: EvidenceRef): boolean {
  return a.kind === b.kind && a.validator === b.validator && a.slot === b.slot;
}

/** Items a proposer deliberately leaves out (取り込みの省略): votes by
 * message reference (exact, or every vote of a validator in a slot),
 * evidence by equivocator / kind / slot. */
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
    if (omit.votes?.some((r) => coversMessage(r, voteRef(vote)))) continue;
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
