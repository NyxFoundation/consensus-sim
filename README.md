# consensus-sim

An in-browser, parameter-driven simulator for Ethereum's consensus protocols, built to support
research on **Decoupled Consensus** — the proposal to split block production from finality and run a
different protocol in each layer.

The simulator runs individual validators on a discrete-event engine, so nodes genuinely disagree
under delay and partition, and you can watch that disagreement form and resolve.

**Status: M1.** Gasper (LMD-GHOST + Casper FFG) runs end to end, with the fork tree and the
validator-view grid live. UI text is Japanese; code and commits are English.

**Live: <https://adust09.github.io/consensus-sim/>** — deployed from `main` on every push.

## Running

```bash
npm install
npm run dev        # http://localhost:5173
npm test           # vitest
npm run typecheck
npm run build      # static output in dist/
```

There is no backend. `dist/` is a static bundle.

> On machines with a low inotify instance limit, `npm run dev` may fail with `EMFILE: too many open
> files`. `npm run build && npm run preview` serves the same app without file watching.

## Why this exists

A survey of prior art found nothing that covers browser visualisation *and* parameter-driven
protocol swapping for the Ethereum consensus family:

| Prior art | What it is | Why it does not fit |
| --- | --- | --- |
| [`ethereum/research/3sf-mini`](https://github.com/ethereum/research/tree/master/3sf-mini) | 3SF consensus + p2p in ~21 KB of Python | No UI, no Gasper, no Goldfish/Simplex/Minimmit. Useful as a semantics reference |
| [`ethpandaops/forky`](https://github.com/ethpandaops/forky) | Fork-choice viewer for live beacon nodes | Views real data; cannot run a hypothetical protocol |
| [`ethereum/beaconrunner`](https://github.com/ethereum/beaconrunner) | Agent-based PoS simulation (cadCAD) | Last updated 2023, predates this line of research |
| JABS, BlockSim, SimBlock | General blockchain / BFT simulators | No Ethereum fork-choice semantics, no browser UI |
| [raft.github.io](https://raft.github.io/) | Interactive consensus visualisation | Raft only — but the right interaction model to aim at |

No public simulator exists for Goldfish, RLMD-GHOST, Minimmit or Simplex.

## Architecture

```
src/core/          engine — RNG, event queue, network model, simulation driver
src/protocol/      layer interface + protocol implementations (gasper/)
src/ui/            React shell, Canvas views, control panel
```

The core is UI-independent: it advances to a target simulated instant and stops, knowing nothing
about frames or the DOM. The browser and a future headless runner drive the same engine.

Three decisions shape everything else:

**Discrete events, not fixed ticks.** The differences this tool exists to study — Goldfish vs
RLMD-GHOST, view-merge vs proposer boost — only appear when message delay varies beyond Δ. A
lock-step round model bakes a constant Δ into the engine and makes those differences unobservable.

**Individual validators, not vote counts.** Every node holds its own store and its own view. A
statistical model would be faster and larger, but partitions, equivocation and view-merge are
defined as *differences between nodes' views*, so there would be nothing left to visualise.

**Layers, not monoliths.** Protocols plug into an ordered stack. A layer declares its own
participant set (layers do not share a validator set — block production runs on a small committee
while finality runs over everyone), whether it produces a ledger on its own, and reads the layers
below it explicitly. With A available-chain candidates and F finality candidates, a layered design
costs A+F implementations where a monolithic one costs A×F.

## What Gasper models

**Included:** slots, epochs, per-slot committees, attestations carrying a head vote *and* an FFG
source/target pair in one message, LMD-GHOST subtree weights, justification and finalization,
proposer boost, effective-balance weighting, message delay distributions and network partitions.

**Excluded:** RANDAO, rewards, SSZ, BLS signatures, blobs, the execution layer. None of them change
the fork choice's output, and each would multiply the implementation for no additional phenomenon.

Proposer boost is a first-class parameter rather than a constant, because it solves the same problem
Goldfish solves with view-merge. Comparing the two is the first experiment this tool is for.

## Views

- **Slot timeline** — the inside of the current slot: when the proposal fired, when the committee
  voted, and how far each has spread. Propagation is the part of a slot that is actually continuous,
  and it is where latency and partitions stop being a parameter and become watchable — raise the
  delay and the meter is still filling when the voting deadline arrives.
- **Fork tree** — slot on x, one row per branch. Drawn from the *observed node's* snapshot, not from
  a global truth, so during a partition it shows what that node believes. Colour carries state
  (finalized / justified / canonical / orphaned), not identity.
- **Validator grid** — one cell per node, coloured by whether it agrees with the observed node.
  Agreement is the quietest thing on screen: a converged network is one flat neutral that does not
  repaint. Colour appears only for genuinely contested heads, so the amount of movement tracks the
  amount of information. This slot's committee is outlined, which is where Gasper's
  one-committee-per-slot structure becomes visible.

Changing any protocol parameter restarts the run. Comparing the first ten slots at N=64 against the
next ten at N=128 would not mean anything, so a parameter edit starts a new experiment.

## Roadmap

| | |
| --- | --- |
| **M1** ✅ | Engine, Gasper, fork tree, validator grid |
| **M2** | Slot timeline, metrics, safety/reorg detection, attack presets, inactivity leak, slashing |
| **M3** | Vote expiry η as a parameter — one slider spans Goldfish (η=1), RLMD-GHOST (1<η<∞) and LMD-GHOST (η=∞) |
| **M4** | Simplex, Minimmit, stabilization layer, three-tier composition |
| **M5** | Headless runner and parameter sweeps |

The layer interface is expected to bend when Goldfish lands in M3; a refactor is budgeted there
rather than pretended away.

## References

- [Unblocking Faster Finality with Decoupled Consensus](https://ethresear.ch/t/unblocking-faster-finality-with-decoupled-consensus/24527) — fradamt
- Goldfish — IACR ePrint 2022/1171
- RLMD-GHOST — arXiv:2302.11326 (D'Amato & Zanolini, CSF 2024)
- Simplex — IACR ePrint 2023/463
- Minimmit — arXiv:2508.10862
