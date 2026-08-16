/**
 * Content addressing for blocks.
 *
 * Real consensus uses SSZ + SHA-256. That is deliberately out of scope (the
 * fork choice never inspects a root's bits, it only needs distinct, stable,
 * comparable identifiers), so this is a 64-bit FNV-1a rendered as hex. At the
 * few-thousand-block scale a simulation reaches, collision probability is
 * negligible.
 */

export type Hash = string

const FNV_OFFSET_A = 0x811c9dc5
const FNV_OFFSET_B = 0x1000193
const FNV_PRIME = 0x01000193

function fnv1a(input: string, offset: number): number {
  let h = offset >>> 0
  for (let i = 0; i < input.length; i++) {
    h = Math.imul(h ^ input.charCodeAt(i), FNV_PRIME) >>> 0
  }
  return h >>> 0
}

/** Stable 16-hex-character digest of a string. */
export function digest(input: string): Hash {
  const hi = fnv1a(input, FNV_OFFSET_A)
  const lo = fnv1a(input, FNV_OFFSET_B)
  return hi.toString(16).padStart(8, '0') + lo.toString(16).padStart(8, '0')
}

/** The all-zero root, used as the parent of genesis and as "no block". */
export const ZERO_HASH: Hash = '0000000000000000'

/** A short, human-readable prefix for labels and tooltips. */
export function shortHash(hash: Hash): string {
  return hash.slice(0, 6)
}
