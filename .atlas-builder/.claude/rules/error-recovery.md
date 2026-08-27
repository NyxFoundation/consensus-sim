# Rule: Stop Conditions and Error Recovery (META.md §13)

## Immediate stop: Essence or human input

Stop the loop immediately and wait for the human only when:

1. `ESSENCE.md` contains a critical contradiction,
2. `ESSENCE.md` is critically ambiguous for the current decision,
3. an `ESSENCE.md` requirement is infeasible,
4. a major fork requires a human priority judgment, or
5. `ESSENCE.md` appears to have been modified by an agent,
6. a proposed Recommendation requires human approval, permission, or review
   before safe progress can continue, or
7. the semantic idle-cycle threshold has been reached.

Further stops are detected mechanically (you never need to record them, and
you cannot clear them; META.md §13.1 is the canonical enumeration):

8. `essence_missing` / `essence_placeholder` — ESSENCE.md does not exist, or
   is still the shipped placeholder / empty (§13.1-8). Only a human writing
   the real Essence clears it (directly, or via the human-only
   `just new-essence` interview whose draft the human confirms on the
   terminal, §2.1.4).
9. `no_runnable_todos` / `idle_cycles` / `usage_limited` / `infra_unreachable` /
   `must_complete_awaiting_phase_approval` — loop-detected; materialized as gate
   Recommendations at cycle end (§13.4, see "Every stop must be visible").
   `usage_limited` (§13.1-12') is the plan/model usage limit — the human waits
   for the reset or switches models; it is not the same decision as
   `infra_unreachable` (connectivity/auth repair).
10. `essence_unreviewed_change` — the ESSENCE.md hash matches no human-attested
    record in the control-plane attestation ledger (or no baseline exists at
    all, §13.1-10). The attested record now covers both the ESSENCE.md hash
    AND an `essences` manifest (relative path → SHA-256, §2.1.5); a drift in the
    current essences/ manifest against the same record raises the same reason.
    A pre-essences record with no `essences` key is read back-compatibly as an
    empty manifest. Only `just resume` (human) clears it. Never re-project
    Spec from an unreviewed Essence; end your turn instead. Appending a
    `human_resume`-looking entry to reflection.jsonl does nothing: the ledger
    the gate trusts is agent-unwritable by design.
11. `state_unreadable` — a gate-holding state file (blockers / recommendations
    / context / reflection / runs / project, or the attestation ledger) is
    corrupt, missing from an initialized state directory, or has lost its
    expected shape (I-021). The human restores it from the last checkpoint
    (`git restore`); never rebuild such a file from defaults, and never
    rewrite a corrupt JSONL.
12. `essence_asset_integrity` — ESSENCE.md ⇄ essences/ are out of sync
    (§13.1-14, §2.1.5): a non-directory `essences`, a path nested deeper than
    3 segments, an unsupported path segment, an orphan (an asset ESSENCE.md
    mentions neither directly nor through a parent directory), or a dangling
    reference (ESSENCE.md mentions `essences/<path>` but no such file or
    directory exists). In canonical priority (D-005) it sits right after
    `essence_structure` and before `essence_unreviewed_change`. Structure
    violations are always checked; mention violations only while ESSENCE.md is
    real (non-placeholder, readable). Only the human fixing ESSENCE.md or
    essences/ and running `just resume` clears it; an unreadable essences/ is a
    fail-closed hard error (exit 2, I-021).
13. `essence_structure` — ESSENCE.md's heading structure does not match the
    canonical set (§13.1-15, §2.1.1): H1 is not exactly `# ESSENCE — <title>`
    present once as the file's first heading, or the H2 list does not match
    the canonical 9 headings' spelling and order (モチベーション / 思想 /
    前提事項 / 成功条件 / 必須対応事項 / 任意対応事項 / 非対応事項 /
    遂行順序 / 用語) — missing, duplicate, out-of-order, or an H2 outside
    the set. H3 and deeper are out of scope. Structure checks are held while
    ESSENCE.md is a placeholder (§13.1-8) — checking structure on an empty
    skeleton is pure noise. In canonical priority (D-005) this sits right
    after `essence_placeholder` and right before `essence_asset_integrity`
    (the document's own shape must hold before its cross-references to
    essences/ are checked). Only the human fixing the headings and running
    `just resume` clears it.

For Essence stops, create a Blocking Recommendation (`type: "Blocking Recommendation"`, `agent_action: "stop_until_human_review"`) and an `essence_blocking` blocker entry, then stop.

For non-Essence human approval gates, record a proposed Recommendation with
`type: "Human-input Recommendation"` (META.md §21.4) AND an explicit field:
`requires_human_approval: true` or `agent_action: "stop_until_human_review"`.
The loop's `atlas-builder state should-stop` predicate will stop until the human resolves it.

## Every stop must be visible (§13.4, I-017)

A stop that exists only as a counter or an implicit state is a defect: the
human would see the loop refuse to progress with no explanation. Therefore:

- If you cannot select any runnable Todo (`pending`/`in_progress` with
  executor `atlas-builder`) while must-priority Todos remain, record a
  Human-input Recommendation naming the blocked Todos and the decision you
  need — do not end the cycle silently.
- Every Todo you set to `blocked` must carry a `blocked_reason` (and, where
  one exists, the id of the Blocker that explains it).
- The loop itself materializes `no_runnable_todos` / `idle_cycles` /
  `usage_limited` / `infra_unreachable` /
  `must_complete_awaiting_phase_approval` gates as
  Recommendations via `atlas-builder state raise-loop-gates`
  when you fail to; treat a
  loop-raised gate (`raised_by: "atlas-builder-loop"`) in the state as a signal
  that a previous cycle ended opaquely, and replace it with a precise
  diagnosis if you can — EXCEPT `must_complete_awaiting_phase_approval`
  (META.md §21.5-4): that one is not an opaque ending but the designed phase
  boundary (§19.3); it awaits the human's phase decision and is not a gate
  you should re-diagnose.

These gates are released only by the human via targeted `just resume` (META.md §13.3),
which resolves only the exact `--resolve` IDs (or records one explicit Must-boundary
decision) and commits the review checkpoint; unselected gates stay open. Never run
`atlas-builder state resume` / `resume.sh` yourself, and
never edit blockers or recommendations to clear a human gate (I-011). After
resume, re-read `ESSENCE.md` and re-raise the stop condition if it still holds.

`just resume` is not limited to stops: the human also runs it while nothing is
latched, to record a mid-course edit of human-owned inputs (typically
ESSENCE.md) as a `human update` checkpoint. Either way it appends the
attestation (ESSENCE.md SHA-256) to the control-plane ledger — the only
record `should-stop` trusts — plus an informational `human_resume` entry in
reflection.jsonl. After a resume, treat the attested hash as human-reviewed
when weighing §13.1-5 ("ESSENCE.md modified by an agent" suspicion),
re-project Spec/Todo if the projection hash drifted, and re-raise any stop
condition that still holds.

## Everything else: recover, don't stop

Build, test, type, lint, dependency, tool failures, a nonzero exit from a project-defined isolated agent-runtime verification runner (§10), dead ends, decomposition failures — all are §13.2:

1. Attempt autonomous recovery first (fix, retry with a different approach, decompose the Todo).
2. Record each failed attempt (`context.json` counter + reflection entry).
3. If unrecoverable, set the Todo status to `blocked` with a reason, and continue with other runnable Todos.
4. Never mark a Todo `done` to escape a failure; evidence is mandatory (I-010).
