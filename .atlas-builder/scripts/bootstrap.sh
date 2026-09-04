#!/usr/bin/env bash
# bootstrap.sh — initialize a project for the framework (META.md §18.1, §26).
#
# Seeds PROJECT_ROOT from CONTROL_ROOT/templates/project (never overwriting
# existing files), creates the canonical state via <tool> state ensure, then
# validates. WHICH faces are seeded is the domain pack's declaration, read from
# the engine (`util domain-spec`, META.md §26.1) — this script carries no list
# of its own. The target's implementation, CLAUDE.md and .claude/** are the
# project's own content and are never seeded (META.md §5.0, §17).
#
# Usage: cd ./.<tool> && bash scripts/bootstrap.sh --project ../PROJECT_TITLE

# shellcheck source=./_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

assert_control_root
resolve_project "$@"
# Seeding runs through `<tool> util seed`; fail closed before touching
# anything (META.md §31.5).
require_tool_bin

# I-018: seeding + state ensure mutate the project plane; inherit the lock
# when running as the init child, refuse beside a live foreign loop/resume.
acquire_or_inherit_loop_lock
# §13.5: untrapped INT/TERM would free an owned lock (EXIT trap) while a
# foreground child (seed, <tool> state) still runs; trapping defers the signal
# until the child returns.
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

TEMPLATES="${CONTROL_ROOT}/templates/project"

log "Bootstrapping ${PROJECT_TITLE} at ${PROJECT_ROOT}"

# §26.1-5: a fresh binding must not inherit another run's staging artifacts.
prune_stale_control_tmp

# Seed a file from the template tree only when the destination does not exist.
# Human-owned files are therefore never clobbered (META.md §26.1-5). Mode "render"
# substitutes the literal PROJECT_TITLE token; only the prose seeds that carry
# the token declare it. Mode "verbatim" copies bytes unchanged, so a settings
# or ignore file can never be rewritten by a stray token match added in a
# future template revision.
seed() {
  local rel="$1"
  local mode="${2:-render}"
  local src="${TEMPLATES}/${rel}"
  local dst="${PROJECT_ROOT}/${rel}"
  if [[ ! -f "${src}" ]]; then
    warn "template missing: ${rel} (skipped)"
    return
  fi
  if [[ -f "${dst}" ]]; then
    log "keep existing: ${rel}"
    return
  fi
  mkdir -p "$(dirname "${dst}")"
  # Atomic (`.seed.<pid>.tmp` → rename): a crash mid-seed must not leave a
  # truncated file that the next bootstrap then keeps as "existing" — a
  # half-written ESSENCE.md without the placeholder marker would even pass
  # the placeholder gate as a "real" Essence.
  if [[ "${mode}" == "render" ]]; then
    "${TOOL_BIN}" util seed "${src}" "${dst}" --replace "PROJECT_TITLE=${PROJECT_TITLE}"
  else
    "${TOOL_BIN}" util seed "${src}" "${dst}"
  fi
  log "seeded: ${rel}"
}

# The seed manifest is a domain axis (§26.1): "<mode> <path>", in declaration
# order. An empty manifest would mean "seed nothing", which no domain declares
# — refuse rather than bootstrap a target with no Essence to gate on.
load_domain_spec
if ((${#BOOTSTRAP_SEEDS[@]} == 0)); then
  err "the domain declares no bootstrap seed faces; refusing to bootstrap an unseeded target (META.md §26.1)."
  exit 2
fi
for SEED_ENTRY in ${BOOTSTRAP_SEEDS[@]+"${BOOTSTRAP_SEEDS[@]}"}; do
  seed "${SEED_ENTRY#* }" "${SEED_ENTRY%% *}"
done

if essence_has_placeholder_marker "${PROJECT_ROOT}/ESSENCE.md"; then
  # §13.1-8 / §2.1.1: the top guide block OR any leftover section FILL marker
  # means the Essence is not yet written; the loop will gate on it.
  warn "ESSENCE.md is still a placeholder (guide block or a '<!-- FILL:' section marker remains). A human must write the real Essence before the loop runs."
fi

# Canonical state + control-plane registration, then validate.
state ensure --project "${PROJECT_ARG}"
state_validate_soft --project "${PROJECT_ARG}" || warn "validation reported issues (see validation.json)"

log "Bootstrap complete."
log "Next: ensure ${PROJECT_ROOT}/ESSENCE.md is the real human-written Essence, review \`just status\`, commit the initial ${TOOL_NAME} state from the workspace root, then run: bash scripts/loop.sh --project ${PROJECT_ARG}"
