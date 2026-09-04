# Rule: One Atlas Builder Cycle (META.md §19.2)

Each cycle follows this order. Do not skip steps.

1. Observe CONTROL_ROOT and PROJECT_ROOT (git status, validation.json, runs.jsonl).
2. Read `PROJECT_ROOT/ESSENCE.md` (and, if present, its `PROJECT_ROOT/essences/**` attachment assets — reference only, never edit; they are human-only like ESSENCE.md, §2.1.5).
3. Read `PROJECT_ROOT/README.md`.
4. Read `PROJECT_ROOT/.atlas-builder/state/*.json`.
5. Validate the Essence > Spec > Todo > Impl trace (`bin/atlas-builder state validate --project ...`).
6. Stop on Essence-derived Blocking, human approval/input wait, or idle-cycle safety threshold (§13.1). Everything in §13.2 (build/test/type/lint/dependency/tool failures, dead ends) is recoverable; the remaining §13.1 stops (essence_missing/placeholder, essence_unreviewed_change, state_unreadable, infra streak, the must boundary) are detected mechanically — you never clear them yourself.
7. Select a Todo batch respecting `batch_policy` (no mixing high-risk with normal, no mixing executors) AND the completion phase (§19.3): in the default `must` phase only must-priority Todos are runnable — do not pick up `should` Todos until the human explicitly chooses `--approve-should` (resume sets `context.json.phase = "extended_approved"`). The other human choice, `--close-at-must`, sets the terminal `closed_at_must` scope. Never write `phase` yourself; the must boundary stops for the human as `must_complete_awaiting_phase_approval` (§13.1-13). Under a relaxed profile (ESSENCE `profile:` line, META.md §11.5) a High-Risk Todo is directly runnable — its ask faces auto-allow with an audited reason — but it still runs in a batch of its own with before/after hashes recorded (§12, high-risk rule); under `standard` it stops for `just supervise` as usual.
8. Execute by direct edit (`executor.mode = "atlas-builder"` is the only implementation path). Never launch an embedded target agent directly in the live project. Behavioural verification uses only a project-defined isolated runner that cannot access live Atlas Builder state or secrets; without one, raise a Human-input Recommendation (META.md §10).
9. Verify with real commands; capture exit codes.
10. Recover implementation errors autonomously where possible; otherwise mark the Todo `blocked` and continue with other Todos.
11. Update canonical JSON state only through `atlas-builder state`. For spec/todo/recommendations/blockers, build a temporary bundle and use `state apply-projection`; never edit a projection in place or rely on after-the-fact validation (see the state rule).
12. Append a reflection entry with `bin/atlas-builder state append-reflection --file <entry.json>` (never by Edit — see the state rule). If the cycle produced knowledge worth carrying to the next project — a build tactic that actually worked, a harness pattern, a tool limit and its workaround — append it to `lessons.jsonl` with `append-lesson` instead of retyping it into the handoff every cycle.
13. Decide whether a context reset is due (`atlas-builder state should-reset`).

After the cycle returns to `loop.sh`, the loop script records
semantic progress, materializes any loop-detected stop gate as a
Recommendation (`atlas-builder state raise-loop-gates`, §13.4), validates again,
and creates exactly one Git checkpoint commit for the
cycle. If a stop condition
is latched, the loop exits before starting another cycle — and a re-run while
gated refuses side-effect-free (no run record, no commit, I-019).
The cycle commit never contains PROJECT_ROOT's human-gated files — ESSENCE.md,
its essences/** attachment assets (§2.1.5), and (where the target embeds an
agent) CLAUDE.md, .claude/** (I-020): if the human edited one mid-cycle, the
loop leaves the diff in the worktree (for ESSENCE.md it also stops on
`essence_unreviewed_change`, which now also covers the essences/ manifest; for
the others the next cycle refuses on I-014) until the human records it with
`just resume`.
README.md is not in that set: it is an ordinary implementation file you own
(§11.1) and its diffs ride in the cycle commit.
Agents may inspect `git status` and `git diff`, but must not run `git add` or
`git commit` directly.

## Spec / Todo projection

- Every Spec item derives from the Essence and records why in `essence_refs`; each ref exactly reproduces a current human-authored Essence content item (whitespace-normalized; headings/directives excluded), so Essence → Spec → Todo is mechanically validated.
- Every Todo references at least one Spec id in its `spec` array.
- A Todo becomes `done` only with evidence (§22): command results with exit codes, or diffs. An isolated target-agent runner yields ordinary command evidence — the runner command, its exit code, and a redacted summary (never verbatim output, I-024); there is no special evidence type for it.
