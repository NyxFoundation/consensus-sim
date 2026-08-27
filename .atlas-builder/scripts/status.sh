#!/usr/bin/env bash
# status.sh — human-readable state summary (META.md §18.1).
#
# Usage: cd ./.<tool> && bash scripts/status.sh --project ../PROJECT_TITLE

# shellcheck source=./_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

assert_control_root
resolve_project "$@"

state status --project "${PROJECT_ARG}"

echo
# state_predicate hard-stops on exit >= 2: a broken predicate must never be
# reported as "RUNNABLE" (same fail-closed rule the loop follows, §19.1-3).
if state_predicate STOP_JSON should-stop --project "${PROJECT_ARG}"; then
  echo "STOP: $(stop_message_from_json "${STOP_JSON}")"
  # The exact resume form has ONE derivation point: the should-stop message
  # (§13.4-2 — status must not be a second implementation of the gate rules).
  # A fixed sentence here would contradict it: with an open gate a bare
  # `just resume` is refused (§13.3-4'), and at the must boundary neither
  # ESSENCE.md editing nor `--resolve` applies at all (§13.1-13).
  echo "NEXT: run the exact \`just resume …\` form named in the STOP line above, then \`just loop\` (META.md §13.3)."
  echo "HELP: \`just triage\` triages the gates interactively — settles what needs no human decision, turns the rest into step-by-step actions (META.md §13.6)."
elif state_predicate COMPLETE_JSON should-complete --project "${PROJECT_ARG}"; then
  COMPLETION_SCOPE="$("${TOOL_BIN}" util json-get completion_scope <<<"${COMPLETE_JSON}")"
  if [[ "${COMPLETION_SCOPE}" == "must" ]]; then
    echo "COMPLETE: full_complete — the human explicitly accepted completion at must scope (META.md §19.3)."
  else
    echo "COMPLETE: full_complete — must phase done and every should Todo explicitly resolved (META.md §19.3)."
  fi
else
  echo "RUNNABLE: no blocking condition; the loop may proceed."
  GIT_ROOT="$(git -C "${CONTROL_ROOT}" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "${GIT_ROOT}" && -n "$(git -C "${GIT_ROOT}" status --porcelain --untracked-files=all 2>/dev/null)" ]]; then
    echo "NOTE: uncommitted changes present; \`just loop\` starts only from a clean worktree (I-014)."
    echo "      If these are your own edits (e.g. ESSENCE.md), run \`just resume\` to record them as a human-update checkpoint first (META.md §13.3)."
  fi
fi
