# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

`consensus-sim` is a browser simulator for Ethereum consensus protocols, built to support research on
Decoupled Consensus. See `README.md` for the survey of prior art and the roadmap.

Vite + TypeScript (strict) + React + Canvas 2D + Vitest. Dependencies are deliberately limited to
those five — no D3, no chart library, no CSS framework. Add one only with a concrete reason.

## Commands

```bash
npm run dev        # dev server
npm test           # vitest
npm run typecheck  # tsc --noEmit
npm run build      # typecheck + static build
```

`npm run dev` can hit `EMFILE` where inotify instances are scarce; `npm run build && npm run preview`
is the workaround.

## Invariants to preserve

**The core never learns about the DOM.** `src/core/` and `src/protocol/` must stay importable from a
headless runner. React lives only in `src/ui/`, reads the engine, and never mutates it. Breaking this
breaks M5 before it starts.

**Runs are deterministic.** Every stochastic decision draws from a seeded `Rng`. Add a new draw via
`rng.fork('label')`, never from a shared stream, so that introducing one subsystem does not shift
another's sequence and silently change unrelated results. `Date.now()` and `Math.random()` do not
belong anywhere in the engine.

**Nodes do not share state.** Each node owns its `GasperStore`. There is exactly one god view —
`Simulation.blocks` — and it exists solely to draw the fork tree; no node may read it.

**Layers stay pluggable.** New protocols implement `ConsensusLayer` in `src/protocol/`. Do not add a
protocol-specific branch to `Simulation`.

## Mutability

Configuration, messages and anything crossing a boundary are `readonly`. A node's own store is
mutated in place: rebuilding a validator's whole view on each received attestation would dominate
run time at N=1000 and buys no safety, since that store is reachable from one node only.

## Fidelity notes

These are deliberate simplifications; check here before "fixing" one.

- Block roots are FNV-1a, not SSZ + SHA-256. The fork choice never inspects a root's bits.
- Signatures are assumed valid; the envelope's sender is trusted.
- Slot 0 belongs to genesis; proposals start at slot 1.
- Justification is applied at epoch boundaries, not the instant a supermajority appears, so attesters
  within an epoch vote a stable source — as they do reading it from a beacon state.
- Finalization implements the k=1 rule (two consecutive justified epochs).
- Partitions defer cross-group messages until healing rather than dropping them, matching the
  "asynchrony is adversarial delay" model the papers reason in.

## Testing

Vitest, `tests/`. Name tests `should [behaviour] when [condition]`.

Assert simulation state at a quiet point inside a slot, not on a slot boundary: on the boundary the
proposer has applied its own block and nobody else has received it, so every run shows a "head
disagreement" that is only a message in flight.

Where a parameter has a threshold, test both sides of it. A test that passes on one side alone would
also pass against an implementation that always succeeds.

## Language

UI text and inline explanations are Japanese. Code, identifiers, comments, commit messages and PR
descriptions are English.
