// Block tree (ブロック木) — the core value object of a validator's view.
// Immutable: every mutation returns a new tree. Determinism (決定性) depends
// on this layer being free of hidden state, clocks, and randomness.

import {
  ANCHOR_BLOCK_INDEX,
  NO_PARENT,
  anchorBlock,
  type Block,
  type BlockIndex,
} from "./types";

export interface BlockTree {
  /** All known blocks, keyed by index. Always contains the anchor block. */
  readonly blocks: ReadonlyMap<BlockIndex, Block>;
}

/** A tree holding only the anchor block, the state every validator starts from. */
export function createBlockTree(): BlockTree {
  const anchor = anchorBlock();
  return { blocks: new Map([[anchor.index, anchor]]) };
}

export function getBlock(tree: BlockTree, index: BlockIndex): Block | undefined {
  return tree.blocks.get(index);
}

export function hasBlock(tree: BlockTree, index: BlockIndex): boolean {
  return tree.blocks.has(index);
}

/**
 * Add a block. Rejects blocks whose parent is unknown, whose index is
 * already present with different content, or whose slot does not come after
 * its parent's slot. Adding an identical duplicate is a no-op, because a
 * validator may legitimately receive the same block twice.
 */
export function addBlock(tree: BlockTree, block: Block): BlockTree {
  const existing = tree.blocks.get(block.index);
  if (existing) {
    if (
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
  if (block.index === ANCHOR_BLOCK_INDEX || block.parent === NO_PARENT) {
    throw new Error("only the anchor block may be a root");
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

/** Child block indices of `parent`, in ascending index order (deterministic). */
export function childrenOf(tree: BlockTree, parent: BlockIndex): BlockIndex[] {
  const children: BlockIndex[] = [];
  for (const block of tree.blocks.values()) {
    if (block.parent === parent) children.push(block.index);
  }
  return children.sort((a, b) => a - b);
}

/**
 * Whether `ancestor` is on the path from `descendant` to the root
 * (inclusive: a block is its own ancestor).
 */
export function isAncestor(
  tree: BlockTree,
  ancestor: BlockIndex,
  descendant: BlockIndex,
): boolean {
  let current = tree.blocks.get(descendant);
  while (current) {
    if (current.index === ancestor) return true;
    if (current.parent === NO_PARENT) return false;
    current = tree.blocks.get(current.parent);
  }
  return false;
}

/** The path from `index` up to the anchor block, starting at `index`. */
export function pathToAnchor(tree: BlockTree, index: BlockIndex): Block[] {
  const path: Block[] = [];
  let current = tree.blocks.get(index);
  while (current) {
    path.push(current);
    if (current.parent === NO_PARENT) break;
    current = tree.blocks.get(current.parent);
  }
  return path;
}

/** Blocks with no children — the candidate heads, in ascending index order. */
export function leafIndices(tree: BlockTree): BlockIndex[] {
  const hasChild = new Set<BlockIndex>();
  for (const block of tree.blocks.values()) {
    if (block.parent !== NO_PARENT) hasChild.add(block.parent);
  }
  const leaves: BlockIndex[] = [];
  for (const block of tree.blocks.values()) {
    if (!hasChild.has(block.index)) leaves.push(block.index);
  }
  return leaves.sort((a, b) => a - b);
}
