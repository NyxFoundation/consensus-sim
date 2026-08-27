# consensus-sim

An in-browser laboratory for understanding consensus algorithms through a
**most-abstract model**: validators, blocks and votes, advancing slot by
slot, with every validator's local view individually observable.

Instead of simulating network fidelity, the simulator is built for
*exhaustive observation and manipulation*: a fully deterministic model whose
state at any slot is a pure function of the scenario, so any run can be
replayed, rewound and inspected from any validator's point of view. The UI
text is Japanese; code and documentation are English.

**Status:** the domain layer (block tree, LMD-GHOST fork choice,
justification/finality over source→target checkpoints, per-validator local
views, deterministic slot driver) is complete and fully tested. The UI
currently ships the chain mode (local / god perspectives) with slot
advancing; network mode, global mode, interventions, rewind UI and scenario
persistence are next.

## Quickstart

```bash
npm install
npm run dev        # http://localhost:5173
```

Open the page, press **＋1 スロット進める** to advance a slot, and watch the
proposal, the votes and each validator's head update. Switch between
局所視点 (one validator's view) and 神視点 (the overlay of everyone's
information), and pick a validator to inspect its block tree, latest votes,
head and justified/finalized checkpoints.

Sanity check:

```bash
npm test           # vitest — model, fork choice, finality, determinism, rewind, UI shell
npm run typecheck  # tsc --noEmit
npm run build      # static bundle in dist/ (no backend; plain static SPA)
```

## The model

- **Validators** (4–10, default 4) act as proposers and attesters in a
  round-robin schedule. Time advances in slots; epoch boundaries fall every
  4 slots.
- **Blocks** form a tree rooted at the **anchor block** (slot 0), which every
  validator already agrees is finalized — there is no genesis ceremony.
- **Votes** are `{validator, slot, head, source, target}`: an LMD-GHOST-style
  head endorsement plus an FFG-style pair of epoch-boundary checkpoints.
- **Fork choice** is GHOST over each validator's own view, starting from its
  justified checkpoint; **finality** follows supermajority source→target
  links (justification fixpoint, adjacent-epoch finalization).
- **Local views** are pure filters over a global append-only message log: a
  delivery rule decides who has seen what by when. Instant broadcast is the
  default; partitions, delays and drops plug in as stricter delivery rules
  without touching the engine.
- **Determinism and rewind:** the state at slot *n* is recomputed from the
  anchor, never replayed from mutable history — the same scenario always
  reproduces the same run, and rewinding is just recomputation.

## Development

```
src/domain/   pure TypeScript domain layer — no React, no DOM, no I/O
src/ui/       React shell and SVG views, consuming only src/domain exports
tests/domain/ model tests (incl. an import-purity test that fences the boundary)
tests/ui/     layout and DOM-level shell tests (jsdom)
```

The domain layer is the product's core: UI code imports from `src/domain`
and never the other way around (`tests/domain/purity.test.ts` enforces
this mechanically). More concrete abstraction levels (delta/discrete-event
timing, full Gasper semantics, stochastic networks) are future additions
the boundary is designed not to obstruct.

`scripts/verify-ui.mjs` smoke-drives the built bundle in a real Chromium
via Playwright (`npx playwright install chromium` once, then
`npm run build && node scripts/verify-ui.mjs`). The jsdom test suite covers
the same interactions headlessly and runs in `npm test`.
