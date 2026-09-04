/**
 * The source files of the domain layer's model module (本質的仕様 —
 * src/domain/model), bundled verbatim at build time. The type catalog
 * (型一覧) derives from these strings, so its content always matches the
 * shipped implementation — a new model file joins the catalog with no
 * further wiring, and the sim module (シミュレーション上の制約) never appears.
 */

const raw = import.meta.glob('../domain/model/*.ts', {
  query: '?raw',
  import: 'default',
  eager: true,
}) as Record<string, string>

export const DOMAIN_SOURCES: Readonly<Record<string, string>> =
  Object.fromEntries(
    Object.entries(raw).map(([path, source]) => [
      path.replace(/^.*\//, '').replace(/\.ts$/, ''),
      source,
    ]),
  )
