#!/usr/bin/env bash
# agentic-state-loop — the continuous autonomous loop.
#
#   assert CWD == TARGET_ROOT -> parameter/trust gates -> single-flight lock
#   per cycle:
#     should-stop (side-effect-free refusal while gated)
#     -> assert clean git worktree -> ensure -> start-run -> validate
#     -> claude -p (or -c -p) with the cycle prompt
#     -> end-run -> record-progress (idle / failed-run streaks -> gates)
#     -> validate -> exactly one cycle checkpoint commit
#     -> stop gate check
#
# Every designed terminal — a latched gate, the --max-cycles budget — exits 0;
# a stop is the designed hand-off to the human, reported as STOP, never as
# ERROR. Nonzero means failure only: 2 usage/environment/engine crash,
# 3 dangling-run refusal (a previous cycle crashed; recover with
# `resume.sh --force`), 4 git refusal, 5 lock contention, 129/130/143 interrupted.
#
# Usage: cd <target> && bash <loop-dir>/scripts/loop.sh [-n N | --max-cycles N] [--max-session-cycles N]

# shellcheck source=./_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

assert_target_root
assert_instance_parameterized
require_asl_bin
resolve_git_context

MAX_CYCLES=25
MAX_SESSION_CYCLES="$("${ASL_BIN}" util max-session-cycles --loop-root "${LOOP_ROOT}")"
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [[ "${args[$i]}" == "--max-cycles" || "${args[$i]}" == "-n" ]] &&
    MAX_CYCLES="${args[$((i + 1))]:-25}"
  [[ "${args[$i]}" == "--max-session-cycles" ]] && MAX_SESSION_CYCLES="${args[$((i + 1))]:-8}"
done
[[ "${MAX_CYCLES}" =~ ^[1-9][0-9]*$ ]] ||
  {
    err "-n/--max-cycles must be a positive integer, got: ${MAX_CYCLES}"
    exit 2
  }
[[ "${MAX_SESSION_CYCLES}" =~ ^[1-9][0-9]*$ ]] ||
  {
    err "--max-session-cycles must be a positive integer, got: ${MAX_SESSION_CYCLES}"
    exit 2
  }

command -v claude >/dev/null 2>&1 || {
  err "claude CLI not found; cannot run the loop."
  exit 2
}
require_claude_trust
build_sanitized_claude_env

PROMPT_TEMPLATE="${LOOP_ROOT}/prompts/cycle.md"
PROMPT="$(cat "${PROMPT_TEMPLATE}")"

acquire_loop_lock

# An interrupted cycle terminates its claude child and closes its run record
# so runs.jsonl stays consistent; the dirty worktree is then recovered by
# resume.sh --force.
CURRENT_RUN_ID=""
CLAUDE_PID=""
on_loop_signal() {
  local signal="$1"
  local code="$2"
  err "received ${signal}; aborting the loop."
  if [[ -n "${CLAUDE_PID}" ]] && kill -0 "${CLAUDE_PID}" 2>/dev/null; then
    # claude leads its own process group (set -m at spawn), so the group kill
    # also reaches every verification/build child it started via Bash — a plain
    # single-pid kill would leave such grandchildren running past the lock
    # release. Fall back to the single pid if the group signal fails.
    kill -- -"${CLAUDE_PID}" 2>/dev/null || kill "${CLAUDE_PID}" 2>/dev/null || true
    # Wait for claude to actually die before the EXIT trap frees the lock:
    # releasing it while the agent still shuts down would let an immediate
    # `resume.sh --force` race its final writes.
    wait "${CLAUDE_PID}" 2>/dev/null || true
  fi
  if [[ -n "${CURRENT_RUN_ID}" ]]; then
    state end-run --run-id "${CURRENT_RUN_ID}" --status "interrupted" >/dev/null 2>&1 || true
    err "run ${CURRENT_RUN_ID} recorded as interrupted; the worktree keeps its partial changes."
    err "Recover with: review the diff, then \`bash ${LOOP_DIR_NAME}/scripts/resume.sh --force --note ...\`"
  fi
  exit "${code}"
}
trap 'on_loop_signal SIGINT 130' INT
trap 'on_loop_signal SIGTERM 143' TERM
# claude runs in its OWN process group (set -m), so a terminal hangup reaches
# this wrapper's group but NOT claude's — without this trap the default HUP
# action would run the EXIT trap and free the single-flight lock while a
# headless claude keeps writing, and the documented `resume.sh --force`
# recovery would then close a still-live run.
trap 'on_loop_signal SIGHUP 129' HUP

report_stop_and_exit() {
  local stop_json="$1"
  local when="$2"
  printf '%s\n' "${stop_json}"
  log "STOP: $(stop_message_from_json "${stop_json}"). ${when}"
  log "Next: bash ${LOOP_DIR_NAME}/scripts/status.sh, then bash ${LOOP_DIR_NAME}/scripts/resume.sh --note \"...\""
  exit 0
}

# shellcheck disable=SC2153  # state_predicate assigns STOP_JSON via nameref.
exit_if_gated() {
  if state_predicate STOP_JSON should-stop; then
    report_stop_and_exit "${STOP_JSON}" "$1"
  fi
}

CYCLE=0
SESSION_MODE="fresh" # the first cycle always starts a fresh session
CYCLES_SINCE_FRESH=0

while ((CYCLE < MAX_CYCLES)); do
  CYCLE=$((CYCLE + 1))
  log "=== cycle ${CYCLE}/${MAX_CYCLES} (${TARGET_ROOT##*/}) ==="

  # A latched gate is re-reported without starting a run — no run record, no
  # counter change, no checkpoint commit. Re-running while gated is free.
  exit_if_gated "The loop is gated; no cycle was started and nothing was committed."

  assert_clean_worktree_for_cycle
  state ensure >/dev/null
  RUN_ID="$(state start-run)"
  CURRENT_RUN_ID="${RUN_ID}"
  log "run ${RUN_ID} started (session: ${SESSION_MODE})"

  state_validate_soft >/dev/null || warn "validation errors — the agent must repair state this cycle"

  if [[ "${SESSION_MODE}" == "continue" ]] && ((CYCLES_SINCE_FRESH >= MAX_SESSION_CYCLES)); then
    log "session continuation backstop: ${CYCLES_SINCE_FRESH} cycles since fresh (cap ${MAX_SESSION_CYCLES}). Next session starts fresh."
    SESSION_MODE="fresh"
  fi

  RUN_STATUS="ok"
  # Credential scrubbing makes current Claude Code resolve to default mode.
  # Supplying an inert dontAsk CLI flag only emits a warning each cycle; `-p`
  # remains the fail-closed floor because an unmatched tool cannot answer its
  # resulting ask in a headless session.
  CLAUDE_CMD=("${SANITIZED_CLAUDE_ENV[@]}" claude -p "${PROMPT}" --setting-sources project --strict-mcp-config)
  if [[ "${SESSION_MODE}" == "fresh" ]]; then
    CYCLES_SINCE_FRESH=1
  else
    CLAUDE_CMD=("${SANITIZED_CLAUDE_ENV[@]}" claude -c -p "${PROMPT}" --setting-sources project --strict-mcp-config)
    CYCLES_SINCE_FRESH=$((CYCLES_SINCE_FRESH + 1))
  fi

  # claude runs as a background child under `wait` so signal traps are
  # processed immediately instead of after claude exits. set -m gives it its
  # own process group so on_loop_signal can kill it together with any
  # verification/build child it spawned; disabled again right after, since job
  # control must not affect the rest of the loop.
  set -m
  "${CLAUDE_CMD[@]}" &
  CLAUDE_PID=$!
  set +m
  CLAUDE_RC=0
  wait "${CLAUDE_PID}" || CLAUDE_RC=$?
  CLAUDE_PID=""

  [[ "${CLAUDE_RC}" -eq 0 ]] || RUN_STATUS="claude_exit_${CLAUDE_RC}"
  SESSION_MODE="continue"
  if [[ "${RUN_STATUS}" != "ok" ]]; then
    # A failed invocation may be continuation-poisoned; correctness relies on
    # fresh restarts from disk, so the next cycle starts a fresh session.
    log "claude exited nonzero (${CLAUDE_RC}); next session will start fresh."
    SESSION_MODE="fresh"
  fi

  # Progress detection BEFORE the state bookkeeping below adds its own diff:
  # "changed" means the cycle touched anything outside the state directory.
  CHANGED="no"
  worktree_has_non_state_changes && CHANGED="yes"

  # Cleared BEFORE end-run so a trapped signal cannot re-close the same run
  # with a contradictory status right after end-run recorded the real one.
  CURRENT_RUN_ID=""
  state end-run --run-id "${RUN_ID}" --status "${RUN_STATUS}" >/dev/null
  RUN_CLASS="ok"
  [[ "${RUN_STATUS}" == "ok" ]] || RUN_CLASS="fail"
  # Streak counters update and, on a threshold crossing, materialize a gate —
  # conditions the loop is about to stop for exist as canonical state before
  # the checkpoint, never only as counters.
  state record-progress --changed "${CHANGED}" --run-status "${RUN_CLASS}" >/dev/null

  state_validate_soft >/dev/null ||
    warn "validation errors remain at cycle end; committing checkpoint for recovery"

  COMMIT_BODY="Cycle: ${CYCLE}/${MAX_CYCLES}
Run-Status: ${RUN_STATUS}
Changed-Outside-State: ${CHANGED}

Loop-Run-Id: ${RUN_ID}
Loop-Run-Status: ${RUN_STATUS}"
  create_guarded_checkpoint "loop: cycle ${RUN_ID}" "${COMMIT_BODY}" fail yes

  exit_if_gated "Stopping before the next cycle."

  # Implementation-level failures never stop the loop immediately; the next
  # cycle's agent sees the run status and validation output on disk (the
  # failed-run streak gate bounds a persistent failure).
  [[ "${RUN_STATUS}" == "ok" ]] || warn "run ${RUN_ID} ended with ${RUN_STATUS}; continuing"
done

log "Reached max cycles (${MAX_CYCLES}) without a stop. Re-run to continue."
