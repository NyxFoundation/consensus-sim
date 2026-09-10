// 攻撃ライブラリの戦略 — 形式体系の具体的攻撃であり、攻撃ごとに Strategy と
// Attack の三つ組を 1 つずつ持つ。戦略とは、攻撃者の観測から先のスロットの
// 行動への純粋な規則である(attack.ts)。最初の境界で一度だけ発する固定の
// 介入列は、戦略の特殊ケースとして ESSENCE が名指すものである。
//
// これらが model モジュールに置かれるのは、戦略と攻撃の三つ組が本質的仕様の
// 一部 — 攻撃体系の Lean 形式化がそのまま対象とする定義 — だからである。
// ライブラリのメタデータと既定実行構成(シミュレータの実行上の関心事)は
// sim/attackLibrary.ts に置く。
//
// 各戦略はその攻撃が宣言する前提と既定実行構成に合わせて調整してある。
// バリデータ集合はラウンドロビン(スロット s のプロポーザーは s mod n)で、
// 正直チェーンは線形なので、ブロック B_k はスロット k に位置する。各コメントは
// その攻撃が再現する仕組みを述べる(ESSENCE 思想: 本質さえ再現できれば
// 縮約版で十分)。

import type { Action } from "./action";
import type { Attack, AttackerObservation, Strategy } from "./attack";
import type { Schedule } from "./schedule";
import type { AttackGoal } from "./attackGoal";
import { childrenOf, isAncestor, leavesUnder, type BlockTree } from "./blockTree";
import { chainStatesOf } from "./chainState";
import { latestVotes } from "./forkChoice";
import { equivocationsIn, equivocatorOf, evidenceRef } from "./inclusion";
import { validatorIndices, type InitialConditions } from "./initialConditions";
import type { View } from "./view";
import {
  SLOTS_PER_EPOCH,
  checkpointFor,
  epochBoundarySlot,
  epochOf,
  slotsSinceEpochStart,
} from "./finality";
import {
  ANCHOR_BLOCK_INDEX,
  ANCHOR_CHECKPOINT,
  type BlockIndex,
  type Checkpoint,
  type SlotIndex,
  type ValidatorIndex,
} from "./types";

/** 攻撃者でないバリデータを、インデックス順に並べたもの。 */
function honestOf(
  attackers: readonly ValidatorIndex[],
  config: InitialConditions,
): ValidatorIndex[] {
  return validatorIndices(config.validatorCount).filter((v) => !attackers.includes(v));
}

/** 最初の境界(スロット 0)でのみ `actions` を一度だけ発し、以降は何も
 * 発しない — 固定の介入列という戦略の形。 */
function once(actions: readonly Action[]): Strategy {
  return (observation) => (observation.slot === 0 ? actions : []);
}

/**
 * 次のスロットが攻撃者のものであれば、その次の提案の body から自分自身に
 * 不利な証拠をすべて取り込みの省略で除く — エクイボケーションする攻撃者が
 * しなければならないことで、正直な取り込みのままでは自分の証拠を自分の枝に
 * 運び入れ、自らをスラッシングしてしまう。証拠は観測から読み取る:
 * 境界の時点で攻撃者が保持している相反ペアすべて。
 */
function omitOwnEvidence({ slot, attackers, view, schedule }: AttackerObservation): Action[] {
  const next = slot + 1;
  if (!attackers.includes(schedule.proposerOf(next))) return [];
  const own = equivocationsIn(view.blockTree, view.votes).filter((e) =>
    attackers.includes(equivocatorOf(e)),
  );
  return own.length === 0
    ? []
    : [{ kind: "omit-inclusion", slot: next, evidence: own.map(evidenceRef) }];
}

/** `strategy` に、攻撃者自身の証拠をその全提案から省く取り込みの省略を
 * 加えたもの。 */
function omittingOwnEvidence(strategy: Strategy): Strategy {
  return (observation, params) => [
    ...strategy(observation, params),
    ...omitOwnEvidence(observation),
  ];
}

/** `slot` における全攻撃者に対する、同一の投票先指定。 */
function voteAll(
  attackers: readonly ValidatorIndex[],
  slot: SlotIndex,
  head: BlockIndex,
): Action[] {
  return attackers.map((validator) => ({ kind: "vote-target", slot, validator, head }));
}

// ── A01 Ex-Ante リオーグ(保留+時機) ────────────────────────────────────
// 攻撃者(バリデータ 1)はスロット 1 で提案し、自身のブロックと投票の両方を
// スロット 3 まで保留する。正直チェーン 錨→B2→B3 は正直アテステーションが
// 遅延しているため proposer boost のみで守られている。スロット 3 での公開に
// より、正直 head は B2 から攻撃者の B1 へ切り替わる — リオーグ — が、これは
// phase0(boost なし)の下でのこと。merge プリセットでは boost が正直ブロックを
// 守るため、攻撃目標は未達のままとなる(成功条件 19)。d = 2。
export const exAnteReorgA01: Strategy = once([
  { kind: "delay", message: { kind: "proposal", sender: 1, slot: 1 }, untilSlot: 3 },
  { kind: "delay", message: { kind: "vote", sender: 1, slot: 1 }, untilSlot: 3 },
  { kind: "delay", message: { kind: "vote", sender: 0, slot: 2 }, untilSlot: 4 },
  { kind: "delay", message: { kind: "vote", sender: 2, slot: 2 }, untilSlot: 4 },
  { kind: "delay", message: { kind: "vote", sender: 3, slot: 2 }, untilSlot: 4 },
  { kind: "delay", message: { kind: "vote", sender: 0, slot: 3 }, untilSlot: 5 },
  { kind: "delay", message: { kind: "vote", sender: 2, slot: 3 }, untilSlot: 5 },
  { kind: "delay", message: { kind: "vote", sender: 3, slot: 3 }, untilSlot: 5 },
]);

const REORG: AttackGoal = { kind: "reorg", count: 1 };

export const ATTACK_A01: Attack = {
  attackers: { kind: "count", atLeast: 1 },
  goal: [REORG],
  strategy: exAnteReorgA01,
};

// ── A02 proposer boost 逆用リオーグ(boost 逆用) ──────────────────────────
// 攻撃者(バリデータ 1)は正直な B4 を飛ばし、祖父ブロック B3 の上にスロット 5
// で提案する。同時に、自身のスロット 4 の B4 への投票を保留し(B3 に振り向け)、
// 他の正直なスロット 4 の投票も遅延させる。これにより B4 は正直投票 1 票
// (32)のみで守られ、攻撃者の B5 が持つ proposer boost(0.4 × 128 = 51.2)を
// 下回るため、正直 head は B4 から B5 へ移る — boost 自体が可能にするリオーグ
// である(前提 merge)。d = 2。
export const boostReversalA02: Strategy = once([
  { kind: "vote-target", slot: 4, validator: 1, head: 3 },
  { kind: "delay", message: { kind: "vote", sender: 0, slot: 4 }, untilSlot: 6 },
  { kind: "delay", message: { kind: "vote", sender: 2, slot: 4 }, untilSlot: 6 },
  { kind: "delay", message: { kind: "vote", sender: 3, slot: 4 }, untilSlot: 6 },
  { kind: "propose-parent", slot: 5, parent: 3 },
]);

export const ATTACK_A02: Attack = {
  attackers: { kind: "count", atLeast: 1 },
  goal: [REORG],
  strategy: boostReversalA02,
};

// ── A03 バランシング と A04 LMD バランシング ────────────────────────────
// どちらも正直バリデータたちのビューを 2 つの枝に分断したまま保ち、いずれの
// エポックのチェックポイントも 2/3 リンクを一度も得られないようにする
// (活性停止)。攻撃者(バリデータ 1)は自身のスロット 1 のブロック B1 を、
// スロット 2 の正直プロポーザーがそれと並んで B2 を build するのに足りる間だけ
// 保留する — 枝 A(B1 の下)と枝 B(B2 の下)の 2 つができ、正直バリデータは
// 2 つの陣営に分かれる: 陣営 B(スロット 2 のプロポーザーとそれ以降の正直
// バリデータ)は B2 を先に見て B に投票し、陣営 A は B1 を先に見て A に投票
// する。以降は攻撃者のスイング投票が各陣営をその枝に留め続ける: ある陣営は
// 常に、自分の枝を支持する攻撃者の最新投票を見ている(64 + 32 対 64)。他方の
// 枝への投票はその陣営に 2 スロット遅れて届く(d = 2)ため、届く頃には自分の
// 枝を支持するより新しいスイング投票がすでに到着しているからである。スイング
// 投票は枝の根 B1 / B2 を支持するので、その重みは証拠を含まないチェーン状態
// から読まれる(スラッシングで 0 になることは決してない)。
//
// A03 はスロットごとに 1 票のスイング投票を、枝を交互に切り替えながら投じる。
// phase0 の下ではバランスが保たれ finality が停止するが、merge プリセットの
// 下では proposer boost がそれを崩す — 他方の枝上の正直提案がそのスロット内に
// 0.4 × 160 = 64 の追加重みを伴って届き、それを見た陣営が寝返る
// (成功条件 19)。
//
// A04 はスロットごとに 2 票(二重投票)、枝ごとに 1 票を、選択配送で(二重
// 投票の分割)公開する: 各陣営は自分の枝向けの半分を即座に、もう半分を
// 2 スロット遅れて受け取る。LMD-GHOST の下では、ある陣営は常に攻撃者の
// 最新スロットについて自分の枝向けの半分だけを見ているため、バランスが
// 保たれる — これは merge + 割引 off の下で、正直提案を 1 スロット遅らせて
// 他方の陣営へ届け、自分自身の提案は全員へ 1 スロット遅れて届けることで、build していない
// 陣営でその提案が boost されることを防いでいる。merge プリセットの下では、
// ある陣営が 1 スロット分の両半分を保持した時点(2 スロット後)でエクイボ
// ケーション割引が発動し、攻撃者の重みはその陣営のビューで 0 に落ち、
// 64 対 64 はより小さいインデックス側にタイブレークされ、両陣営とも A に
// 収束する(成功条件 19)。
interface Balancing {
  readonly attacker: ValidatorIndex;
  /** 攻撃者の最初の提案スロット p: そのブロックが枝 A の根となる。 */
  readonly p: SlotIndex;
  /** 正直な提案スロット q = p + 1: A の根が保留されている間にそれと並んで
   * build されるそのブロックが、枝 B の根となる。 */
  readonly q: SlotIndex;
  readonly campA: readonly ValidatorIndex[];
  readonly campB: readonly ValidatorIndex[];
  readonly rootA: BlockIndex | undefined;
  readonly rootB: BlockIndex | undefined;
}

function balancingOf({
  attackers,
  view,
  schedule,
  config,
}: AttackerObservation): Balancing | undefined {
  const attacker = attackers[0];
  if (attacker === undefined) return undefined;
  const p = proposalSlotOf(schedule, [attacker], 1, config.validatorCount);
  if (p === undefined) return undefined;
  const q = p + 1;
  const splitter = schedule.proposerOf(q);
  const honest = honestOf(attackers, config);
  const at = honest.indexOf(splitter);
  if (at < 0 || honest.length < 2) return undefined;
  const rotated = [...honest.slice(at), ...honest.slice(0, at)];
  const half = Math.ceil(honest.length / 2);
  return {
    attacker,
    p,
    q,
    campB: rotated.slice(0, half),
    campA: rotated.slice(half),
    rootA: blockBy(view.blockTree, attacker, p),
    rootB: blockBy(view.blockTree, splitter, q),
  };
}

/** 分断の設定: A の根は、q の正直プロポーザーがそれと並んで build するまで
 * 陣営 A から保留し、陣営 B からはさらに 1 スロット長く保留する。これにより
 * 陣営 B はスロット q で B に投票し、陣営 A は両方を見て A に投票する。陣営 A
 * のスロット q の投票は陣営 B から 2 スロット保留し、陣営 B が常に B を先に
 * 見続けるようにする。 */
function balancingSetup(b: Balancing): Action[] {
  const root = { kind: "proposal", sender: b.attacker, slot: b.p } as const;
  return [
    { kind: "delay", message: root, untilSlot: b.p + 1, observers: b.campA },
    { kind: "delay", message: root, untilSlot: b.p + 2, observers: b.campB },
    ...b.campA.map(
      (validator): Action => ({
        kind: "delay",
        message: { kind: "vote", sender: validator, slot: b.q },
        untilSlot: b.q + 2,
        observers: b.campB,
      }),
    ),
  ];
}

/** スロット `t` の攻撃者の投票が振れる先の枝: 分断の設定中(スロット p と q)
 * は A、その後は B と A の交互。 */
function swingBranch(b: Balancing, t: SlotIndex): "A" | "B" | undefined {
  if (t < b.p) return undefined;
  if (t <= b.q) return "A";
  return (t - b.p) % 2 === 0 ? "B" : "A";
}

/** スイング投票が他方の陣営から保留されるスロット数。 */
const SWING_DELAY = 2;

export const balancingA03: Strategy = (observation) => {
  const b = balancingOf(observation);
  if (b === undefined) return [];
  const t = observation.slot + 1;
  const branch = swingBranch(b, t);
  const actions: Action[] = observation.slot === 0 ? balancingSetup(b) : [];
  if (branch === undefined) return actions;
  const root = branch === "A" ? b.rootA : b.rootB;
  if (root !== undefined) {
    actions.push({ kind: "vote-target", slot: t, validator: b.attacker, head: root });
  }
  actions.push({
    kind: "delay",
    message: { kind: "vote", sender: b.attacker, slot: t },
    untilSlot: t + SWING_DELAY,
    observers: branch === "A" ? b.campB : b.campA,
  });
  return actions;
};

/** 活性停止の閾値 L: 正直な起動時の停滞(最初の finalize はスロット 9)より
 * 上に設定してあるので、正直な実行ではこれに引っかからない。 */
const STALL: AttackGoal = { kind: "liveness-stall", slots: 12 };

export const ATTACK_A03: Attack = {
  attackers: { kind: "count", atLeast: 1 },
  goal: [STALL],
  strategy: balancingA03,
};

/** 正直な陣営がバランスを離れたかどうか: 分断が存在する時点で、すべての
 * 正直バリデータの最新投票が同じ枝の根に載っている状態を指す。攻撃者は
 * 自身が保持する投票からこれを読み取る(それらは即座に届く)。 */
function campsConverged(b: Balancing, view: View, t: SlotIndex): boolean {
  if (t <= b.q + 1 || b.rootA === undefined || b.rootB === undefined) return false;
  const latest = latestVotes(view.votes);
  const roots = new Set<BlockIndex | undefined>();
  for (const v of [...b.campA, ...b.campB]) {
    const vote = latest.get(v);
    if (vote === undefined) return false;
    roots.add(branchOf(view.blockTree, [b.rootA, b.rootB], vote.head));
  }
  return roots.size === 1;
}

export const lmdBalancingA04: Strategy = (observation) => {
  const b = balancingOf(observation);
  if (b === undefined) return [];
  const t = observation.slot + 1;
  // 両陣営が 1 つの枝に収まった時点(割引がスイング投票を 0 にした時点)で
  // バランシングは終わり、攻撃者は停止する — 提案の遅延を続けても、それは
  // エポックの target を分裂させるだけの、別の攻撃(A06)になってしまう。
  if (campsConverged(b, observation.view, t)) return [];
  const actions: Action[] = observation.slot === 0 ? balancingSetup(b) : [];
  // build していない陣営で提案が boost されることは決してない: 正直な提案は
  // 他方の陣営に 1 スロット遅れて届き、攻撃者自身の提案は全員に 1 スロット
  // 遅れて届く。
  const proposer = observation.schedule.proposerOf(t);
  if (proposer === b.attacker && t > b.p) {
    actions.push({
      kind: "delay",
      message: { kind: "proposal", sender: proposer, slot: t },
      untilSlot: t + 1,
    });
  } else if (t >= b.q && (b.campA.includes(proposer) || b.campB.includes(proposer))) {
    actions.push({
      kind: "delay",
      message: { kind: "proposal", sender: proposer, slot: t },
      untilSlot: t + 1,
      observers: b.campA.includes(proposer) ? b.campB : b.campA,
    });
  }
  const branch = swingBranch(b, t);
  if (branch === undefined) return actions;
  if (t <= b.q || b.rootA === undefined || b.rootB === undefined) {
    // まだ枝 A しか存在しない: A03 と同じ単一のスイング投票。
    if (b.rootA !== undefined) {
      actions.push({ kind: "vote-target", slot: t, validator: b.attacker, head: b.rootA });
    }
    actions.push({
      kind: "delay",
      message: { kind: "vote", sender: b.attacker, slot: t },
      untilSlot: t + SWING_DELAY,
      observers: b.campB,
    });
    return actions;
  }
  // 2 つの半分は選択配送で公開する: A への投票は陣営 A に、B への投票は
  // 陣営 B に即座に届き、それぞれ他方の陣営には 2 スロット遅れて届く。
  actions.push(
    { kind: "vote-target", slot: t, validator: b.attacker, head: b.rootA },
    {
      kind: "double-vote",
      slot: t,
      validator: b.attacker,
      head: b.rootB,
      split: { first: b.campA, second: b.campB, untilSlot: t + SWING_DELAY },
    },
  );
  return actions;
};

/** A04 の停止閾値: 割引がバランスを崩すと陣営はあるエポック内で収束するが、
 * 各バリデータの FFG 部分はその収束したエポックのものとして確定するため、
 * 収束後最初の finalize は正直なスロット 9 より 1 エポック遅れる(既定実行
 * 構成ではスロット 13)。閾値はそれより十分上にしてあるので、緩和策のある
 * 実行は未達のまま、バランスした実行はこれに到達する。 */
const LMD_STALL: AttackGoal = { kind: "liveness-stall", slots: 20 };

export const ATTACK_A04: Attack = {
  attackers: { kind: "count", atLeast: 1 },
  goal: [LMD_STALL],
  strategy: lmdBalancingA04,
};

// ── A06 エポック境界 finality 遅延 ──────────────────────────────────────
// 攻撃者は最初のエポック境界提案(スロット 4、正直)を、正直バリデータの
// 半数に対して d = 4 スロット遅延させる。時間内に受信するバリデータ —
// そのプロポーザー、次スロットのプロポーザー、そして攻撃者 — は target B4
// に投票する。残りは依然として B3 をエポック 1 のチェックポイントと見なし
// target B3 に投票するので、どちらの target も 2/3 リンクを得られず(target
// 分裂)、エポック 1 は一度も justified にならない。2 つのグループはブロック
// がスロット 8 に届くまで別々のチェーンを伸ばし、次の境界ブロックが両者を
// 統合してエポック 2 で justified、エポック 3 で finalize される — 正直な
// スロット 9 ではなくスロット 13 になる。停止閾値は正直な最初の finalize の
// 1 スロット上にあるので、この 1 エポック分の遅延がそのまま攻撃目標として
// 読み取られる(活性停止、L = 10。フォールバックのチェックポイント B3 は
// 常に投票を欠くだけで、それ自身の finalize は問題にならない)。前提 merge。
export const boundaryDelayA06: Strategy = ({ slot, attackers, schedule, config }, params) => {
  if (slot !== 0) return [];
  let boundary = SLOTS_PER_EPOCH;
  for (let i = 0; i < config.validatorCount && attackers.includes(schedule.proposerOf(boundary)); i++) {
    boundary += SLOTS_PER_EPOCH;
  }
  const proposer = schedule.proposerOf(boundary);
  if (attackers.includes(proposer)) return [];
  const seeing = [proposer, schedule.proposerOf(boundary + 1)];
  const hidden = honestOf(attackers, config).filter((v) => !seeing.includes(v));
  if (hidden.length === 0) return [];
  return [
    {
      kind: "delay",
      message: { kind: "proposal", sender: proposer, slot: boundary },
      untilSlot: boundary + params.maxDelay,
      observers: hidden,
    },
  ];
};

/** 正直な最初の finalize(スロット 9)の 1 スロット上: これより遅れれば
 * 停止とみなす。 */
const FINALITY_DELAY: AttackGoal = { kind: "liveness-stall", slots: 10 };

export const ATTACK_A06: Attack = {
  attackers: { kind: "count", atLeast: 1 },
  goal: [FINALITY_DELAY],
  strategy: boundaryDelayA06,
};

// ── A05 バウンシング(競合 justified 間の跳ね) ───────────────────────────
// 前提 merge + justified チェックポイント切替 off + committee エポック分割、
// 4 バリデータ中 1 攻撃者: 3 票で justified となるので、正直投票 2 票を持つ
// チェックポイントは攻撃者が自分の 1 票を加えたときにちょうど justified に
// なる。各バリデータはエポックに 1 度だけ attest するので、一度投票した
// バリデータは同じエポック内で後から現れるチェックポイントに再び投票
// できない。
//
// opening が作るフォークから 2 つの枝 X と Y が育つ。最初のバウンス以降の
// 各エポック k で、正直バリデータは fork choice の root r を持つ一方の枝
// (old)から始め、そのうち 2 名がそのエポックの攻撃者の提案より前に attest
// して (r → cp_k(old)) に投票する。攻撃者の提案 — バウンスブロック — は
// もう一方の枝(new)の上に build され、エポック k−1 で攻撃者が投じて保留
// していた投票 (r' → cp_{k−1}(new)) を取り込む: そのエポックの正直投票 2 票
// と合わせて最新の justified チェックポイントである cp_{k−1}(new) が
// justified となり、このブロックを受信したすべての正直バリデータはその
// root — そして head — を new に移す。このブロックは早い方の 2 名の
// アテスターが投票し終えるまで彼らから保留され、3 人目の正直バリデータは
// その後 new 上で attest する。攻撃者自身は自分の committee スロットで
// (r → cp_k(old)) に投票し、その投票を次の自分の提案(old 上)まで保留し、
// そこで cp_k(old) を justified にする — 次のバウンスである。こうして
// justified チェックポイントは X, Y, X, … と交互になり、各 justify リンクは
// 2 エポックにまたがるため、チェックポイントは一度も finalize されない:
// 活性停止。
//
// opening(エポック 1〜3)は、跳ねの起点となる justified チェックポイントが
// まだない状態でフォークと最初の分断を仕込む段階で、正直ブロックを遅延
// させることで行う: あるブロックを受信していないバリデータは、そのブロック
// またはその子孫への投票をすべて重み 0 として扱う(その head を知らない
// ため)。したがってあるチェーンの最新ブロックをあるバリデータから保留する
// と、そのバリデータはもう一方のチェーンへ移る。エポック 1 の境界ブロックは
// splitter — エポック 1 のより遅いスロットで提案かつ attest する正直
// バリデータ — に遅延して届き、そのため splitter はそれと並んで build する
// (フォーク: 境界ブロックを持つ X と、splitter のブロックを持つ Y)、
// そしてフォーク地点に投票する。残る 2 名の正直バリデータ(エポック 2 と
// エポック 3 の境界ブロックを提案する flipper と、holdout)は
// (錨 → cp_1(X)) に投票するが、攻撃者はこの 2 票を決して完成させない。
// エポック 2 ではエポック 2 の境界ブロックが splitter に遅延して届くので、
// splitter は Y に留まりそれを伸ばして Y に投票する。flipper と holdout は
// (錨 → cp_2(X)) に投票する。攻撃者のそのエポックの投票 — head は Y、
// target は cp_2(X) — は全員に即座に届く。エポック 3 では holdout のエポック
// 2 のブロックが flipper に遅延して届くので、flipper は自分の直前の投票を
// 重み 0 として扱い Y へ移る: flipper は Y 上でエポック 3 の境界ブロック
// (cp_3(Y))を提案し (錨 → cp_3(Y)) に投票する。同じスロットで attest
// する holdout は、その適時な提案が boost されているのを見て Y に投票する。
// 最初のバウンスブロック(エポック 3、X 上)は攻撃者のエポック 2 の投票と
// ともに cp_2(X) を justified にし、以後この型が繰り返される。d = 5(攻撃者
// の投票はその committee スロットから次の自分の提案まで、最大で 5 スロット
// 保留される)。
//
// 切替窓(merge)と unrealized justification(current)は、この攻撃が判定
// 対象とする緩和策である(成功条件 19): 切替窓があると root はエポックの
// 先頭スロットでのみ動く。

/** `validator` が `epoch` 内で attest するスロット(あれば)。 */
function attestationSlotOf(
  schedule: Schedule,
  validator: ValidatorIndex,
  epoch: number,
): SlotIndex | undefined {
  const start = epochBoundarySlot(epoch);
  for (let slot = start; slot < start + SLOTS_PER_EPOCH; slot++) {
    if (schedule.committeeOf(slot).has(validator)) return slot;
  }
  return undefined;
}

/** `proposers` のいずれかが提案する `epoch` 内の最初のスロット(あれば)。 */
function proposalSlotIn(
  schedule: Schedule,
  proposers: readonly ValidatorIndex[],
  epoch: number,
): SlotIndex | undefined {
  const start = epochBoundarySlot(epoch);
  for (let slot = start; slot < start + SLOTS_PER_EPOCH; slot++) {
    if (proposers.includes(schedule.proposerOf(slot))) return slot;
  }
  return undefined;
}

/** 一度だけフォークした木の 2 つの枝: 子を 2 つ持つ最初のブロックの子を
 * インデックス順に並べたもの。フォークが存在する前は undefined。 */
function branchesOf(tree: BlockTree): readonly [BlockIndex, BlockIndex] | undefined {
  for (const block of [...tree.blocks.values()].sort((a, b) => a.index - b.index)) {
    const children = childrenOf(tree, block.index);
    if (children.length >= 2) return [children[0]!, children[1]!];
  }
  return undefined;
}

/** `block` の祖先である枝の根(あれば)。 */
function branchOf(
  tree: BlockTree,
  branches: readonly [BlockIndex, BlockIndex],
  block: BlockIndex,
): BlockIndex | undefined {
  return branches.find((root) => isAncestor(tree, root, block));
}

export const bouncingA05: Strategy = (observation) => {
  const { slot, attackers, view, schedule, config } = observation;
  const attacker = attackers[0];
  if (attacker === undefined) return [];
  const honest = honestOf(attackers, config);
  const tree = view.blockTree;
  const next = slot + 1;
  const epoch = epochOf(next);
  const attest = (v: ValidatorIndex, e: number): SlotIndex | undefined =>
    attestationSlotOf(schedule, v, e);
  const proposalOf = (proposer: ValidatorIndex, at: SlotIndex) =>
    ({ kind: "proposal", sender: proposer, slot: at }) as const;
  const attestationOf = (validator: ValidatorIndex, at: SlotIndex) =>
    ({ kind: "vote", sender: validator, slot: at }) as const;
  const boundary1 = epochBoundarySlot(1);
  const rootSlot = 1;
  // opening における役割: boundary proposer(F)はエポック 1 の境界ブロックを
  // 提案する。splitter(S)はエポック 1 の最後の正直スロットで提案かつ
  // attest し、そこで Y へ移る。holdout(H)は 3 人目の正直バリデータ。
  // 攻撃者はスロット 1 で Y の根を提案しなければならない。
  const boundaryProposer = schedule.proposerOf(boundary1);
  const splitSlot = Math.max(
    ...honest.map((v) => attest(v, 1) ?? -1).filter((s) => s > boundary1),
  );
  const splitter = honest.find(
    (v) => attest(v, 1) === splitSlot && schedule.proposerOf(splitSlot) === v,
  );
  const holdout = honest.find((v) => v !== splitter && v !== boundaryProposer);
  if (
    schedule.proposerOf(rootSlot) !== attacker ||
    attackers.includes(boundaryProposer) ||
    splitter === undefined ||
    splitter === boundaryProposer ||
    holdout === undefined
  ) {
    return [];
  }
  const actions: Action[] = [];

  if (slot === 0) {
    const a1 = attest(attacker, 1);
    const a2 = attest(attacker, 2);
    const f1 = attest(boundaryProposer, 1);
    const f2 = attest(boundaryProposer, 2);
    const h1 = attest(holdout, 1);
    const p1 = proposalSlotIn(schedule, attackers, 1);
    const p3 = proposalSlotIn(schedule, attackers, 3);
    const fProposal2 = proposalSlotIn(schedule, [boundaryProposer], 2);
    const hProposal2 = proposalSlotIn(schedule, [holdout], 2);
    if (
      [a1, a2, f1, f2, h1, p1, p3, fProposal2, hProposal2].includes(undefined) ||
      a1! <= rootSlot
    ) {
      return [];
    }
    actions.push(
      // Y の根は、正直チェーン X がそれと並んで始まるまで保留する。
      { kind: "delay", message: proposalOf(attacker, rootSlot), untilSlot: boundary1 },
      // 攻撃者のエポック 1 の投票(head は Y)は、F と H が X に投票した後に
      // しか届かない。F にとってその攻撃者のエポック 1 のブロックは boost
      // されない。
      { kind: "delay", message: attestationOf(attacker, a1!), untilSlot: f1! + 1, observers: [boundaryProposer] },
      { kind: "delay", message: attestationOf(attacker, a1!), untilSlot: h1! + 1, observers: [holdout] },
      { kind: "delay", message: proposalOf(attacker, p1!), untilSlot: f1! + 1, observers: [boundaryProposer] },
      // 境界ブロックは S にそのスロットより後に届く: S はそのエポックの X
      // への投票を重み 0 として扱い、同点で Y へ移る。
      { kind: "delay", message: proposalOf(boundaryProposer, boundary1), untilSlot: splitSlot + 1, observers: [splitter] },
      // S の Y への投票は、F と H にそれぞれのエポック 2 の提案(X 上)の後に
      // 届く。
      { kind: "delay", message: attestationOf(splitter, splitSlot), untilSlot: fProposal2!, observers: [boundaryProposer] },
      { kind: "delay", message: attestationOf(splitter, splitSlot), untilSlot: hProposal2!, observers: [holdout] },
      // 攻撃者のエポック 2 の投票(head は Y、target は cp_2(X))は、F には
      // 自身のエポック 2 の投票の後に、他は最初のバウンスブロックとともに
      // 届く。
      { kind: "delay", message: attestationOf(attacker, a2!), untilSlot: f2! + 1, observers: [boundaryProposer] },
      { kind: "delay", message: attestationOf(attacker, a2!), untilSlot: p3!, observers: [holdout, splitter] },
    );
  }

  const boundaryBlock = blockBy(tree, boundaryProposer, boundary1);
  const branches = branchesOf(tree);
  const mine = attest(attacker, epoch);
  const proposal = proposalSlotIn(schedule, attackers, epoch);
  const tip = (root: BlockIndex): BlockIndex => tipUnder(tree, root);

  const yRoot = blockBy(tree, attacker, rootSlot);
  // 攻撃者のエポック 1 の提案は Y の根を伸ばす。
  if (epoch === 1 && proposal === next && yRoot !== undefined) {
    actions.push({ kind: "propose-parent", slot: proposal, parent: yRoot });
  }

  // 攻撃者のこのエポックの投票。その直前の境界で内容を決める。
  if (mine === next) {
    if (epoch === 0) {
      // 重みなし: head も target も 錨。
      actions.push({
        kind: "vote-target",
        slot: mine,
        validator: attacker,
        head: ANCHOR_BLOCK_INDEX,
        target: ANCHOR_BLOCK_INDEX,
      });
    } else if (epoch === 1) {
      // head は Y の根、target は錨(意味を持たないリンク)。
      if (yRoot === undefined) return actions;
      actions.push({ kind: "vote-target", slot: mine, validator: attacker, head: yRoot, target: ANCHOR_BLOCK_INDEX });
    } else if (epoch === 2) {
      // head は Y(分断のための重み)、target は cp_2(X): 最初のバウンス
      // ブロックが取り込む投票。全員に即座に届く — バウンスより前に X 上の
      // 正直ブロックが 3 票すべてを取り込むことはない。
      const x = boundaryBlock === undefined || branches === undefined ? undefined : branchOf(tree, branches, boundaryBlock);
      const y = branches?.find((b) => b !== x);
      if (x === undefined || y === undefined) return actions;
      actions.push({
        kind: "vote-target",
        slot: mine,
        validator: attacker,
        head: tip(y),
        source: ANCHOR_CHECKPOINT,
        target: checkpointFor(tree, tip(x), epoch).block,
      });
    } else {
      const previous = view.votes.find(
        (v) => v.validator === attacker && epochOf(v.slot) === epoch - 1,
      );
      const newBranch =
        previous === undefined || branches === undefined ? undefined : branchOf(tree, branches, previous.target.block);
      const oldBranch = branches?.find((b) => b !== newBranch);
      const release = proposalSlotIn(schedule, attackers, epoch + 1);
      if (oldBranch === undefined || release === undefined) return actions;
      if (mine !== epochBoundarySlot(epoch) || epoch === 3) {
        actions.push({ kind: "vote-target", slot: mine, validator: attacker, head: tip(oldBranch) });
      }
      actions.push({
        kind: "delay",
        message: { kind: "vote", sender: attacker, slot: mine },
        untilSlot: release,
      });
    }
  }

  // バウンスブロック。攻撃者の提案の直前の境界で内容を決める。
  if (epoch >= 3 && proposal === next) {
    const previous = view.votes.find(
      (v) => v.validator === attacker && epochOf(v.slot) === epoch - 1,
    );
    const newBranch =
      previous === undefined || branches === undefined ? undefined : branchOf(tree, branches, previous.target.block);
    if (newBranch === undefined) return actions;
    actions.push({ kind: "propose-parent", slot: proposal, parent: tip(newBranch) });
    const slots = honest
      .map((v) => [v, attest(v, epoch)] as const)
      .filter((pair): pair is readonly [ValidatorIndex, SlotIndex] => pair[1] !== undefined)
      .sort((a, b) => a[1] - b[1]);
    const late = slots[slots.length - 1];
    for (const [v, at] of slots) {
      if (v === late?.[0] || at < proposal) continue;
      actions.push({
        kind: "delay",
        message: { kind: "proposal", sender: attacker, slot: proposal },
        untilSlot: at + 1,
        observers: [v],
      });
    }
  }
  return actions;
};

export const ATTACK_A05: Attack = {
  attackers: { kind: "count", atLeast: 1 },
  goal: [STALL],
  strategy: bouncingA05,
};

// ── A09 1/3 超の棄権による finality 停止 ─────────────────────────────────
// 攻撃者(バリデータ 2 と 3、ステークの半分)はスロット 1 以降、沈黙する。
// 投票するバリデータが 2 名だけになるため、source→target のリンクが 2/3
// 超に達することは一度もなく、finalized は 錨 から動かず、神視点は
// 無期限に停止する(前提 merge; 活性停止)。
export const abstainStallA09: Strategy = once([
  { kind: "stop", fromSlot: 1, validators: [2, 3] },
]);

export const ATTACK_A09: Attack = {
  attackers: { kind: "stake-ratio", atLeast: 1 / 3 },
  goal: [STALL],
  strategy: abstainStallA09,
};

// ── A11 51% 多数派 fork choice 支配リオーグ ────────────────────────────
// 攻撃者はステークの多数派を握る(バリデータ 0, 1, 2)。バリデータ 0 は
// スロット 4 で 錨 の上に提案する — 正直チェーンと並ぶフォーク — そして
// 攻撃者 3 名全員がスロット 4 とスロット 5 の投票をそちらへ振り向ける。彼らの
// 重みが LMD fork choice を支配するため、正直 head はそのフォーク(直前の
// スロット 3 の head の子孫ではないブロック)へ移る: リオーグである(前提
// merge)。A11 の検閲は対象外(トランザクションを扱わない)であり、この攻撃は
// 多数派による fork choice 支配として扱う(ESSENCE 前提事項)。
export const majorityReorgA11: Strategy = once([
  { kind: "propose-parent", slot: 4, parent: 0 },
  { kind: "vote-target", slot: 4, validator: 0, head: 4 },
  { kind: "vote-target", slot: 4, validator: 1, head: 4 },
  { kind: "vote-target", slot: 4, validator: 2, head: 4 },
  { kind: "vote-target", slot: 5, validator: 0, head: 4 },
  { kind: "vote-target", slot: 5, validator: 1, head: 4 },
  { kind: "vote-target", slot: 5, validator: 2, head: 4 },
]);

export const ATTACK_A11: Attack = {
  attackers: { kind: "stake-ratio", atLeast: 0.5 },
  goal: [REORG],
  strategy: majorityReorgA11,
};

// ── A07 アバランチ(秘匿エクイボケーションブロック列の一斉公開) ─────────────
// 攻撃者(バリデータ 1)は秘匿したチェーン B1(スロット 1)→ B5(スロット 5、
// 次の自分の提案)を build し、毎スロットそれに投票しつつその投票も保留する
// — スロット 5 では二重投票で、その両半分(B5 と親の B1)がともに秘匿された
// 部分木に収まる。その一方で正直チェーンは 錨→B2→B3→B4 と伸び、攻撃者は
// 正直投票を遅延させ、公開の時点で各正直バリデータが自分の直近の投票と、
// 1、2 個の古い投票だけしか見ていないようにする。すべてはスロット 6 で公開
// される。GHOST の下ではすべての古い投票・エクイボケーション投票が数えられ、
// 秘匿部分木は攻撃者の投票 6 票(6 × 32)を運び、それは正直な投票最大 5 票を
// 上回るため、正直 head は B4 から B5 へ移る — リオーグ — その後の正直投票も
// それを維持する。LMD-GHOST の下では攻撃者の最新の投票のみが数えられ(ペアの
// 片半分、32)、それは少なくとも正直な最新投票 2 票(64)を下回り、しかも
// エクイボケーション割引によりただちに 0 にされるため、merge プリセット
// (LMD + 割引、加えて正直提案への boost)の下では head は決して動かない
// (成功条件 19)。前提 phase0 + fork choice GHOST、d = 5。
export const avalancheA07: Strategy = once([
  { kind: "delay", message: { kind: "proposal", sender: 1, slot: 1 }, untilSlot: 6 },
  { kind: "delay", message: { kind: "vote", sender: 1, slot: 1 }, untilSlot: 6 },
  { kind: "delay", message: { kind: "vote", sender: 1, slot: 2 }, untilSlot: 6 },
  { kind: "delay", message: { kind: "vote", sender: 1, slot: 3 }, untilSlot: 6 },
  { kind: "delay", message: { kind: "vote", sender: 1, slot: 4 }, untilSlot: 6 },
  { kind: "delay", message: { kind: "vote", sender: 1, slot: 5 }, untilSlot: 6 },
  ...voteAll([1], 2, 1),
  ...voteAll([1], 3, 1),
  ...voteAll([1], 4, 1),
  { kind: "propose-parent", slot: 5, parent: 1 },
  ...voteAll([1], 5, 5),
  { kind: "double-vote", slot: 5, validator: 1 },
  { kind: "delay", message: { kind: "vote", sender: 0, slot: 2 }, untilSlot: 7 },
  { kind: "delay", message: { kind: "vote", sender: 2, slot: 2 }, untilSlot: 7, observers: [0] },
  { kind: "delay", message: { kind: "vote", sender: 0, slot: 3 }, untilSlot: 7 },
  { kind: "delay", message: { kind: "vote", sender: 2, slot: 3 }, untilSlot: 7 },
  { kind: "delay", message: { kind: "vote", sender: 3, slot: 3 }, untilSlot: 7 },
  { kind: "delay", message: { kind: "vote", sender: 0, slot: 4 }, untilSlot: 8 },
  { kind: "delay", message: { kind: "vote", sender: 2, slot: 4 }, untilSlot: 8 },
  { kind: "delay", message: { kind: "vote", sender: 3, slot: 4 }, untilSlot: 8 },
  { kind: "delay", message: { kind: "vote", sender: 0, slot: 5 }, untilSlot: 9 },
  { kind: "delay", message: { kind: "vote", sender: 2, slot: 5 }, untilSlot: 9 },
  { kind: "delay", message: { kind: "vote", sender: 3, slot: 5 }, untilSlot: 9 },
]);

export const ATTACK_A07: Attack = {
  attackers: { kind: "count", atLeast: 1 },
  goal: [REORG],
  strategy: avalancheA07,
};

// ── A10 34% 二重投票による二重 finality ─────────────────────────────────
// 攻撃者(バリデータ 2 と 3、ステークの半分)は 2 名の正直バリデータのビューを
// 分割する: バリデータ 0 には攻撃者のブロック B3(スロット 3 で B1 の上に
// build)を、バリデータ 1 には正直な B4 を、いずれもスロット 12 になって
// 初めて届ける。こうしてスロット 4 以降、各正直バリデータは自分自身の枝を伸ばす
// — A: B1→B2→B4→…、B: B1→B3→B5→…。攻撃者は両方の枝のエポック
// チェックポイントに、スロットを交互に切り替えて投票する — A には偶数スロット
// (スロット 4 の B4、スロット 8 の B8)、B には奇数スロット(スロット 5 の
// B3、スロット 9 の B7。エポックの 2 番目の target は明示的に投票先指定する。
// 指定しない FFG 部分はそのエポックの最初のものを繰り返してしまうため)— そし
// てそれぞれの投票をその枝の正直バリデータにのみ配送し、もう一方へはスロット
// 12 まで保留する(選択配送)。これにより、どちらの正直バリデータも自分の
// リンクを完成させる間、相反するペアを見ることはない: A 側は {0,2,3}、B 側は
// {1,2,3}、それぞれ 4 分の 3。両方の枝が finalize する — A では B4 が
// スロット 10 で、B では B3 がスロット 11 で — 互いに矛盾する 2 つの
// finalized チェックポイントとなる(安全性違反)。この相反する target 投票は
// 同一エポックの FFG 二重投票であり、攻撃者は自分自身の提案からはそれを
// 省くが、神視点はそのペアをすべて保持しており(成功条件 27)、スロット 12 で
// 分断が癒えると次の正直提案(スロット 13)がその証拠を取り込み、攻撃者は
// その枝上でスラッシングされる。前提 merge、d = 8(B4 とバリデータ 0 の
// 早い投票は、バリデータ 1 から最大 8 スロット保留される)。
const HEAL_SLOT = 12;

/** `slot` における全攻撃者に対する、FFG 部分を明示した同一の投票先指定。 */
function voteAllFfg(
  attackers: readonly ValidatorIndex[],
  slot: SlotIndex,
  head: BlockIndex,
  target: BlockIndex,
  source?: Checkpoint,
): Action[] {
  return attackers.map((validator) => ({
    kind: "vote-target",
    slot,
    validator,
    head,
    target,
    ...(source === undefined ? {} : { source }),
  }));
}

/** 攻撃者の `slot` の投票は、heal slot まで `to` にのみ届く。 */
function deliverOnlyTo(
  attackers: readonly ValidatorIndex[],
  slot: SlotIndex,
  to: ValidatorIndex,
  others: readonly ValidatorIndex[],
): Action[] {
  return attackers.map((sender) => ({
    kind: "delay",
    message: { kind: "vote", sender, slot },
    untilSlot: HEAL_SLOT,
    observers: others.filter((v) => v !== to),
  }));
}

export const doubleFinalityA10: Strategy = omittingOwnEvidence(once([
  { kind: "propose-parent", slot: 3, parent: 1 },
  { kind: "delay", message: { kind: "proposal", sender: 3, slot: 3 }, untilSlot: HEAL_SLOT - 1, observers: [0] },
  { kind: "delay", message: { kind: "proposal", sender: 0, slot: 4 }, untilSlot: HEAL_SLOT, observers: [1] },
  // バリデータ 0 の B2 への投票をバリデータ 1 から保留し、スロット 4 の
  // 時点でバリデータ 1 が B3 上に座るようにする。
  { kind: "delay", message: { kind: "vote", sender: 0, slot: 2 }, untilSlot: 10, observers: [1] },
  { kind: "delay", message: { kind: "vote", sender: 0, slot: 3 }, untilSlot: 11, observers: [1] },
  ...voteAll([2, 3], 3, 3),
  // 偶数スロット: 枝 A への投票をバリデータ 0 へ、奇数スロット: 枝 B への
  // 投票をバリデータ 1 へ。
  ...voteAll([2, 3], 4, 4),
  ...deliverOnlyTo([2, 3], 4, 0, [0, 1]),
  ...voteAllFfg([2, 3], 5, 5, 3),
  ...deliverOnlyTo([2, 3], 5, 1, [0, 1]),
  { kind: "propose-parent", slot: 6, parent: 4 },
  ...voteAll([2, 3], 6, 6),
  ...deliverOnlyTo([2, 3], 6, 0, [0, 1]),
  { kind: "propose-parent", slot: 7, parent: 5 },
  ...voteAllFfg([2, 3], 7, 7, 3),
  ...deliverOnlyTo([2, 3], 7, 1, [0, 1]),
  ...voteAll([2, 3], 8, 8),
  ...deliverOnlyTo([2, 3], 8, 0, [0, 1]),
  ...voteAllFfg([2, 3], 9, 9, 7, { epoch: 1, block: 3 }),
  ...deliverOnlyTo([2, 3], 9, 1, [0, 1]),
  { kind: "propose-parent", slot: 10, parent: 8 },
  ...voteAll([2, 3], 10, 10),
  ...deliverOnlyTo([2, 3], 10, 0, [0, 1]),
  { kind: "propose-parent", slot: 11, parent: 9 },
  ...voteAllFfg([2, 3], 11, 11, 7, { epoch: 1, block: 3 }),
  ...deliverOnlyTo([2, 3], 11, 1, [0, 1]),
]));

const SAFETY: AttackGoal = { kind: "safety-violation" };

export const ATTACK_A10: Attack = {
  attackers: { kind: "stake-ratio", atLeast: 1 / 3 },
  goal: [SAFETY],
  strategy: doubleFinalityA10,
};

// ── A12 66% 履歴支配 ────────────────────────────────────────────────────
// 攻撃者(バリデータ 0, 1, 2 — ステークの 4 分の 3)はまず正直に振る舞い、
// 正直チェーンはスロット 9 で B4 を finalize する。スロット 12 でバリデータ
// 0 が 錨 の上に — finalize 済みの履歴と並んで — 提案し、攻撃者は自身の
// 投票を新しい枝へ振り向け、自分たちのスロット(13, 14, 16, 17, 18, 20)から
// それを伸ばす。そこでの攻撃者のエポック 3 の投票は錨(エポック 0)→
// B12(エポック 3)にまたがり、したがって自分自身のエポック 2 の投票 B4
// (エポック 1)→ B8(エポック 2)を包囲する: すべての攻撃者(ステークの 4 分の
// 3)についての包囲投票の証拠は神視点に存在し、正直バリデータは正直チェーン
// 上の自身のスロット 15 のブロックにそれを取り込む — そこで攻撃者はスラッシ
// ングされ、以後そのチェーンは正直バリデータの投票のみで justify・finalize
// されるようになる — そして攻撃者は自分自身のブロックからはそれを取り込みの
// 省略で除くので、彼らの枝は自分たちのステークを保つ。攻撃者たちの 2/3 超の多数派は
// その枝のエポック 3 のチェックポイント(スロット 12)を justified にし、
// エポック 4 のチェックポイントがスロット 16 で build・投票されると、
// スロット 17 でそれを finalize する: すでに finalize 済みの B4 と矛盾する
// finalized チェックポイントである(安全性違反。成功条件 27 の
// アカウンタビリティを伴う)。前提 merge。
const A12_ATTACKERS: readonly ValidatorIndex[] = [0, 1, 2];

export const historyDominationA12: Strategy = omittingOwnEvidence(once([
  { kind: "propose-parent", slot: 12, parent: 0 },
  ...voteAll(A12_ATTACKERS, 12, 12),
  { kind: "propose-parent", slot: 13, parent: 12 },
  ...voteAll(A12_ATTACKERS, 13, 13),
  { kind: "propose-parent", slot: 14, parent: 13 },
  ...voteAll(A12_ATTACKERS, 14, 14),
  ...voteAll(A12_ATTACKERS, 15, 14),
  { kind: "propose-parent", slot: 16, parent: 14 },
  ...voteAll(A12_ATTACKERS, 16, 16),
  { kind: "propose-parent", slot: 17, parent: 16 },
  ...voteAll(A12_ATTACKERS, 17, 17),
  { kind: "propose-parent", slot: 18, parent: 17 },
  ...voteAll(A12_ATTACKERS, 18, 18),
  ...voteAll(A12_ATTACKERS, 19, 18),
  { kind: "propose-parent", slot: 20, parent: 18 },
  ...voteAll(A12_ATTACKERS, 20, 20),
]));

export const ATTACK_A12: Attack = {
  attackers: { kind: "stake-ratio", atLeast: 2 / 3 },
  goal: [SAFETY],
  strategy: historyDominationA12,
};

// ── A14 inactivity leak 増幅 ────────────────────────────────────────────
// 反応的な戦略(固定列ではなく、観測が行動を決める)。攻撃者は分断を始める
// 2 つの提案を欠落させることで、正直バリデータ 1 名を残りから孤立させる —
// 孤立するバリデータのエポック 1 の最初の提案を残りの正直バリデータに対して欠落させ、その
// 直後の正直提案を孤立するバリデータに対して欠落させる — こうして正直バリデータ
// は互いの相手のブロックを見ることなく、2 つの枝 A(孤立するバリデータの
// もの)と B(残りのもの)を build する。攻撃者は両方を見ており、分断以降は
// 毎エポック両方に投票する: 各エポックの 2 番目のスロットで A の tip に、
// それ以外のスロットで B の tip に(分断そのものの時点では、残りが build
// することになるフォーク地点に)投票する — それぞれその枝の FFG 部分を明示
// して(source = その枝の justified チェックポイント、target = そのエポック
// のチェックポイント)投票するので、両方の枝が攻撃者を active としてカウント
// する。FFG 部分を明示しなければそのエポックの最初の投票を繰り返してしまい、
// またエポックの最初のスロットの投票はまだ A の境界ブロックを名指せない。
// 1 エポックの 2 つの FFG 部分は FFG 二重投票(1 つの target エポック、2 つの
// target)であり、エポックをまたいで A の投票は B のものを包囲するため、
// 各投票はその枝のバリデータにのみ選択配送で届き、どの正直ビューもペアを
// 保持することはなく、攻撃者自身の提案からはその証拠が省かれる。A では
// 孤立するバリデータと攻撃者だけが active なので finality が停止し、N エポッ
// クを超えて遅れると残りは毎エポックそこでステークを leak する(罰則
// inactivity leak)が、攻撃者は決して leak しない。段階 1: 孤立するバリデータ
// の head で読んだ A のチェーン状態における攻撃者の取り分が 1/3 に達する。
// 段階 2: 同じ侵食により孤立するバリデータと攻撃者が A の 2/3 超の多数派と
// なり、A は自身のチェックポイントを finalize する — これは、攻撃者の投票が
// ずっと finalize させ続けてきた B のものと矛盾する(安全性違反)。前提
// merge。
function proposalSlotOf(
  schedule: Schedule,
  proposers: readonly ValidatorIndex[],
  from: SlotIndex,
  validatorCount: number,
): SlotIndex | undefined {
  for (let slot = from; slot < from + validatorCount * SLOTS_PER_EPOCH; slot++) {
    if (proposers.includes(schedule.proposerOf(slot))) return slot;
  }
  return undefined;
}

/** バリデータが `slot` で提案したブロック。ビューがそれを保持していれば。 */
function blockBy(
  tree: BlockTree,
  proposer: ValidatorIndex,
  slot: SlotIndex,
): BlockIndex | undefined {
  for (const block of tree.blocks.values()) {
    if (block.kind === "proposed" && block.proposer === proposer && block.slot === slot) {
      return block.index;
    }
  }
  return undefined;
}

/** `root` の下で最も深い葉(最新スロット、次いで最小インデックス)。 */
function tipUnder(tree: BlockTree, root: BlockIndex): BlockIndex {
  let tip = root;
  for (const leaf of leavesUnder(tree, root)) {
    const a = tree.blocks.get(leaf)!;
    const b = tree.blocks.get(tip)!;
    if (a.slot > b.slot || (a.slot === b.slot && a.index < b.index)) tip = leaf;
  }
  return tip;
}

export const leakAmplificationA14: Strategy = omittingOwnEvidence((observation) => {
  const { slot, attackers, view, schedule, config } = observation;
  const honest = honestOf(attackers, config);
  const isolated = honest[0];
  const rest = honest.slice(1);
  if (isolated === undefined || rest.length === 0) return [];
  const splitA = proposalSlotOf(schedule, [isolated], SLOTS_PER_EPOCH, config.validatorCount);
  if (splitA === undefined) return [];
  const splitB = proposalSlotOf(schedule, rest, splitA + 1, config.validatorCount);
  if (splitB === undefined) return [];

  const actions: Action[] = [];
  if (slot === 0) {
    actions.push(
      { kind: "drop", message: { kind: "proposal", sender: isolated, slot: splitA }, observers: rest },
      {
        kind: "drop",
        message: { kind: "proposal", sender: schedule.proposerOf(splitB), slot: splitB },
        observers: [isolated],
      },
    );
  }
  const next = slot + 1;
  if (next < splitA) return actions;
  const tree = view.blockTree;
  const phase = slotsSinceEpochStart(next);
  const onA = phase === 1;
  const root = onA
    ? blockBy(tree, isolated, splitA)
    : (blockBy(tree, schedule.proposerOf(splitB), splitB) ??
      (next === splitA ? blockBy(tree, schedule.proposerOf(splitA - 1), splitA - 1) : undefined));
  if (root !== undefined) {
    const tip = tipUnder(tree, root);
    const justified = chainStatesOf(tree, config).get(tip)!.justified;
    const target = checkpointFor(tree, tip, epochOf(next)).block;
    actions.push(...voteAllFfg(attackers, next, tip, target, justified));
    const others = onA ? rest : [isolated];
    for (const sender of attackers) {
      actions.push({ kind: "drop", message: { kind: "vote", sender, slot: next }, observers: others });
    }
  }
  return actions;
});

export const ATTACK_A14: Attack = {
  attackers: { kind: "count", atLeast: 1 },
  goal: [{ kind: "attacker-stake-ratio", threshold: 1 / 3 }, SAFETY],
  strategy: leakAmplificationA14,
};
