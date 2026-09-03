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
intervention at once), and the UI ships the two pages described below with
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
proposal, the votes and each validator's head update.

The screen is laid out as an instrument: one header bar (display tabs,
validator count 4–10, theme), a **stage** on the left and the **operation
dock** (操作盤) on the right. The stage carries the slot bar — cursor,
rewind, advance — and the selected display; on a standard PC width the
chain display and the state table fill it from the first paint, with about
ten slot columns visible before horizontal scrolling. The dock is a fixed
narrow column holding every other control (protocol parameters,
interventions, scenarios) as collapsible sections, each opening with a
one-line summary. Panels carry no resident explanations: an **ⓘ** next to a
title or a group shows its note on hover or keyboard focus. The theme
control offers 自動 / ライト / ダーク (自動 follows the OS colour scheme and
is the default; a manual choice is remembered in the browser). Every
colour, spacing, type size and typeface comes from one token sheet
(`src/ui/tokens.css`), the typefaces are a deliberately chosen system set
for Japanese, English and monospaced (numbers, IDs, slots) text with no
external font service, and every form control is one of the app's own
unified components. The header tabs switch between the two pages:

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
- **型一覧** — the essential specification's exported types as a top-down
  dependency graph (types depending on no other type on the top row). The
  page has its own layout: only the header bar frames it (no slot bar, no
  dock, no validator count), the graph takes about four fifths of the width
  and the focused type the remaining fifth. One type is always in focus —
  the first type of the top row when the page opens — and the focus pane
  shows its verbatim declaration with its comment, the types it depends on
  and the types that depend on it; selecting any of those, or a node of the
  graph, moves the focus. The catalog is extracted from the domain source
  bundled verbatim into the app, so what it shows is exactly what the
  implementation defines. The essential specification (`src/domain/model`)
  is commented in Japanese — identifiers stay English — so every type on
  the page reads with its Japanese description; the rest of the code base
  keeps English comments. There is no network or overview display: every
  validator's own state and view is observed through the state table's
  cell expansion.

The プロトコルパラメータ section of the dock holds the scenario's
initial conditions: a preset (`phase0` / `merge` / `current`, default
`merge`) that sets every value at once, and each protocol parameter on its
own — committee (everyone, size `c`, or an epoch split), proposer boost, fork-choice rule,
equivocation discount, the two justified-checkpoint switches (window,
unrealized), slashing and the inactivity leak (off, or `N` and `r`) — plus the seed and every validator's
initial stake (equal by default). Changing a value recomputes the displayed
run from the anchor with the interventions kept, so the effect of one knob
is read off the same run; the preset label turns to カスタム as soon as a
value departs from every preset.

The 介入 section of the dock injects disturbances at the next slot
boundary: partition a validator set (分断), switch a
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

The 攻撃 section of the dock binds one attack of the library into the
scenario. Choosing an attack proposes its **default run** (既定実行構成) as
the scenario's initial conditions — validator count, initial stakes, seed,
the premise's protocol parameters (preset plus overrides), the attacker
set, the attack parameters (`d` and the strategy's own) and the end slot —
each of which can then be changed: the attacker set from the validators
(the declared condition is read out and an unmet one is marked 条件未満
while the attack stays runnable), the parameters, the end slot, and the
protocol parameters in their own section (a departure from the premise is
read out with a way back, so a mitigation can be switched on to watch the
attack miss). From then on every slot boundary runs the strategy: its
actions join the intervention list marked 攻撃者 (a discarded one stays
listed, struck through, with its reason), the attackers' rows in the state
table and their blocks and chips in the tree carry the attacker mark, and
a **goal trace** between the tree and the state table shows every stage of
the attack goal per slot — the predicate's indicator (stalled slots, reorg
count, stake ratio, conflicting checkpoints), whether it holds, and the
slot the stage was achieved at, with the full grounds on hover.

The シナリオ section of the dock saves the current run — initial conditions plus the
manual intervention list, the attack (by id, attacker set and parameters;
generated actions are never saved) and how far it advanced — to a
browser-local list, and reloading replays it deterministically to the
identical states, generated actions and verdicts. The protocol parameters,
the seed and the initial stakes are part of the saved identity, and the
list shows each entry's preset and attack.

Sanity check:

```bash
npm test           # vitest — model, chain state, fork choice, protocol params, stakes and penalties, attack execution and goal judgment, determinism, rewind, UI shell, design contract
npm run typecheck  # tsc --noEmit
npm run build      # static bundle in dist/ (no backend; plain static SPA)
```

The design contract is machine-checked in the suite: the token sheet is
the only source of colour / spacing / type / typeface values and no style
declares a literal of its own (`tests/ui/designTokens.test.ts`), no native
form control renders outside the unified components, the frame's tokens
give the chain display and the state table more than half of a standard
PC viewport (`tests/ui/layout.test.ts`), and no panel holds a sentence of
resident prose — explanations live only in ⓘ hints
(`tests/ui/prose.test.tsx`). `scripts/verify-ui.mjs` measures the same
contract in a real browser (see Development).

## The model

- **Validators** (4–10, default 4) act as proposers and attesters, and carry
  recognizable katakana names (アリス, ボブ, キャロル, …) throughout the UI.
  Time advances in slots, each with three **instants** — proposal, vote,
  end — and epoch boundaries fall every 4 slots. The **initial conditions**
  (validator count, initial stakes, protocol parameters, seed) determine
  the **schedule**: the proposer of a slot (round-robin) and its
  **committee** — everyone; `c` validators drawn per slot from the seed; or
  an **epoch split**, Ethereum's committee structure, in which every
  validator attests in exactly one seed-assigned slot of each epoch. The
  schedule is public to every validator; the model states only the
  structure of each assignment, the seeded permutation it is drawn with
  belongs to the simulator.
- **Protocol parameters** (`ProtocolParams`) make the skeleton's knobs
  explicit: committee assignment, proposer boost, fork-choice rule (GHOST /
  LMD-GHOST), equivocation discount, justified-checkpoint switching (two
  independent switches: window, unrealized), slashing and inactivity leak
  (`{N, r}` or off). Three **presets** name real points of Ethereum's
  history — `phase0` (no boost, no discount, window on), `merge` (boost
  0.4, discount on, window on; the default) and `current` (unrealized on
  instead of the window) — and an attack declares its premise as a preset
  plus overrides. The parameters are part of the scenario and are saved
  with it.
- **Blocks** form a tree rooted at the **anchor block** (slot 0), which every
  validator already agrees is finalized — there is no genesis ceremony. A
  block carries a **body**: the votes and equivocation evidence its proposer
  included. An honest proposer includes everything in its view that no
  ancestor of the parent has included yet. **Evidence** is a pair of
  conflicting messages of one validator in one of three forms — a double
  proposal (two blocks of one slot), a double vote (two votes of one slot
  with different content, or two votes with the same target epoch and
  different targets) and a surround vote (a later vote whose source →
  target span strictly encloses an earlier one's in epochs) — the last two
  being Casper FFG's slashing conditions. Evidence is not a message of its
  own: it comes into existence in any view that holds both messages (the
  god view included), and a validator that repeats the same FFG part
  through an epoch, as honest validators do, produces none.
- **Votes** are `{validator, slot, head, source, target}`: an LMD-GHOST-style
  head endorsement plus an FFG-style pair of **checkpoints**. The head
  follows fork choice every slot; the FFG pair is decided once per epoch —
  in the first slot a validator votes in during the epoch, read off its
  head's chain — and repeated in its later votes of that epoch, so an
  honest validator never contradicts its own FFG vote (Ethereum attests
  once per epoch). A checkpoint
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
  evidence — of any of its three forms — onward (a branch without the
  evidence is untouched), and the **inactivity leak**, when on, removes the
  fraction `r` per epoch from every validator whose target vote for that
  epoch the branch has not included, once finality lags by more than `N`
  epochs, stopping as soon as finality catches up. Both are protocol
  parameters; Ethereum's quadratic amounts and rewards are deliberately
  absent.
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
  any view that holds vote evidence against it (a double vote or a surround
  vote) — immediate, local to that view, and fork choice only; chain state
  waits for slashing. **Justified-checkpoint switching** is two independent
  switches on the fork-choice root: with both off the root is always the
  highest justified checkpoint known; the **window** lets the root move to a
  conflicting justified checkpoint only in the first slot of an epoch (a
  quarter of the epoch, as in Ethereum), while a newer checkpoint on the
  root's own chain is adopted at once; **unrealized** keeps the root but
  never descends into a branch whose included votes justify only an older
  one. Ethereum introduced the window first and unrealized justification
  later, both against bouncing.
- **Local views** are pure filters over a global append-only message log: a
  **view** is `{blockTree, votes}`, the knowledge read for one validator at
  one instant (both are the view's coordinates, not its content — the
  merge of several attackers' views is a view too). A block is published
  at the proposal instant, votes at the vote instant, and a delivery rule
  decides who has seen what by when. Instant broadcast is the default;
  partitions, delays and drops plug in as stricter delivery rules without
  touching the engine. A **message reference** names a message by sender,
  slot and kind (proposal / vote), plus — once published — the individual
  (the block index, or the whole vote); without the individual it names
  everything of that sender and slot, which is how an attacker's strategy
  withholds or selectively delivers a message that does not exist yet.
- **Attacks** are a formal triple: an **attacker set** (a non-empty subset
  of the validators, fixed by a library attack up to a condition such as a
  stake share), an **attack goal** (a non-empty sequence of god-view
  predicates — safety violation, liveness stall over L slots, k reorgs,
  attacker stake ratio ≥ θ — judged stage by stage) and a **strategy**: a
  pure rule that, at every slot boundary, maps what the attackers observe
  (the merge of their views — attackers share everything instantly — and
  the schedule) to their actions for the slots ahead. An attacker's
  capability range is two **bases**: *publish* — a message of its own,
  with any content it can build from its observation (no forgery), at any
  time, to any receiver set (withholding, selective delivery and silence
  included) — and *deliver* — an honest message held back at most `d`
  slots, or dropped, per receiver. The action vocabulary is the intervention
  set as sugar over the bases: an attacker's own equivocation (a double vote
  may split its two halves between two receiver sets), parent designation,
  vote designation, silence, withholding and selective delivery of its own
  messages (referenced ahead of publication), omitted inclusion in its own
  proposal, and delay / drop / partition of honest messages — a partition
  being the symmetric set of deliveries, so a closed one must heal within
  `d`. The attack's **premise** declares the protocol parameters it holds
  under (a preset plus overrides) and `d`. A scenario holds at most one attack beside
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
  The safety violations of the library are accountable: by the slot the
  violation is judged, the god view holds FFG evidence (double or surround
  votes) of attackers worth at least a third of the stake, and a branch
  that includes it slashes them — the honest chain in the history
  domination, the healed network in the double finality — while the
  attackers' own proposals leave it out.
- **Determinism and rewind:** the state at slot *n* is recomputed from the
  anchor, never replayed from mutable history — the same scenario always
  reproduces the same run, and rewinding is just recomputation.

## Development

```
src/domain/        pure TypeScript domain layer — no React, no DOM, no I/O
src/domain/model/  essential specification (本質的仕様): the types a formalization
                   takes as its object — the identifier sorts / Checkpoint / the
                   instants and the coordinate-free View / Vote / Block (anchor |
                   proposed) / BlockTree / Equivocation / ChainState /
                   ProtocolParams and presets / the initial conditions and the
                   schedule they determine / message references, the skeleton's
                   total orders, fork choice, finality, inclusion, the attack
                   triple, the action vocabulary and the goal predicates
src/domain/sim/    simulation constraints (シミュレーション上の制約): message log
                   and delivery, the seeded permutation the schedule is drawn
                   with, the slot driver, interventions, attack execution
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
`npm run build && node scripts/verify-ui.mjs`). Besides the shell
interactions it measures the visual contract at 1280×720, 1440×900 and
1920×1080: the chain display and state table cover more than half of the
first paint without scrolling and ten slot columns fit, every form control
has `appearance: none`, no sentence is rendered as resident text and an ⓘ
tooltip appears on hover inside the viewport, the theme follows the
emulated OS scheme and a manual choice overrides it, and the text and
monospaced typeface roles are applied. The jsdom test suite covers the same
interactions headlessly and runs in `npm test`.

### Deploying to GitHub Pages

The site is published at `https://nyxfoundation.github.io/consensus-sim/`
by a GitHub Actions workflow kept at the repository root
(`.github/workflows/deploy.yml`, outside this directory). On every push to
`main` it runs, inside `consensus-sim/`:

```bash
npm ci
npm test
npm run build
```

and publishes `dist/` only when all three succeed — a commit whose tests or
build fail leaves the previously published version in place. The contract
this directory keeps is therefore: a clean install passes `npm test` and
`npm run build` with exit 0, and `npm run build` emits a fully static
`dist/` whose asset references are relative (`base: './'` in
`vite.config.ts`), so the bundle works from the project subpath (or any
other). To check the contract locally, run the three commands above in a
fresh clone. No server-side configuration is involved; the app is a plain
static SPA with browser-local persistence only.
