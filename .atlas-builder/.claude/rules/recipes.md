# Rule: Recipes (META.md §29)

A recipe is a concrete implementation template the Essence can adopt with a
machine-readable pointer line (anywhere in ESSENCE.md, recommended in
前提事項):

```text
recipe: <name>@<major>        e.g.  recipe: agentic-state-loop@2
```

Originals live only in `CONTROL_ROOT/recipes/<name>/` (immutable control-plane
surface: your writes there are always denied, §11.3). The project side holds
only the pointer, the generated final implementation, and its provenance
record (`recipe.lock.json`).

## Instantiation (projection work)

When the Essence carries a recipe pointer and no matching instance exists
(`atlas-builder state validate` warns), project it as a **High-Risk Todo**
(`risk_level: "high"`, §12) — the generated files include `.claude/**`,
hooks, and loop scripts, so the existing ask + hash fences apply unchanged.
Executing the Todo:

1. Read `recipes/<name>/recipe.json` and `recipes/<name>/README.md`; follow
   the `install` map (copy `files/`, substitute the token, e.g.
   `__ASL_LOOP_DIR__`).
2. Fill every `kind: "authored"` parameter by deriving it from the Essence
   (state document schemas, deny rules, protected paths, the cycle prompt's
   domain section). Leave no `unfilled_marker` and no substitution token.
3. Write `recipe.lock.json` per `recipe.json`'s `lock_format`;
   `source_sha256` comes from `bin/atlas-builder recipe hash <name>`.
4. Run the `post_install_checks` and record them as the Todo's evidence.

## Boundaries

- **Vendoring:** after instantiation the generated files are ordinary
  implementation files of the target — the target's own property. They never
  auto-follow recipe-original updates; a `source hash drift` warning is
  informational, and re-instantiation happens only when the human approves it
  (it is a fresh High-Risk Todo).
- The instance must stay self-contained and Atlas Builder-free: never write
  Atlas Builder's vocabulary into it, never make it reference CONTROL_ROOT (§6.2,
  §17). An instance embedding an agent loop IS an In-Project Agent — develop
  it by direct edit, but never launch it in the live project as verification;
  use a project-defined isolated runner or raise a human gate (§10).
- Never seed a recipe the Essence did not ask for: adoption is the Essence's
  decision, expressed as the pointer line (§29.1). A missing pointer with an
  installed instance is a validate warning to surface to the human, not
  something you fix by editing ESSENCE.md (I-004).
- Pointer/instance mismatches are warnings, never stop gates; do not raise a
  gate for them.
