#!/usr/bin/env bash
# loop.sh — the continuous autonomous Over-Project loop (META.md §19.1).
#
#   assert CWD == CONTROL_ROOT -> trust gate -> single-flight lock (I-018)
#   -> clear any stale drain request (§19.1-7)
#   per cycle:
#     pre-gates (should-stop / should-complete, side-effect-free, I-019)
#     -> assert clean git worktree -> ensure -> start-run
#     -> validate -> should-reset
#     -> claude -p (or -c -p): headless, isolation flags fixed
#     -> end-run -> record-progress -> raise-loop-gates (§13.4)
#     -> validate -> cycle git commit
#     -> consume drain request (`just stop`, §19.1-7)
#     -> post-gates (stop / complete)   # a latched gate wins the report
#     -> exit 0 if a drain was consumed
#     -> exponential backoff when claude could not launch (§19.1-8)
#
# A gated invocation refuses before start-run: it writes nothing, commits
# nothing, and prints the stop reason plus the resume instruction (§13.4).
#
# Exit codes (§19.1-6): every designed terminal — complete, a latched stop
# gate, the --max-cycles budget, a `just stop` drain (§19.1-7) — exits 0. A
# stop is the designed hand-off to the human, reported as STOP, never as
# ERROR. Nonzero means failure only:
# 2 usage/environment/predicate crash, 4 git refusal, 5 lock contention,
# 129/130/143 interrupted (SIGHUP/SIGINT/SIGTERM). Machine callers query the gate state
# via `<tool> state should-stop` / `should-complete`, not via this exit code.
#
# Usage: cd ./.<tool> && bash scripts/loop.sh --project ../PROJECT_TITLE \
#          [-n N | --max-cycles N] [--max-session-cycles N]

# shellcheck source=./_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

assert_control_root
resolve_project "$@"
resolve_git_context

MAX_CYCLES=25
MAX_SESSION_CYCLES=8 # §14.1 backstop: a session lasts at most N cycles (1 fresh + N-1 continued)
# Strict flag parsing (same rule as stop.sh / watch.sh / resume.sh): a silently
# dropped or mistyped flag would run a different budget than the human asked
# for — `just loop --max-cyles 5` must refuse, not run 25 autonomous cycles.
args=("$@")
i=0
while ((i < ${#args[@]})); do
  case "${args[$i]}" in
    --project | --max-cycles | -n | --max-session-cycles)
      ((i + 1 < ${#args[@]})) || {
        err "${args[$i]} requires a value."
        exit 2
      }
      case "${args[$i]}" in
        --max-cycles | -n) MAX_CYCLES="${args[$((i + 1))]}" ;;
        --max-session-cycles) MAX_SESSION_CYCLES="${args[$((i + 1))]}" ;;
      esac
      i=$((i + 2))
      ;;
    *)
      err "unknown argument: ${args[$i]}"
      err "usage: bash scripts/loop.sh --project ../PROJECT_TITLE [-n N | --max-cycles N] [--max-session-cycles N]"
      exit 2
      ;;
  esac
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
require_claude_launch_trust "Over-Project Agent" "${CONTROL_ROOT}"
resolve_session_model
build_sanitized_claude_env

PROMPT_TEMPLATE="${CONTROL_ROOT}/.agent/prompts/${TOOL}-cycle.md"
[[ -f "${PROMPT_TEMPLATE}" ]] || {
  err "missing prompt template: ${PROMPT_TEMPLATE}"
  exit 2
}
PROMPT_TEMPLATE_CONTENT="$(cat "${PROMPT_TEMPLATE}")"

# §19.1-9: this invocation's own start time, stamped into every cycle's
# display-only heartbeat.
LOOP_STARTED_AT_EPOCH="$(date +%s)"

acquire_loop_lock

# §19.1-7: a drain request only ever targets the invocation it was made
# under; one surviving a gate stop or a crash must not kill this fresh loop
# after a single cycle.
clear_stale_drain_request

# §13.5: an interrupted cycle terminates its claude child and closes its run
# record so runs.jsonl stays consistent; the dirty worktree is then recovered
# by `just resume`. claude runs as a background child under `wait` so that
# signal traps are processed immediately instead of after claude exits.
CURRENT_RUN_ID=""
CLAUDE_PID=""
# §28.6: per-cycle stderr capture so a nonzero `claude` exit can be classified
# as infra vs unknown. claude writes its stderr straight to a regular file; a
# background `tail -f` mirrors it to the terminal so the human still sees the
# error live. Both are torn down after every cycle and by the signal handler;
# they live under .agent/tmp (gitignored) so they never dirty the worktree the
# next cycle asserts clean (I-014).
CLAUDE_STDERR_FILE=""
CLAUDE_TEE_PID=""
cleanup_cycle_capture() {
  if [[ -n "${CLAUDE_TEE_PID}" ]] && kill -0 "${CLAUDE_TEE_PID}" 2>/dev/null; then
    # The live-mirror `tail -f` is killed on the normal path already; this only
    # nudges one still live because the cycle was interrupted mid-run.
    kill "${CLAUDE_TEE_PID}" 2>/dev/null || true
    wait "${CLAUDE_TEE_PID}" 2>/dev/null || true
  fi
  CLAUDE_TEE_PID=""
  [[ -n "${CLAUDE_STDERR_FILE}" ]] && rm -f "${CLAUDE_STDERR_FILE}"
  CLAUDE_STDERR_FILE=""
}
on_loop_signal() {
  local signal="$1"
  local code="$2"
  err "received ${signal}; aborting the loop."
  if [[ -n "${CLAUDE_PID}" ]] && kill -0 "${CLAUDE_PID}" 2>/dev/null; then
    # §13.5: claude runs as its own process-group leader (set -m at spawn), so
    # the group kill also reaches every verification/build child it started via
    # Bash — a plain single-pid kill would leave such grandchildren running
    # past the lock release. Fall back to the single pid if the group signal
    # fails.
    kill -- -"${CLAUDE_PID}" 2>/dev/null || kill "${CLAUDE_PID}" 2>/dev/null || true
    # Wait for claude to actually die before the EXIT trap frees the
    # single-flight lock: releasing it while the agent still shuts down would
    # let an immediate `just resume --force` race its final writes (I-018).
    wait "${CLAUDE_PID}" 2>/dev/null || true
  fi
  cleanup_cycle_capture
  if [[ -n "${CURRENT_RUN_ID}" ]]; then
    state end-run --project "${PROJECT_ARG}" --run-id "${CURRENT_RUN_ID}" \
      --status "interrupted" >/dev/null 2>&1 || true
    err "run ${CURRENT_RUN_ID} recorded as interrupted; the worktree keeps its partial changes."
    err "Recover with: review the diff, then \`just resume\` (META.md §13.5)."
  fi
  exit "${code}"
}
trap 'on_loop_signal SIGINT 130' INT
trap 'on_loop_signal SIGTERM 143' TERM
# §13.5: claude runs in its OWN process group (set -m), so a terminal hangup
# reaches the wrapper's group but NOT claude's — without this trap the default
# HUP action would run the EXIT trap and free the single-flight lock while a
# headless claude keeps writing, and the documented `just resume --force`
# recovery would then close a still-live run. The handler kills claude's group
# and reaps it before releasing the lock, exactly like INT/TERM.
trap 'on_loop_signal SIGHUP 129' HUP

# §16.1: the bound overlay (path rules + sandbox) is generated once per
# invocation, after the lock (and after the signal traps, so the acquisition
# window stays as narrow as before) — with the slot held, no framework
# transition can rewrite the base (and its recorded profile) mid-invocation
# (I-018). An unbound or pre-split base fails closed here (exit 2) with no
# side effects: the EXIT trap releases the lock and nothing has been written
# (I-019).
build_bound_session_settings

# A latched stop gate is the loop working as designed — the hand-off to the
# human (§13.4-3) — so it is reported as STOP and exits 0; ERROR/nonzero would
# make every wrapper (just, CI) present the designed pause as a failure.
report_stop_and_exit() {
  local stop_json="$1"
  local when="$2"
  printf '%s\n' "${stop_json}"
  log "STOP: $(stop_message_from_json "${stop_json}"). ${when}"
  print_resume_hint
  exit 0
}

report_complete_and_exit() {
  local complete_json="$1"
  local completion_scope
  printf '%s\n' "${complete_json}"
  completion_scope="$("${TOOL_BIN}" util json-get completion_scope <<<"${complete_json}")"
  # §19.3: COMPLETE is either explicit must-scope closure, or musts done plus
  # an approved should phase whose Todos are all explicitly resolved.
  if [[ "${completion_scope}" == "must" ]]; then
    log "Project complete at the explicitly accepted must scope (full_complete). Loop complete."
  else
    log "Project complete: must phase done and every should Todo explicitly resolved (full_complete). Loop complete."
  fi
  log "To continue beyond this, update ESSENCE.md, then run \`just resume\` and \`just loop\` (META.md §19.3)."
  exit 0
}

# Evaluate the stop/complete gate pair and exit if either holds; $1 gives the
# stop report its context line.
# shellcheck disable=SC2153  # state_predicate assigns STOP_JSON/COMPLETE_JSON via nameref.
exit_if_gated() {
  if state_predicate STOP_JSON should-stop --project "${PROJECT_ARG}"; then
    report_stop_and_exit "${STOP_JSON}" "$1"
  fi
  if state_predicate COMPLETE_JSON should-complete --project "${PROJECT_ARG}"; then
    report_complete_and_exit "${COMPLETE_JSON}"
  fi
}

finalize_cycle() {
  local run_status="$1"
  # §28.6: the infra/ok/unknown classification of this cycle's claude exit,
  # distinct from run_status (which is the run.jsonl record: ok/claude_exit_N).
  # record-progress consumes it to drive the infra_unreachable counter.
  local run_class="${2:-ok}"
  local commit_run_status="${run_status}"
  local validation_status
  local stop_json complete_json

  # Cleared BEFORE end-run: a trapped signal is deferred until the foreground
  # command returns and would otherwise re-close the same run as
  # `interrupted` right after this `end-run` recorded its real status,
  # leaving two contradictory end events. If end-run itself fails, the run
  # stays dangling and `just resume --force` recovers it (§13.5).
  CURRENT_RUN_ID=""
  state end-run --project "${PROJECT_ARG}" --run-id "${RUN_ID}" --status "${run_status}" >/dev/null
  state record-progress --project "${PROJECT_ARG}" --run-status "${run_class}" >/dev/null
  # §13.4 / I-017: conditions the loop is about to stop for must exist as
  # canonical Recommendations before the checkpoint, never only as counters.
  state raise-loop-gates --project "${PROJECT_ARG}" >/dev/null

  # §19.1-2 / §24.3: a stop or completion latched during the cycle is the
  # cycle's designed terminal and takes precedence in the commit trailer —
  # even over a nonzero claude exit (infra_unreachable latches ONLY on such
  # cycles, so claude_exit_N winning would make it unreachable). The raw
  # claude_exit_N stays recorded in runs.jsonl's run end status.
  if state_predicate stop_json should-stop --project "${PROJECT_ARG}"; then
    commit_run_status="$(stop_run_status_from_json "${stop_json}")"
  elif state_predicate complete_json should-complete --project "${PROJECT_ARG}"; then
    commit_run_status="complete"
  fi

  state_validate_soft --project "${PROJECT_ARG}" >/dev/null ||
    warn "validation errors remain at cycle end; committing checkpoint for recovery"
  validation_status="$(read_validation_status)"

  commit_cycle_checkpoint "${RUN_ID}" "${CYCLE}" "${MAX_CYCLES}" \
    "${commit_run_status}" "${validation_status}"
}

CYCLE=0
SESSION_MODE="fresh" # first cycle always starts a fresh session
CYCLES_SINCE_FRESH=0

# §19.1-8: consecutive launch failures (RUN_CLASS usage/infra — claude itself
# could not run) drive an exponential backoff before the next attempt. Retrying
# a rate-limited or unreachable API three seconds later, as the 2026-08-12 run
# did, only burns the safety counters without giving the condition any time to
# clear. Reset to 0 by any cycle whose claude exit was clean.
# Per-class launch-failure streaks, mirroring the canonical counters
# (`progress.usage_limited_since_ok` / `infra_fails_since_ok`, §13.1-12/-12'):
# only an `ok` cycle resets, `unknown` HOLDS (a session that ran and failed is
# not evidence the limit reset), and the two classes never advance each other —
# otherwise the ladder measures interleaving instead of the streak, and the
# stated 5/10/20-minute hand-off (§13.1-12') silently shortens.
USAGE_FAIL_STREAK=0
INFRA_FAIL_STREAK=0
RETRY_STREAK=0
# Usage limits reset on the provider's clock (minutes to hours), infra faults
# usually much sooner — so the usage ladder starts an order of magnitude
# higher. Both are capped so the loop never parks for longer than the human
# would tolerate before seeing the gate.
BACKOFF_BASE_USAGE=300
BACKOFF_BASE_INFRA=30
BACKOFF_CAP=1800

while ((CYCLE < MAX_CYCLES)); do
  CYCLE=$((CYCLE + 1))
  log "=== ${TOOL_NAME} cycle ${CYCLE}/${MAX_CYCLES} (${PROJECT_TITLE}) ==="

  # Pre-cycle gates (I-019): a latched stop or a completed project is
  # re-reported without starting a run — no run record, no counter change,
  # no checkpoint commit. Re-running `just loop` while gated is free.
  exit_if_gated "The loop is gated; no cycle was started and nothing was committed."

  assert_clean_worktree_for_cycle
  state ensure --project "${PROJECT_ARG}" >/dev/null
  RUN_ID="$(state start-run --project "${PROJECT_ARG}")"
  CURRENT_RUN_ID="${RUN_ID}"
  log "run ${RUN_ID} started (session: ${SESSION_MODE})"

  state_validate_soft --project "${PROJECT_ARG}" || warn "validation errors — the agent must repair state this cycle"

  if state_predicate RESET_JSON should-reset --project "${PROJECT_ARG}"; then
    log "Context reset triggered (§14.1). Next session starts fresh."
    state reset-context --project "${PROJECT_ARG}" >/dev/null
    SESSION_MODE="fresh"
  fi
  if [[ "${SESSION_MODE}" == "continue" ]] && ((CYCLES_SINCE_FRESH >= MAX_SESSION_CYCLES)); then
    log "Session continuation backstop: ${CYCLES_SINCE_FRESH} cycles since fresh (cap ${MAX_SESSION_CYCLES}, §14.1). Next session starts fresh."
    SESSION_MODE="fresh"
  fi

  # §19.1-9: display-only heartbeat for `just watch`, written once SESSION_MODE
  # is final (after should-reset and the §14.1 backstop) and right before the
  # session launches. Best-effort — a failed write warns and never stops the
  # cycle.
  write_loop_heartbeat "${PROJECT_TITLE}" "${CYCLE}" "${MAX_CYCLES}" \
    "${RUN_ID}" "${SESSION_MODE}" "$$" "${LOOP_STARTED_AT_EPOCH}"

  # Plain string substitution: sed would corrupt the prompt when the project
  # title contains replacement metacharacters such as `&` or `\`.
  PROMPT="${PROMPT_TEMPLATE_CONTENT//PROJECT_TITLE/${PROJECT_TITLE}}"
  RUN_STATUS="ok"
  # §19.1-5 fail-closed floor: headless `-p` is load-bearing — under
  # `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` the CLI resolves the permission mode to
  # `default`, an unmatched tool maps to ask, and an ask that cannot be shown
  # is denied. The launcher deliberately omits the inert `--permission-mode
  # dontAsk` flag (the settings' `defaultMode: dontAsk` stays as the
  # declarative baseline for non-scrubbed launches). The doctor recipe
  # asserts both headless forms (§28.5).
  CLAUDE_CMD=("${SANITIZED_CLAUDE_ENV[@]}" "${LOCK_TOKEN_ENV}=${LOOP_LOCK_TOKEN}" claude -p "${PROMPT}" --setting-sources project --strict-mcp-config)
  if [[ "${SESSION_MODE}" == "fresh" ]]; then
    CYCLES_SINCE_FRESH=1
  else
    CLAUDE_CMD=("${SANITIZED_CLAUDE_ENV[@]}" "${LOCK_TOKEN_ENV}=${LOOP_LOCK_TOKEN}" claude -c -p "${PROMPT}" --setting-sources project --strict-mcp-config)
    CYCLES_SINCE_FRESH=$((CYCLES_SINCE_FRESH + 1))
  fi
  # §16.1: the per-invocation model override applies to every cycle of this
  # loop run; without the <TOOL>_MODEL override the array is empty and settings.json decides.
  CLAUDE_CMD+=("${SESSION_MODEL_ARGS[@]+"${SESSION_MODEL_ARGS[@]}"}")
  # §16.1: the bound overlay (--settings <inline JSON>) carries every
  # machine-dependent rule and the whole sandbox; the base carries none.
  CLAUDE_CMD+=("${SESSION_SETTINGS_ARGS[@]+"${SESSION_SETTINGS_ARGS[@]}"}")

  # §28.6: capture claude's stderr while still streaming it live. claude writes
  # its stderr DIRECTLY to a regular file, so the capture is complete the moment
  # claude exits — it depends on no pipe reader draining. A background `tail -f`
  # mirrors that file to this stderr for the human's live view only; it holds no
  # correctness role. This is deliberately NOT a FIFO+tee: a FIFO's write-end
  # stays open as long as ANY descendant holds it, so a background grandchild
  # the Agent spawned (dev server, watcher) would keep `wait tee` blocked and
  # wedge the whole cycle indefinitely — lock held, run never ended (a real
  # unattended-operation hang). A regular file has no such dependency.
  mkdir -p "${CONTROL_ROOT}/.agent/tmp"
  CLAUDE_STDERR_FILE="$(mktemp "${CONTROL_ROOT}/.agent/tmp/claude-stderr.XXXXXX")" || CLAUDE_STDERR_FILE=""
  RUN_CLASS="ok"
  # §19.1-8: a retry delay the CLI stated itself, read while the capture still
  # exists (cleanup_cycle_capture removes it right below). Empty = none stated.
  CLAUDE_RETRY_AFTER=""
  if [[ -n "${CLAUDE_STDERR_FILE}" ]]; then
    tail -n +1 -f "${CLAUDE_STDERR_FILE}" >&2 2>/dev/null &
    CLAUDE_TEE_PID=$!
    # set -m: give claude its own process group so the signal trap can kill it
    # together with any verification/build child it spawned (§13.5). Disabled
    # again right after — job control must not affect the rest of the loop.
    set -m
    "${CLAUDE_CMD[@]}" 2>>"${CLAUDE_STDERR_FILE}" &
    CLAUDE_PID=$!
    set +m
    CLAUDE_RC=0
    wait "${CLAUDE_PID}" || CLAUDE_RC=$?
    CLAUDE_PID=""
    # claude has exited and flushed; the file is authoritative. Stop the live
    # mirror (killing it never blocks — it is not on the cycle's critical path)
    # and classify from the complete file.
    if [[ -n "${CLAUDE_TEE_PID}" ]]; then
      kill "${CLAUDE_TEE_PID}" 2>/dev/null || true
      wait "${CLAUDE_TEE_PID}" 2>/dev/null || true
      CLAUDE_TEE_PID=""
    fi
    RUN_CLASS="$(classify_claude_exit "${CLAUDE_RC}" "${CLAUDE_STDERR_FILE}")"
    CLAUDE_RETRY_AFTER="$(claude_retry_after_seconds "${CLAUDE_STDERR_FILE}")"
  else
    # mktemp failed (rare: full disk). Fall back to running claude with its
    # stderr untouched — no capture, so a nonzero exit can only be classified as
    # `unknown`. The idle safety net (§13.1-7) still bounds it.
    warn "could not create stderr capture file; infra classification degraded to unknown this cycle"
    set -m
    "${CLAUDE_CMD[@]}" &
    CLAUDE_PID=$!
    set +m
    CLAUDE_RC=0
    wait "${CLAUDE_PID}" || CLAUDE_RC=$?
    CLAUDE_PID=""
    RUN_CLASS="$(classify_claude_exit "${CLAUDE_RC}" "")"
  fi
  cleanup_cycle_capture

  [[ "${CLAUDE_RC}" -eq 0 ]] || RUN_STATUS="claude_exit_${CLAUDE_RC}"
  SESSION_MODE="continue"
  # §19.1-8: the backoff this cycle earned, consumed after the post-gate check.
  BACKOFF_WAIT=0
  if [[ "${RUN_STATUS}" != "ok" ]]; then
    # §28.4: a failed invocation may be continuation-poisoned (e.g. `-c` with
    # no resumable conversation). Correctness relies on fresh restarts from
    # disk, so the next cycle starts a fresh session instead of retrying `-c`.
    case "${RUN_CLASS}" in
      usage)
        # §13.1-12': the plan/model limit. Named as itself, never as "the agent
        # is stuck" — the whole point of the separate class.
        USAGE_FAIL_STREAK=$((USAGE_FAIL_STREAK + 1))
        RETRY_STREAK="${USAGE_FAIL_STREAK}"
        warn "claude could not run: the plan / model USAGE LIMIT was reached; this counts toward the usage_limited stop (§13.1-12'), NOT toward idle_cycles."
        log "Wait for the limit to reset, or re-run with ${TOOL_ENV}_MODEL=<tier> to continue on another model (§16.1)."
        BACKOFF_WAIT="$(backoff_seconds "${USAGE_FAIL_STREAK}" "${BACKOFF_BASE_USAGE}" "${BACKOFF_CAP}")"
        ;;
      infra)
        # §13.1-12: an infra-caused failure is not the agent being stuck —
        # Claude itself could not run.
        INFRA_FAIL_STREAK=$((INFRA_FAIL_STREAK + 1))
        RETRY_STREAK="${INFRA_FAIL_STREAK}"
        warn "claude failed for an infra reason (API connection / auth / Claude-side error); this counts toward the infra_unreachable stop (§13.1-12)."
        BACKOFF_WAIT="$(backoff_seconds "${INFRA_FAIL_STREAK}" "${BACKOFF_BASE_INFRA}" "${BACKOFF_CAP}")"
        ;;
      *)
        # `unknown`: the session ran and failed for a reason we cannot attribute
        # to the environment. That IS ordinary §13.2 work — no backoff. The
        # streaks HOLD (like the canonical counters): an unknown failure is
        # not evidence that a limit reset or the network healed.
        ;;
    esac
    # A retry delay the CLI stated itself outranks the ladder when it is longer
    # (still capped): the provider knows its own reset better than we do.
    if [[ "${BACKOFF_WAIT}" != "0" && -n "${CLAUDE_RETRY_AFTER}" ]] &&
      ((CLAUDE_RETRY_AFTER > BACKOFF_WAIT)); then
      BACKOFF_WAIT="${CLAUDE_RETRY_AFTER}"
      ((BACKOFF_WAIT > BACKOFF_CAP)) && BACKOFF_WAIT="${BACKOFF_CAP}"
      log "the CLI stated a retry delay of ${CLAUDE_RETRY_AFTER}s; honouring it (capped at ${BACKOFF_CAP}s)."
    fi
    log "claude exited nonzero (class: ${RUN_CLASS}); next session will start fresh (§14.1, §28.4)."
    SESSION_MODE="fresh"
  else
    USAGE_FAIL_STREAK=0
    INFRA_FAIL_STREAK=0
  fi

  finalize_cycle "${RUN_STATUS}" "${RUN_CLASS}"

  # §19.1-7: consume a pending `just stop` BEFORE the post-gate check so the
  # flag never outlives the boundary it targeted; a stop/complete latched this
  # same cycle still wins the report below — the gate is canonical state with
  # its own resume contract, the drain is only this invocation's budget.
  DRAIN_PENDING=0
  if consume_drain_request; then DRAIN_PENDING=1; fi

  exit_if_gated "Stopping before the next cycle."

  if ((DRAIN_PENDING)); then
    [[ "${RUN_STATUS}" == "ok" ]] ||
      warn "run ${RUN_ID} ended with ${RUN_STATUS}; the next \`just loop\` cycle sees it on disk (§13.2)"
    log "DRAIN: \`just stop\` requested a graceful stop — cycle ${CYCLE}/${MAX_CYCLES} finished and its checkpoint is committed; no stop gate is latched."
    log "Re-run \`just loop\` to continue (no resume needed, §19.1-7)."
    exit 0
  fi

  # Implementation-level failures never stop the loop immediately (§13.2);
  # the next cycle's agent sees the run status and validation output on disk.
  [[ "${RUN_STATUS}" == "ok" ]] || warn "run ${RUN_ID} ended with ${RUN_STATUS}; continuing (§13.2)"

  # §19.1-8: back off before retrying a launch failure. Deliberately AFTER the
  # post-gate check and the drain exit — a latched gate is the hand-off to the
  # human and must not be delayed by a wait the human will never see, and a
  # `just stop` already asked us to end at this boundary. The wait is
  # interruptible so Ctrl-C and a late `just stop` still land immediately.
  if ((BACKOFF_WAIT > 0)) && ((CYCLE < MAX_CYCLES)); then
    log "BACKOFF: waiting ${BACKOFF_WAIT}s before retry ${RETRY_STREAK} (class: ${RUN_CLASS}, §19.1-8). Ctrl-C or \`just stop\` ends the wait."
    interruptible_sleep "${BACKOFF_WAIT}"
    # §19.1-7: a `just stop` that landed DURING the wait ends the invocation at
    # this same cycle boundary — abandoning the wait only to launch one more
    # cycle against a limit that has not reset would make the interrupt worse
    # than the plain sleep. The checkpoint is committed and no gate is latched
    # (both checked above), so this is the same legal DRAIN terminal.
    if consume_drain_request; then
      log "DRAIN: \`just stop\` arrived during the backoff wait — stopping at this cycle boundary; cycle ${CYCLE}/${MAX_CYCLES} finished and its checkpoint is committed."
      log "Re-run \`just loop\` to continue (no resume needed, §19.1-7)."
      exit 0
    fi
  fi
done

log "Reached max cycles (${MAX_CYCLES}) without a stop or completion. Re-run \`just loop\` to continue."
