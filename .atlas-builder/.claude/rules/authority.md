# Rule: Authority and Ownership (META.md §3, §7)

## Canonical priority

Conceptual: `Essence > Spec > Todo > Execution > Impl > Report`

Physical:

```text
PROJECT_ROOT/ESSENCE.md
> PROJECT_ROOT/.atlas-builder/state/spec.json
> PROJECT_ROOT/.atlas-builder/state/todo.json
> PROJECT_ROOT implementation files
```

## Ownership

- `PROJECT_ROOT/ESSENCE.md` — human-only, and the only human requirement-input file a human writes in the target repo. Never edit, never overwrite, never "fix typos". If the Essence is contradictory, ambiguous, or infeasible, raise a Blocking Recommendation and stop.
- `PROJECT_ROOT/essences/**` — human-only too, on equal footing with ESSENCE.md (I-004), but it is ESSENCE.md's *attachment assets* (images embedded in the Essence, non-Markdown instruction material), not a separate requirement-input file: read-only for you, never editable, never in a cycle commit (I-020, META.md §2.1.5). Optional, and nestable up to 3 path segments deep (`essences/<a>/<b>/<c>`); every asset must be covered in ESSENCE.md by its exact `essences/<path>` mention or by one of its parent directories (`essences/input/` covers everything beneath it), and every such reference must resolve to a real file or directory — a bidirectional mismatch stops the loop as `essence_asset_integrity` (§13.1-14) for the human to fix.
- `CONTROL_ROOT/CLAUDE.md` — your execution charter, rendered by init from `templates/control/`. It and its template are immutable from every bound Agent session, including supervise; framework updates happen in the separate maintainer plane (META.md §11.3, I-028).
- `PROJECT_ROOT/README.md` — NOT human-owned: ordinary project documentation you own like any src/ file (META.md §11.1). Edit it freely without a gate, and let it ride in the cycle commit. Keep it consistent with the Essence — when they disagree, the README is what gets corrected. Bootstrap seeds it as a bare skeleton — `Overview` / `Quickstart` / `Usage` / `Development`, each `TBD` (META.md §11.1.1). Replacing those `TBD`s is your work, not a human's: a reader must be able to install, launch, and sanity-check the product from `Quickstart` alone, with real commands. Add sections the target needs, but never ship a README that cannot answer "how do I run this". Write it as the target product's own documentation: no Atlas Builder vocabulary, no `ESSENCE.md` / `.atlas-builder/state/` / `just loop` operating instructions (those belong to the workspace README and `CONTROL_ROOT/README.md`, §6.2/§17), and no leftover instruction comments.
- `PROJECT_ROOT/CLAUDE.md` / `PROJECT_ROOT/.claude/**` (only where the target embeds an In-Project Agent) — NOT human-owned and NOT in the §7.2 ownership table: they are the target product's own content that you develop directly as a High-Risk change (ask-gated + hashed, §12, high-risk-agent-runtime.md). Ask-gated is not the same as human-owned. Atlas Builder seeds no template into them (§6.2, §16.2, §17).
- `PROJECT_ROOT/.atlas-builder/state/**` — Atlas Builder-owned canonical state. Only the Over-Project Agent through the specified state workflow writes here. Embedded target runtime content is not trusted with this boundary and therefore is never launched directly in the live project (META.md §6.2, §10, I-003).
- Human-readable summaries (`just status`, the loop's exit messages) are computed from canonical state on demand; there is no generated summary file to edit or trust.

## Conflict resolution

When two artifacts disagree, the higher-priority artifact wins and the lower one must be regenerated or corrected. Never resolve a conflict by editing upward (e.g. adjusting Spec to match an implementation accident) — regenerate the lower artifact instead, and record the conflict and its resolution in reflection.jsonl.
