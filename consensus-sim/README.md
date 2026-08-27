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
views, deterministic slot driver, interventions compiled onto the
delivery/directives axes) is complete and fully tested. The UI ships all
three modes — chain (local / god perspectives), network (per-validator
cards with hover views) and global (chain + network side by side) — plus
the intervention panel (partition, stop/resume, equivocation, per-message
delay/drop), slot rewind, and scenario save/reload/replay (localStorage
list plus JSON export/import); the remaining work is the final
no-manual-needed UX polish pass.

## Quickstart

```bash
npm install
npm run dev        # http://localhost:5173
```

Open the page, press **＋1 スロット進める** to advance a slot, and watch the
proposal, the votes and each validator's head update. Three modes are
available from the header tabs:

- **チェーンモード** — the block tree, switchable between 局所視点 (one
  validator's view) and 神視点 (the overlay of everyone's information);
  pick a validator to inspect its block tree, latest votes, head and
  justified/finalized checkpoints.
- **ネットワークモード** — one card per validator (head / justified /
  finalized / latest vote at a glance); hover a card to see that
  validator's own block tree.
- **全体モード** — chain on the left, network on the right.

The 介入 panel between the slot bar and the mode body injects disturbances
at the next slot boundary: partition a validator set (分断), stop and
resume validators (停止/復帰), schedule a double proposal or double vote
(equivocation), and delay or drop one specific message. Scheduled
interventions stay listed — healing, resuming or deleting one recomputes
the whole displayed history deterministically. The ◀ / ▶ cursor rewinds to
any past slot and reproduces that state exactly; advancing from a past slot
truncates the discarded future.

The シナリオ panel saves the current run — initial conditions (seed
included) plus the intervention list and how far it advanced — to a
browser-local list, and reloading replays it deterministically to the
identical states. JSON エクスポート/インポート exchanges the same
versioned format as a file.

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
