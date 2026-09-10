// エポックとチェックポイント — Essence が保つ FFG の語彙: 4 スロットの
// エポックと、source/target 投票が指す、ある枝上のエポックのチェックポイント
// {epoch, block}。justified / finalized 自体はチェーン状態(chainState.ts)
// であり、その枝が取り込んだ投票から導出される。

import { pathToAnchor, type BlockTree } from "./blockTree";
import {
  ANCHOR_CHECKPOINT,
  type BlockIndex,
  type Checkpoint,
  type EpochIndex,
  type SlotIndex,
} from "./types";

/**
 * エポックの長さ(スロット数)。抽象モデルがエポックを必要とするのは
 * source/target 投票のためのチェックポイント境界を置くためだけであり、
 * 4 であれば数回のスロット進行のうちに finality が可視になる。
 */
export const SLOTS_PER_EPOCH = 4;

export function epochOf(slot: SlotIndex): EpochIndex {
  return Math.floor(slot / SLOTS_PER_EPOCH);
}

export function epochBoundarySlot(epoch: EpochIndex): SlotIndex {
  return epoch * SLOTS_PER_EPOCH;
}

export function slotsSinceEpochStart(slot: SlotIndex): number {
  return slot - epochBoundarySlot(epochOf(slot));
}

/**
 * fork choice の起点が競合する justified チェックポイントへ切り替わり
 * 得るエポック先頭区間(justified チェックポイント切替の window):
 * Ethereum の SAFE_SLOTS_TO_UPDATE_JUSTIFIED はそのエポックの 4 分の 1
 * であり、これはこのモデルの 4 スロットのうちの 1 スロットに当たる。
 */
export const JUSTIFIED_SWITCH_WINDOW_SLOTS = 1;

export function inJustifiedSwitchWindow(slot: SlotIndex): boolean {
  return slotsSinceEpochStart(slot) < JUSTIFIED_SWITCH_WINDOW_SLOTS;
}

/**
 * `head` に至る枝上での `epoch` のチェックポイント: その枝上でスロットが
 * エポックの境界スロット以下である直近のブロック(境界スロットのブロック、
 * または境界スロットが空であればその直近の祖先 — その場合は同じブロックが
 * 連続するエポックのチェックポイントとなる)。
 */
export function checkpointFor(
  tree: BlockTree,
  head: BlockIndex,
  epoch: EpochIndex,
): Checkpoint {
  const boundary = epochBoundarySlot(epoch);
  for (const block of pathToAnchor(tree, head)) {
    if (block.slot <= boundary) return { epoch, block: block.index };
  }
  return { ...ANCHOR_CHECKPOINT, epoch };
}

/** `checkpoint` が `head` に至る枝上でそのエポックのチェックポイントに
 * 一致するか否か — その枝上で投票の FFG リンクが数えられる条件。 */
export function isCheckpointOn(
  tree: BlockTree,
  head: BlockIndex,
  checkpoint: Checkpoint,
): boolean {
  return checkpointFor(tree, head, checkpoint.epoch).block === checkpoint.block;
}
