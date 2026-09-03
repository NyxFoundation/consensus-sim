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
the validator count (4–10) and the theme control (自動 / ライト / ダーク:
自動 follows the OS colour scheme and is the default; a manual choice is
remembered in the browser). Every colour, spacing, type size and typeface
comes from one token sheet (`src/ui/tokens.css`), the typefaces are a
deliberately chosen system set for Japanese, English and monospaced
(numbers, IDs, slots) text with no external font service, and every form
control is one of the app's own unified components. The header tabs
switch between three displays and the type catalog:

- **チェーン表示** — the block tree with every validator's information
  overlaid (heads, latest votes, J/F checkpoint badges). Below it, the
  **state table** (状態表) lines its slot columns up with the tree: one row
  per validator, the cell item (head / justified / finalized / latest vote /
  stake / view element counts) selectable from the UI, cells that disagree
  with the other validators highlighted, and any cell expandable into that
  validator's full local observation at that slot — head, the **chain
  state** of that head (every validator's stake, justified, finalized, with
  entries that disagree with the other validators' heads highlighted, so
  two validators on different branches show their divergence), the head
  block's **body** (the votes and equivocation evidence it included), the
  block tree, and every vote it has seen (equivocating double votes listed
  individually) with the block each vote supported.
- **ネットワーク表示** — one card per validator (operating state, head /
  justified / finalized / latest vote at a glance); hover a card to see
  that validator's own block tree.
- **全体表示** — chain on the left, network on the right.
- **型一覧** — the domain layer's exported types as a top-down dependency
  graph (types depending on no other type on the top row). The catalog is
  extracted from the domain source bundled verbatim into the app, so what
  it shows is exactly what the implementation defines; selecting a type
  shows its declaration and its dependency links.

The プロトコルパラメータ panel below the slot bar holds the scenario's
initial conditions: a preset (`phase0` / `merge` / `current`, default
`merge`) that sets every value at once, and each protocol parameter on its
own — committee (everyone, size `c`, or an epoch split), proposer boost, fork-choice rule,
equivocation discount, justified-checkpoint switching, slashing and the
inactivity leak (on/off, `N`, `r`) — plus the seed and every validator's
initial stake (equal by default). Changing a value recomputes the displayed
run from the anchor with the interventions kept, so the effect of one knob
is read off the same run; the preset label turns to カスタム as soon as a
value departs from every preset.

The 介入 panel between the slot bar and the mode body injects disturbances
at the next slot boundary: partition a validator set (分断), switch a
validator's operating state (稼働状態 — 稼働 / 停止 = silent but still
receiving / オフライン = fully cut off with a frozen view that catches up
through normal propagation after returning), schedule a double proposal or
double vote (equivocation), delay or drop one specific message for a chosen
receiver set (default: everyone but the sender), create a fork by
designating the next proposal's parent from the proposer's own view
(フォーク作成 — the **fork count** is the number of leaves under the latest
finalized block of the god view, and a designation is refused when that
count, plus what the pending designations and this one add, would exceed 4;
finality advancing past the forks frees the limit again, and forks arising
from other interventions are never constrained), steer one validator's next vote (投票先指定
— head / source / target chosen among the blocks of its own view, the rest
following fork choice and the FFG rule), and make the next proposer leave
chosen votes or evidence out of its block (取り込みの省略 — they stay
includable by a later block). Scheduled
interventions stay listed — healing, resuming or deleting one recomputes
the whole displayed history deterministically. The ◀ / ▶ cursor rewinds to
any past slot and reproduces that state exactly; advancing from a past slot
truncates the discarded future.

The シナリオ panel saves the current run — initial conditions plus the
intervention list and how far it advanced — to a browser-local list, and
reloading replays it deterministically to the identical states. The
protocol parameters, the seed and the initial stakes are part of the saved
identity, and the list shows each entry's preset.

Sanity check:

```bash
npm test           # vitest — model, chain state, fork choice, protocol params, stakes and penalties, attack execution and goal judgment, determinism, rewind, UI shell
npm run typecheck  # tsc --noEmit
npm run build      # static bundle in dist/ (no backend; plain static SPA)
```

## The model

- **Validators** (4–10, default 4) act as proposers and attesters, and carry
  recognizable katakana names (アリス, ボブ, キャロル, …) throughout the UI.
  Time advances in slots; epoch boundaries fall every 4 slots. The proposer
  of a slot (round-robin) and its **committee** — everyone; `c` validators
  drawn per slot from the seed; or an **epoch split**, Ethereum's committee
  structure, in which every validator attests in exactly one seed-assigned
  slot of each epoch — derive deterministically from (slot, protocol
  parameters, seed) and are public to every validator.
- **Protocol parameters** (`ProtocolParams`) make the skeleton's knobs
  explicit: committee assignment, proposer boost, fork-choice rule (GHOST /
  LMD-GHOST), equivocation discount, justified-checkpoint switching
  (window / unrealized / off), slashing and inactivity leak. Three
  **presets** name real points of Ethereum's history — `phase0` (no boost,
  no discount), `merge` (boost 0.4, discount on; the default) and `current`
  (unrealized justification) — and an attack later declares its premise as
  a preset plus overrides. The parameters are part of the scenario and are
  saved with it.
- **Blocks** form a tree rooted at the **anchor block** (slot 0), which every
  validator already agrees is finalized — there is no genesis ceremony. A
  block carries a **body**: the votes and equivocation evidence its proposer
  included. An honest proposer includes everything in its view that no
  ancestor of the parent has included yet.
- **Votes** are `{validator, slot, head, source, target}`: an LMD-GHOST-style
  head endorsement plus an FFG-style pair of **checkpoints**. A checkpoint
  is `{epoch, block}` — the latest block of a branch at or before the
  epoch's first slot; when that boundary slot is empty the same block stands
  for consecutive epochs, so the epoch is part of the identity (the UI
  writes a checkpoint as `B4@e1`). Identifiers are distinct sorts
  (validator, slot, epoch, block index, stake) that the type checker keeps
  apart; the block index carries identity only, and the one total order
  used for every tie-break is a stated rule of the skeleton.
- **Chain state** is derived per block from the bodies along its branch and
  the initial stakes: `{stakes, justified, finalized}`, both checkpoints. A
  vote counts as an FFG link of a branch only once a block on that branch
  includes it and only when its source and target are that branch's own
  checkpoints of their epochs, so the same vote set can justify one branch
  and be inert on another.
- **Stakes** start equal (32 each, settable per validator as part of the
  scenario) and live in chain state, never in a view. **Finality** follows
  supermajority source→target links over included votes — 2/3 of the
  branch's stake, not of its validators (justification fixpoint; a justified
  source is finalized when its target of the very next epoch, by epoch
  number, is justified). Two **penalties** reshape a branch's stakes:
  **slashing** zeroes an equivocator from the block that includes the
  evidence onward (a branch without the evidence is untouched), and the
  **inactivity leak** removes the fraction `r` per epoch from every
  validator whose target vote for that epoch the branch has not included,
  once finality lags by more than `N` epochs, stopping as soon as finality
  catches up. Both are protocol parameters; Ethereum's quadratic amounts and
  rewards are deliberately absent.
- **Fork choice** is GHOST over each validator's own view (the message
  layer), starting from the highest justified checkpoint it knows. A vote
  weighs the voter's stake in the chain state of the head it votes for, so
  a penalty included on a branch bites exactly there. The **proposer boost**
  adds committee weight × boost to the current slot's proposal — in that
  slot's fork choice only, and only for validators that received it during
  the slot; a proposal delivered late is never boosted. A validator's
  justified / finalized / stakes are the chain state of its head (the
  inclusion layer).
- **Mitigations** are three more protocol parameters, each following
  Ethereum's rule in simplified form. The **fork-choice rule** decides which
  votes count: LMD-GHOST only each validator's latest, GHOST every vote (so
  stale votes and both halves of a double vote keep their weight). The
  **equivocation discount** zeroes a validator's votes in the fork choice of
  any view that holds two conflicting votes of it for one slot — immediate,
  local to that view, and fork choice only; chain state waits for slashing.
  **Justified-checkpoint switching** governs the fork-choice root: `off`
  always starts from the highest justified checkpoint known; `window` lets
  the root move to a conflicting justified checkpoint only in the first slot
  of an epoch (a quarter of the epoch, as in Ethereum), while a newer
  checkpoint on the root's own chain is adopted at once; `unrealized`
  starts from the highest justified checkpoint but never descends into a
  branch whose included votes justify only an older one.
- **Local views** are pure filters over a global append-only message log: a
  delivery rule decides who has seen what by when. Instant broadcast is the
  default; partitions, delays and drops plug in as stricter delivery rules
  without touching the engine.
- **Attacks** are a formal triple: an **attacker set** (a non-empty subset
  of the validators, fixed by a library attack up to a condition such as a
  stake share), an **attack goal** (a non-empty sequence of god-view
  predicates — safety violation, liveness stall over L slots, k reorgs,
  attacker stake ratio ≥ θ — judged stage by stage) and a **strategy**: a
  pure rule that, at every slot boundary, maps what the attackers observe
  (the merge of their views — attackers share everything instantly — and
  the proposer schedule) to their actions for the slots ahead. The action
  vocabulary is the intervention set within a capability range: an
  attacker's own equivocation, parent designation, vote designation,
  silence, withholding and selective delivery of its own messages
  (referenced ahead of publication), omitted inclusion in its own
  proposal, and delay / drop / partition of honest messages, delays bounded
  by the attack's `maxDelay`. A scenario holds at most one attack beside
  its manual interventions; the strategy's actions are generated as
  interventions marked as the attackers', and an action that is not
  causal, outside the range, contradicted by a manual intervention of the
  same slot and validator (the manual one wins) or past the fork limit is
  discarded — kept in the list with its reason. Generated actions are never
  saved: replaying the scenario regenerates them identically. The goal is
  judged from the god view at every slot: a stage is judged only once the
  stage before it is achieved, and every verdict carries its evidence (the
  conflicting finalized checkpoints, the slots finality has stalled, the
  reorg count and latest event, the stake ratio and the head it is read at).
- **Determinism and rewind:** the state at slot *n* is recomputed from the
  anchor, never replayed from mutable history — the same scenario always
  reproduces the same run, and rewinding is just recomputation.

## Development

```
src/domain/        pure TypeScript domain layer — no React, no DOM, no I/O
src/domain/model/  essential specification (本質的仕様): the types a formalization
                   takes as its object — the identifier sorts / Checkpoint / View /
                   Vote / Block (anchor | proposed) / BlockTree / Equivocation /
                   ChainState / ProtocolParams and presets, the skeleton's total
                   orders, fork choice, finality, inclusion, the schedule, the
                   initial conditions, the attack triple, the action vocabulary and
                   the goal predicates
src/domain/sim/    simulation constraints (シミュレーション上の制約): message log
                   and delivery, the slot driver, interventions, attack execution
                   (generated actions and their discards), scenarios and their
                   codec, validator names and the 4–10 bound, the fork limit
src/ui/            React shell and SVG views, consuming only src/domain exports
tests/domain/      model tests (incl. an import-purity test that fences the boundaries)
tests/ui/          layout and DOM-level shell tests (jsdom)
```

The domain layer is the product's core: UI code imports from `src/domain`
and never the other way around, and inside the layer `sim/` may import
`model/` but never the reverse (`tests/domain/purity.test.ts` enforces both
mechanically). The 型一覧 tab catalogs `model/` only. More concrete
abstraction levels (delta/discrete-event timing, full Gasper semantics,
stochastic networks) are future additions the boundary is designed not to
obstruct.

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
