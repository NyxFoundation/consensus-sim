# consensus-sim

An in-browser laboratory for understanding consensus algorithms through a
**most-abstract model**: validators, blocks and votes, advancing slot by
slot, with every validator's local view individually observable.

Instead of simulating network fidelity, the simulator is built for
*exhaustive observation and manipulation*: a fully deterministic model whose
state at any slot is a pure function of the scenario, so any run can be
replayed, rewound and inspected from any validator's point of view. The UI
text is Japanese; code and documentation are English.

**Status:** feature-complete for the most-abstract level. The pure domain
layer is fully tested (including adversarial combinations of every
intervention at once), and the UI ships the four tabs described below with
the intervention panel, slot rewind and localStorage-backed scenarios.
Every scenario operation is discoverable from the UI itself: panels
collapse but summarize their contents, empty lists explain the next step,
and the message selector groups the log per publish slot.

## Quickstart

```bash
npm install
npm run dev        # http://localhost:5173
```

Open the page, press **＋1 スロット進める** to advance a slot, and watch the
proposal, the votes and each validator's head update. The header also holds
the validator count (4–10) and a light/dark toggle (light is the default).
The header tabs switch between three displays and the type catalog:

- **チェーン表示** — the block tree with every validator's information
  overlaid (heads, latest votes, J/F checkpoint badges). Below it, the
  **state table** (状態表) lines its slot columns up with the tree: one row
  per validator, the cell item (head / justified / finalized / latest vote /
  view element counts) selectable from the UI, cells that disagree with the
  other validators highlighted, and any cell expandable into that
  validator's full local view at that slot — block tree, every vote it has
  seen (equivocating double votes listed individually) and which block each
  vote supported, head, justified/finalized.
- **ネットワーク表示** — one card per validator (operating state, head /
  justified / finalized / latest vote at a glance); hover a card to see
  that validator's own block tree.
- **全体表示** — chain on the left, network on the right.
- **型一覧** — the domain layer's exported types as a top-down dependency
  graph (types depending on no other type on the top row). The catalog is
  extracted from the domain source bundled verbatim into the app, so what
  it shows is exactly what the implementation defines; selecting a type
  shows its declaration and its dependency links.

The 介入 panel between the slot bar and the mode body injects disturbances
at the next slot boundary: partition a validator set (分断), switch a
validator's operating state (稼働状態 — 稼働 / 停止 = silent but still
receiving / オフライン = fully cut off with a frozen view that catches up
through normal propagation after returning), schedule a double proposal or
double vote (equivocation), delay or drop one specific message, and create
a fork by designating the next proposal's parent from the proposer's own
view (フォーク作成 — the queue holds at most 4 such designations at a time,
so designated forks never exceed 4 at once; forks arising naturally from
other interventions are not capped). Scheduled
interventions stay listed — healing, resuming or deleting one recomputes
the whole displayed history deterministically. The ◀ / ▶ cursor rewinds to
any past slot and reproduces that state exactly; advancing from a past slot
truncates the discarded future.

The シナリオ panel saves the current run — initial conditions plus the
intervention list and how far it advanced — to a browser-local list, and
reloading replays it deterministically to the identical states. A seed is
part of the saved identity for forward compatibility, but the current
skeleton has no random choice, so there is no seed control in the UI yet.

Sanity check:

```bash
npm test           # vitest — model, chain state, fork choice, determinism, rewind, UI shell
npm run typecheck  # tsc --noEmit
npm run build      # static bundle in dist/ (no backend; plain static SPA)
```

## The model

- **Validators** (4–10, default 4) act as proposers and attesters in a
  round-robin schedule, and carry recognizable katakana names (アリス, ボブ,
  キャロル, …) throughout the UI. Time advances in slots; epoch boundaries
  fall every 4 slots.
- **Blocks** form a tree rooted at the **anchor block** (slot 0), which every
  validator already agrees is finalized — there is no genesis ceremony. A
  block carries a **body**: the votes and equivocation evidence its proposer
  included. An honest proposer includes everything in its view that no
  ancestor of the parent has included yet.
- **Votes** are `{validator, slot, head, source, target}`: an LMD-GHOST-style
  head endorsement plus an FFG-style pair of epoch-boundary checkpoints.
- **Chain state** is derived per block from the bodies along its branch and
  the initial stakes: `{stakes, justified, finalized}`. A vote counts toward
  a branch's justification only once a block on that branch includes it, so
  the same vote set can justify one branch and be inert on another.
- **Fork choice** is GHOST over each validator's own view (the message
  layer), starting from the highest justified checkpoint it knows; a
  validator's justified / finalized / stakes are the chain state of its head
  (the inclusion layer). **Finality** follows supermajority source→target
  links over included votes (justification fixpoint, adjacent-epoch
  finalization).
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

`docs/INSPECTION.md` records the pre-release inspection: the
requirement-to-implementation trace, the subtractive design review, and the
adversarial combined-intervention test campaign.

`scripts/verify-ui.mjs` smoke-drives the built bundle in a real Chromium
via Playwright (`npx playwright install chromium` once, then
`npm run build && node scripts/verify-ui.mjs`). The jsdom test suite covers
the same interactions headlessly and runs in `npm test`.

### Deploying to GitHub Pages

`npm run build` emits a fully static `dist/` whose asset references are
relative (`base: './'` in `vite.config.ts`), so the bundle works from any
subpath — including `https://<user>.github.io/<repo>/`. To publish:

1. `npm run build`
2. Serve the `dist/` directory as the Pages site — either point Pages at a
   branch containing `dist/`'s contents (e.g. a `gh-pages` branch), or use
   the "GitHub Actions" source with the standard static-site workflow
   uploading `dist/` as the artifact.

No server-side configuration is involved; the app is a plain static SPA
with browser-local persistence only.
