# Control-plane bind templates

These `*.tmpl` files are the canonical sources that `init.sh`
(`just init <path>`) renders into the live control-plane files when binding this
`.atlas-builder` control plane to a single target project:

| Template | Rendered to |
| --- | --- |
| `settings.json.tmpl` | `.claude/settings.json` |
| `CLAUDE.md.tmpl` | `CLAUDE.md` |
| `justfile.tmpl` | `justfile` |

## Placeholder tokens

Rendering is a literal substitution of these tokens (chosen to never collide
with real prose or paths):

| Token | Replaced with | Example | Used by |
| --- | --- | --- | --- |
| `__ATLAS_BUILDER_PROJECT_PATH__` | PROJECT_ROOT relative to CONTROL_ROOT | `../my-project` | `CLAUDE.md.tmpl` / `justfile.tmpl` (rendered here) |
| `__ATLAS_BUILDER_PROJECT_TITLE__` | PROJECT_ROOT basename | `my-project` | `templates/workspace/README.md.tmpl` (seeded by init, META.md §16.1) |

`settings.json.tmpl` carries no token at all: the rendered settings file is
the machine-independent BASE (META.md §16.1) and the only value init derives
into it is the `_atlas_builder_profile` line (the ESSENCE-declared execution
profile, §11.5). Every machine-dependent path rule and the whole sandbox live
in the per-launch overlay that the launchers generate with
`atlas-builder util bound-settings` and pass inline via `--settings` — nothing
git-tracked names this machine's paths, so a cloned workspace runs without
re-init.

Editing bindings by hand is discouraged: change the templates (or re-run
`just init <path>`) so a re-bind stays reproducible. The live `.claude/settings.json`,
`CLAUDE.md`, and `justfile` shipped in the distribution are the *unbound, safe*
versions — running `init` overwrites them with the bound versions.
