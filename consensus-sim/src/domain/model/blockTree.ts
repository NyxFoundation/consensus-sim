// Block tree (ブロック木) — the core value object of a validator's view.
// Immutable: every mutation returns a new tree. Determinism (決定性) depends
// on this layer being free of hidden state, clocks, and randomness.

import { compareBlockIndex } from "./order";
import {
  anchorBlock,
  type Block,
  type BlockIndex,
  type ProposedBlock,
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

/**
 * Add a proposed block. Rejects blocks whose parent is unknown, whose index
 * is already present with different content, or whose slot does not come
 * after its parent's slot. Adding an identical duplicate is a no-op, because
 * a validator may legitimately receive the same block twice. Only the
 * anchor is ever a root, and it is there from the start.
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

/** Child block indices of `parent`, in the block order (deterministic). */
export function childrenOf(tree: BlockTree, parent: BlockIndex): BlockIndex[] {
  const children: BlockIndex[] = [];
  for (const block of tree.blocks.values()) {
    if (block.kind === "proposed" && block.parent === parent) children.push(block.index);
  }
  return children.sort(compareBlockIndex);
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
    if (current.kind === "anchor") return false;
    current = tree.blocks.get(current.parent);
  }
  return false;
}

/**
 * Leaves (blocks without children) of the subtree rooted at `root`, in the
 * block order — `root` itself when it has no children.
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

/** The path from `index` up to the anchor block, starting at `index`. */
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
