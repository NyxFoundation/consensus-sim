// 取り込み — プロポーザーがどうブロック body を満たすか、そ
// してエクイボケーションの証拠がどう生じるか。View に対する純粋
// 関数群。
//
// ルール(ESSENCE.md): 正直なプロポーザーは、提案する parent のどの祖先
// もまだ取り込んでいない、自身の View 上のすべての投票とすべての証拠を取
// り込む。取り込み期限は存在しない: 抽象モデルが保つのは「この枝上
// でまだ取り込まれていない」という状態のみである。戦略や取り込みの省略の
// 介入は項目を除外してよい。

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

/** 投票の同一性: 同じバリデータ・スロット・内容。 */
export function voteKey(vote: Vote): string {
  return `${vote.validator}@${vote.slot}:${vote.head}/${checkpointKey(vote.source)}/${checkpointKey(vote.target)}`;
}

export function sameVote(a: Vote, b: Vote): boolean {
  return voteKey(a) === voteKey(b);
}

/** 証拠の同一性: その種別と、それが名指しする矛盾するペア。 */
export function equivocationKey(e: Equivocation): string {
  return e.kind === "double-proposal"
    ? `P${e.validator}@${e.slot}:${e.blocks[0]},${e.blocks[1]}`
    : `${e.kind === "double-vote" ? "V" : "S"}${voteKey(e.votes[0])}|${voteKey(e.votes[1])}`;
}

/** その証拠が対象とするバリデータ(エクイボケータ)。 */
export function equivocatorOf(e: Equivocation): ValidatorIndex {
  return e.kind === "double-proposal" ? e.validator : e.votes[0].validator;
}

/** その証拠が生じるスロット: 2 つのメッセージのうち後の方のスロット
 * (同一スロット形式ではそのスロット自身)。 */
export function evidenceSlotOf(e: Equivocation): SlotIndex {
  return e.kind === "double-proposal" ? e.slot : e.votes[1].slot;
}

/**
 * 1 人のバリデータの 2 つの投票が矛盾する場合、その形式(`Equivocation`
 * の投票側の形式): 同じスロットで内容が異なれば 二重投票、同じ
 * target の epoch で target が異なれば 二重投票、後の投票の source →
 * target の区間が epoch において前の投票の区間を厳密に包含するなら
 * 包囲投票。`a` は投票順序で `b` より前でなければならない。
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
 * あるバリデータについて、異なる FFG 部分を代表する各投票と、各スロット
 * 内で異なる投票: 同じ (source, target) を後のスロットで再び投じること
 * (正直バリデータが epoch を通じてどう投票するか)は何も新しく矛盾させ
 * ないため、スロットをまたぐ証拠は各 FFG 部分の最も早い投票同士でのみ抽
 * 出し、あるスロット自身の中で矛盾する投票はペアごとに証拠とする。
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

/** あるバリデータの投票の中で矛盾するすべてのペアを、正準順序で。 */
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

/** バリデータ順に、バリデータごとにまとめた投票。 */
function votesByValidator(votes: readonly Vote[]): readonly (readonly Vote[])[] {
  const by = new Map<ValidatorIndex, Vote[]>();
  for (const vote of votes) by.set(vote.validator, [...(by.get(vote.validator) ?? []), vote]);
  return [...by.entries()].sort(([a], [b]) => a - b).map(([, list]) => list);
}

/**
 * View 内で確認できるすべてのエクイボケーション: 同じスロットにおける同
 * じプロポーザーの 2 つのブロック、およびあるバリデータの投票の中で矛盾
 * するすべてのペア(二重投票 と 包囲投票)。矛盾するメッセージを
 * 3 つ持つバリデータはペアごとに証拠を生み、すべて決定的な順序に並ぶ。
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
 * `votes` の中で投票の証拠(二重投票 または 包囲投票)が成立する
 * バリデータ — エクイボケーション割引(必須 27)は、View が矛盾するペア
 * を保持した瞬間にその投票を fork choice から除外する: 即座に、その
 * View に局所的に、かつ fork choice にのみ働く(チェーン状態 は、ブロック
 * が証拠を取り込むまでは影響を受けない)。
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

/** 錨ブロックから `block` までの枝上に取り込まれたすべてのもののキー。 */
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

/** 証拠を、エクイボケータ・種別・それが生じるスロットで名指しする — 後
 * の方のメッセージがそのスロットである、そのバリデータのその種別の矛盾
 * するメッセージのすべてのペアを指す。 */
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

/** プロポーザーが意図的に除外する項目(取り込みの省略): メッセージ参照
 * による投票(厳密な参照、またはあるバリデータのあるスロットのすべての
 * 投票)、エクイボケータ／種別／スロットによる証拠。 */
export interface Omission {
  readonly votes?: readonly MessageRef[];
  readonly evidence?: readonly EvidenceRef[];
}

/**
 * 正直なプロポーザーがその View から `parent` の上に構築する body: parent
 * の枝にまだ取り込まれていない、すべての可視な投票と証拠から、明
 * 示的な省略を除いたもの。投票は View の順序を保ち、証拠は正準順序とす
 * る。
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
