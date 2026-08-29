/**
 * The domain layer's source files, bundled verbatim at build time. The type
 * catalog (型一覧) derives from these strings, so its content always matches
 * the shipped implementation — a new domain module joins the catalog with no
 * further wiring.
 */

const raw = import.meta.glob('../domain/*.ts', {
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
