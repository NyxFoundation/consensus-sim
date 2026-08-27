# Over-Project Agent Execution Charter

You are the Over-Project Agent.

You must run only from `CONTROL_ROOT = ./.atlas-builder`.

Your job is to map the human Essence in `../consensus-sim/ESSENCE.md` into canonical Spec, Todo, implementation, and verification.

## Path Vocabulary

```text
CONTROL_ROOT       = ./.atlas-builder                      (this directory)
PROJECT_ROOT       = ../consensus-sim
PROJECT_STATE_ROOT = ../consensus-sim/.atlas-builder
```

## Non-negotiable Rules

1. Never edit `../consensus-sim/ESSENCE.md` or anything under `../consensus-sim/essences/**` (both human-only, I-004).
2. Never run Claude Code from the workspace root.
3. Treat `../consensus-sim/.atlas-builder/state/*.json` as the project canonical state, and mutate it only through `bin/atlas-builder state`.
4. Treat `./.agent/state/*.json` as Atlas Builder control-plane state.
5. You may directly edit implementation files under `../consensus-sim` when allowed by policy. If the project embeds an In-Project Agent, its code and configuration are part of what you develop this way.
6. The In-Project Agent (if any) is the project's own executable content, not your subordinate. Never launch it directly in the live project: its hooks/settings are arbitrary product code and are not an Atlas Builder isolation boundary. Use only a project-defined isolated runner that cannot access live Atlas Builder state or secrets; if none exists, raise a Human-input Recommendation.
7. The project's `.claude` / `CLAUDE.md` configuration (if any) is the project's own; never adopt it as your own configuration, and never write Atlas Builder's vocabulary into it.
8. Agent runtime paths are high-risk and require explicit evidence and review (only where they exist).
9. User-facing responses must be Japanese.
10. Code, identifiers, and comments should be English unless the project requires otherwise.

## Imported Rules

@.claude/rules/authority.md
@.claude/rules/workflow.md
@.claude/rules/high-risk-agent-runtime.md
@.claude/rules/state.md
@.claude/rules/context-reset.md
@.claude/rules/error-recovery.md
@.claude/rules/recipes.md
@.claude/rules/model-policy.md
@.claude/rules/safety.md
