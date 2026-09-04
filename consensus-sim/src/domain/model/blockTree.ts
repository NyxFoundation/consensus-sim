// ブロック木 — バリデータの View を構成する中核の値オブジェクト。
// イミュータブル: あらゆる変更は新しい木を返す。決定性はこの層が隠れた状態・
// 時計・乱数を持たないことに依存する。

import { compareBlockIndex } from "./order";
import {
  anchorBlock,
  type Block,
  type BlockIndex,
  type ProposedBlock,
} from "./types";

/** ブロック木。既知の全ブロックの集合を保持する。 */
export interface BlockTree {
  /** 既知の全ブロック、識別子をキーとする。常に錨ブロックを含む。 */
  readonly blocks: ReadonlyMap<BlockIndex, Block>;
}

/** 錨ブロックのみを保持する木。あらゆるバリデータの出発点となる状態。 */
export function createBlockTree(): BlockTree {
  const anchor = anchorBlock();
  return { blocks: new Map([[anchor.index, anchor]]) };
}

export function getBlock(tree: BlockTree, index: BlockIndex): Block | undefined {
  return tree.blocks.get(index);
}

/**
 * 提案ブロックを追加する。parent が未知であるブロック、既に異なる内容で
 * 存在する識別子を持つブロック、スロットが parent のスロットより後で
 * ないブロックは拒否する。同一の重複を追加するのは no-op である。
 * バリデータが同じブロックを正当に 2 度受信することがあり得るからだ。
 * 根となるのは常に錨のみであり、それは最初から存在する。
 */
export function addBlock(tree: BlockTree, block: ProposedBlock): BlockTree {
  const existing = tree.blocks.get(block.index);
  if (existing) {
    if (
      existing.kind === "proposed" &&
      existing.parent === block.parent &&
      existing.slot === block.slot &&
      existing.proposer === block.proposer
    ) {
      return tree;
    }
    throw new Error(
      `block index ${block.index} already exists with different content`,
    );
  }
  const parent = tree.blocks.get(block.parent);
  if (!parent) {
    throw new Error(`parent block ${block.parent} is unknown`);
  }
  if (block.slot <= parent.slot) {
    throw new Error(
      `block slot ${block.slot} must come after parent slot ${parent.slot}`,
    );
  }
  const blocks = new Map(tree.blocks);
  blocks.set(block.index, block);
  return { blocks };
}

/** `parent` の子ブロックの識別子を、ブロックの順序で(決定的に)返す。 */
export function childrenOf(tree: BlockTree, parent: BlockIndex): BlockIndex[] {
  const children: BlockIndex[] = [];
  for (const block of tree.blocks.values()) {
    if (block.kind === "proposed" && block.parent === parent) children.push(block.index);
  }
  return children.sort(compareBlockIndex);
}

/**
 * `ancestor` が `descendant` から根に至る経路上にあるか否か(自分自身も
 * 自分の祖先に含む)。
 */
export function isAncestor(
  tree: BlockTree,
  ancestor: BlockIndex,
  descendant: BlockIndex,
): boolean {
  let current = tree.blocks.get(descendant);
  while (current) {
    if (current.index === ancestor) return true;
    if (current.kind === "anchor") return false;
    current = tree.blocks.get(current.parent);
  }
  return false;
}

/**
 * `root` を根とする部分木の葉(子を持たないブロック)を、ブロックの順序で
 * 返す — `root` 自身が子を持たなければ `root` のみとなる。
 */
export function leavesUnder(tree: BlockTree, root: BlockIndex): BlockIndex[] {
  const parents = new Set<BlockIndex>();
  for (const block of tree.blocks.values()) {
    if (block.kind === "proposed") parents.add(block.parent);
  }
  const leaves: BlockIndex[] = [];
  for (const block of tree.blocks.values()) {
    if (!parents.has(block.index) && isAncestor(tree, root, block.index)) {
      leaves.push(block.index);
    }
  }
  return leaves.sort(compareBlockIndex);
}

/** `index` から始まり錨ブロックに至るまでの経路。 */
export function pathToAnchor(tree: BlockTree, index: BlockIndex): Block[] {
  const path: Block[] = [];
  let current = tree.blocks.get(index);
  while (current) {
    path.push(current);
    if (current.kind === "anchor") break;
    current = tree.blocks.get(current.parent);
  }
  return path;
}
