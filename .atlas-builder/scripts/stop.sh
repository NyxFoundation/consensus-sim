#!/usr/bin/env bash
# stop.sh — ask the RUNNING loop to stop cleanly at the next cycle
# boundary (graceful drain, META.md §19.1-7).
#
# Writes (or, with --cancel, removes) the drain flag LOOP_DRAIN_PATH — a
# human-only surface under .agent/state that every agent layer blocks writes
# to. The loop consumes the flag right after finalize_cycle, so the cycle in
# flight finishes and commits its checkpoint first, then the loop exits 0
# without latching any gate — plain `just loop` continues later, no resume
# needed. A stop gate latched in that same cycle still wins the loop's final
# report (the drain never masks a canonical stop, §13.4).
#
# Asynchronous by design: this command returns immediately; the loop's own
# terminal shows the final report (DRAIN, or a gate STOP) when the boundary
# is reached. Contrast with Ctrl-C (§13.5), which kills the cycle mid-flight
# and leaves a dirty worktree that `just resume` must recover.
#
# Usage: cd ./.<tool> && bash scripts/stop.sh --project ../PROJECT_TITLE [--cancel]
#
# Exit codes: 0 = the request/cancel state is as asked, INCLUDING the
# designed no-ops ("no running loop", "nothing to cancel") — the message, not
# the exit code, carries the distinction, exactly like the loop's own
# designed terminals (§19.1-6). 2 = usage/environment error. Exit 0 never
# means "the loop has stopped": the request is asynchronous.
#
# Human-only: the pre-tool guard hook denies this script and `just stop` to
# agents (§18.2). The loop's lifecycle belongs to the human; an agent that
# wants the loop to pause records a canonical Recommendation instead (§13.4).

# shellcheck source=./_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

assert_control_root

# Consume flags strictly, BEFORE resolve_project scans anything: unknown
# arguments are refused because a silently dropped flag would run a different
# action than the human asked for (same rule as resume.sh).
CANCEL=0
args=("$@")
i=0
while ((i < ${#args[@]})); do
  case "${args[$i]}" in
    --project)
      ((i + 1 < ${#args[@]})) || {
        err "--project requires a value."
        exit 2
      }
      i=$((i + 2))
      ;;
    --cancel)
      CANCEL=1
      i=$((i + 1))
      ;;
    *)
      err "unknown argument: ${args[$i]}"
      err "usage: bash scripts/stop.sh --project ../PROJECT_TITLE [--cancel]"
      exit 2
      ;;
  esac
done

resolve_project "$@"

if ((CANCEL)); then
  if [[ -e "${LOOP_DRAIN_PATH}" ]]; then
    rm -f "${LOOP_DRAIN_PATH}"
    log "drain request withdrawn; a running loop continues past the next cycle boundary."
  else
    log "no pending drain request; nothing to cancel."
  fi
  exit 0
fi

OWNER_PID="$(loop_lock_owner_pid)"
OWNER_ALIVE=0
if [[ -n "${OWNER_PID}" ]] && lock_pid_is_alive "${OWNER_PID}"; then
  OWNER_ALIVE=1
fi

if ((OWNER_ALIVE == 0)); then
  # No live single-flight holder: there is no loop to drain. Clean up any
  # stale flag (belt to the loop's own startup clear, §19.1-7) instead of
  # leaving debris that the next `just loop` would have to warn about.
  if [[ -e "${LOOP_DRAIN_PATH}" ]]; then
    rm -f "${LOOP_DRAIN_PATH}"
    log "removed a stale drain request left by a previous invocation."
  fi
  log "no running loop (no live single-flight holder, I-018); nothing to stop."
  log "If the loop already stopped, see \`just status\`; start it again with \`just loop\`."
  exit 0
fi

# The single-flight slot is shared by every mutating transition (I-018), not
# only the loop — draining a `just resume` or `just supervise` is meaningless.
# `ps` inspection is best-effort: when it cannot answer (restricted shell,
# EPERM), fail toward REGISTERING — the worst case of a misdelivered request
# is one warn at the next loop start, while a silently refused request under
# a real loop would leave the human waiting on a stop that never comes.
OWNER_CMD="$(ps -o command= -p "${OWNER_PID}" 2>/dev/null || true)"
case "${OWNER_CMD}" in
  *"scripts/loop.sh"*) ;; # the holder is the loop — register below
  "")
    warn "cannot inspect the single-flight holder (pid ${OWNER_PID}); registering the drain request anyway."
    warn "If the holder is not \`just loop\`, the request is cleared (with a warning) at the next loop start."
    ;;
  *)
    log "the single-flight slot is held by another transition (pid ${OWNER_PID}), not the loop:"
    log "  ${OWNER_CMD}"
    log "Nothing to stop. Wait for it to finish, or stop it in its own terminal."
    exit 0
    ;;
esac

mkdir -p "$(dirname "${LOOP_DRAIN_PATH}")"
# Existence is the signal; the content is a human-debuggability breadcrumb
# the loop never reads.
printf 'requested_by_pid=%s requested_at=%s\n' "$$" "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
  >"${LOOP_DRAIN_PATH}"
log "drain requested: the loop (pid ${OWNER_PID}) finishes the cycle in flight, commits its checkpoint, then exits at the cycle boundary."
log "Watch the loop's terminal for its final report — normally DRAIN (then plain \`just loop\` continues later, no resume needed);"
log "a stop gate latched in the same cycle wins instead and then needs the \`just resume\` form it names (§13.4)."
log "Withdraw with: just stop --cancel"
