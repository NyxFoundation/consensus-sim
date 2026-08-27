# Rule: Agent Runtime High-Risk Zone (META.md §12)

These PROJECT_ROOT paths are always high-risk wherever they exist. The agent-runtime configuration paths (CLAUDE.md, .claude/**, prompts/**, ...) exist only when the target embeds an agent (§5.0) — a target without them has nothing to classify, not a lower risk level:

```text
CLAUDE.md, .claude/**, .mcp.json, .cursor/**, AGENTS.md,
.github/workflows/** (CI/CD, §11.2),
agent-runtime/**, agents/**, prompts/**, skills/**, hooks/**,
scripts/*agent*, scripts/*claude*, scripts/*loop*, scripts/*autonomous*,
**/settings.json (when it may configure Claude / an agent)
```

## Requirements for any high-risk change

1. The Todo must declare `risk_level: "high"`, a non-empty `risk_reason`, and a non-empty `target` that is the supervised change scope.
2. Never mix a high-risk Todo into a batch with normal Todos.
3. Before/after SHA-256 hashes are recorded mechanically: the pre-tool guard hook records the before-hash and the post-tool audit hook the after-hash into `high_risk_changes.jsonl` (META.md §20.4-3). Your responsibility is the linkage: copy the hashes into the Todo's evidence and make sure the change traces to a declared high-risk Todo (§20.4-1).
4. Ensure `high_risk_changes.jsonl` carries the complete record (path, before/after hash, reviewed_by, risk_reason): where the hook's entry left `reviewed_by` empty or `risk_reason` as the generic hook placeholder, append a completed record that references it — the log is append-only (state rule), so never rewrite the hook's line.
5. Record a diff summary of the change (META.md §12.1-6) — in the Todo's evidence (a `diff` evidence entry) or the completed high-risk record.
6. Summarize the change in this cycle's `reflection.jsonl` entry.
7. Developing agent-runtime configuration and verifying its behavior are separate acts (§12.3): an autonomous cycle records the High-Risk Todo/Recommendation and stops; after human approval, `just supervise --todo T-... --recommendation R-...` provides the interactive ask-gated edit path bound to that exact Todo and authorizing Recommendation. The wrapper's canonical preflight requires the Recommendation `source` to include the Todo ID and its `target` to exactly equal the Todo target. A later cycle verifies the committed result through a project-defined isolated runner (§10). Never mix the change and its behavioral verification in one batch (§9.3).
8. A high-risk change never justifies reinterpreting `ESSENCE.md`.

## Relaxed profile (META.md §11.5)

When ESSENCE.md declares `profile: auto-approve` or `profile: unsandboxed`
(a human-only active line, I-004), the High-Risk ask faces become audited
allows, so an autonomous cycle may apply a High-Risk Todo directly without
the supervise stop. Only the stop is waived — everything else above is
unchanged: the `risk_level` / `risk_reason` / `target` declarations, the
no-mixing batch rule, the mechanical before/after hash records (the guard's
staging is profile-invariant, META.md §31.3 G-T6), the evidence linkage and
reflection summary, and the isolated-runner-only verification boundary
(§10, I-003). A relaxed profile never justifies reinterpreting ESSENCE.md.

## Self-reference guard (§12.2)

- PROJECT_ROOT `.claude/**` / `CLAUDE.md` (if the target has them) are the project's own content — the In-Project Agent's configuration, and your development target. Never adopt them as your own configuration, and never write Atlas Builder's vocabulary into them (§6.2, §17).
- Atlas Builder self-update (changing CONTROL_ROOT hooks/rules/scripts) is outside the bound target-project Agent plane and is always denied here; framework work happens in the separate maintainer plane (META.md §11.3, I-028).

## Control-plane surface (§11.3, hook-enforced)

Relative to CONTROL_ROOT, these are immutable (deny) for you, because they
decide what the framework enforces: `CLAUDE.md`, `.claude/**`, `scripts/**` (_lib.sh,
scripts/*.sh), `templates/**` (bind sources for settings/CLAUDE.md/justfile),
`recipes/**` (recipe originals, META.md §29), `justfile`, `META.md`,
`README.md` (the control plane's own human-facing document),
`.agent/prompts/**`, `.agent/state/workspace.json`, `.agent/state/project_index.json`,
and the enforcement itself — `bin/**` (the hook/guard/state binary) and
`lean/**` (its source). The deny outranks the §11.2 dependency-manifest `ask`
and is identical on the Edit and Bash paths, so a control-plane file that also
carries a manifest name (e.g. `recipes/.../lean/lakefile.lean`) is still denied.
The attestation ledger (`.agent/state/essence_attestations.jsonl`) and
`PROJECT_STATE_ROOT/state/project.json` are denied outright.
