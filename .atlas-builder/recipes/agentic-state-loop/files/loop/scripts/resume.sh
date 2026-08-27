#!/usr/bin/env bash
# agentic-state-loop — human-only resume: release the latched gates, record
# WHY (the intent note), and checkpoint the human's edits (protected files
# included) as one review commit so the next cycle starts clean.
#
# --force additionally closes runs left dangling by a crashed loop.
#
# Usage: cd <target> && bash <loop-dir>/scripts/resume.sh --note "..." [--force]

# shellcheck source=./_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

assert_target_root
resolve_git_context

NOTE=""
FORCE=0
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [[ "${args[$i]}" == "--note" ]] && NOTE="${args[$((i + 1))]:-}"
  [[ "${args[$i]}" == "--force" ]] && FORCE=1
done

# The note is the only durable answer to "why was this gate released?"; a
# blank one would mask an unexplained release. Prompt on a terminal, refuse
# otherwise — automation must state its intent explicitly.
if [[ -z "$(printf '%s' "${NOTE}" | tr -d '[:space:]')" ]]; then
  if [[ ! -t 0 ]]; then
    err "resume records a human intervention and requires an intent note."
    err "Fix: bash ${LOOP_DIR_NAME}/scripts/resume.sh --note \"why you intervened\""
    exit 2
  fi
  while true; do
    if ! read -e -r -p "[loop] intent note (natural language; Ctrl-C to abort): " NOTE; then
      printf '\n' >&2
      err "resume aborted: no intent note was provided (EOF)."
      exit 2
    fi
    [[ -n "$(printf '%s' "${NOTE}" | tr -d '[:space:]')" ]] && break
    warn "the note must not be empty."
  done
fi
# Strip control characters so an embedded escape sequence cannot corrupt the
# gate resolutions or the commit body (multi-byte UTF-8 passes untouched).
NOTE="$(printf '%s' "${NOTE}" | LC_ALL=C tr -d '\000-\010\013-\037\177')"

acquire_loop_lock
# An untrapped INT/TERM/HUP would free the lock (EXIT trap) while a foreground
# child (`state resume`, git) is still mutating state. Trapping defers the
# signal until the child returns, so the transition never outlives its lock.
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# Refuse BEFORE mutating: `state resume` releases the gates and appends to the
# ledger, so an abort at commit time would leave the transition recorded with
# no checkpoint carrying it.
assert_resume_checkpoint_feasible

RESUME_ARGS=(resume --note "${NOTE}")
[[ "${FORCE}" -eq 1 ]] && RESUME_ARGS+=(--force)
state "${RESUME_ARGS[@]}"

state_validate_soft >/dev/null || warn "validation still reports errors; the next cycle's agent repairs state first"

# honor_protected=no: the human checkpoint is exactly where protected-file
# edits enter history.
create_guarded_checkpoint "loop: human resume" "Event: human-resume
Note: ${NOTE}" skip no

log "resumed. Next: bash ${LOOP_DIR_NAME}/scripts/loop.sh"
