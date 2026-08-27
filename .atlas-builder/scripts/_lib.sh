#!/usr/bin/env bash
# Shared helpers for the control-plane scripts. Source only — do not execute.
#
# Path vocabulary (META.md §5.2):
#   CONTROL_ROOT       = ./.<tool>          (parent of this scripts/ dir)
#   PROJECT_ROOT       = ./{project-title}  (resolved from --project)
#   PROJECT_STATE_ROOT = ${PROJECT_ROOT}/.<tool>

set -euo pipefail

# Physical paths (pwd -P) everywhere: git prints physical paths from
# rev-parse --show-toplevel, and the Lean engine resolves symlinks away, so a
# logical (symlinked) path here would break every prefix computation against
# GIT_ROOT — e.g. a workspace reached via /tmp on macOS (a symlink to
# /private/tmp) would fail all checkpoint-scope checks.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")" && pwd -P)"
CONTROL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"

# Product identifier (META.md §5.2). Everything the framework spells with its
# own name is derived HERE, once, from the control root's basename — the
# scripts below never write a product token. The ENV namespace stays
# collision-free (META.md §1.3) because the derivation result is per-product.
#
#   TOOL             sample-tool  stem: the control root name without its dot
#   TOOL_SNAKE       sample_tool  identifier face (the settings profile key)
#   TOOL_ENV         SAMPLE_TOOL  environment-variable prefix (read indirectly)
#   TOOL_NAME        Sample Tool  human-facing display name
#   TOOL_TRAILER     Sample-Tool  commit trailer prefix (META.md §24.3)
#   TOOL_PLACEHOLDER SAMPLE-TOOL-TEMPLATE-PLACEHOLDER (META.md §13.1-8)
#
# Looper/Domain.lean derives the same spellings from the same stem: these are
# two independent derivations of one word, and the black-box regression that
# feeds the distributed template to the real binary pins them together.
#
# The shape check is not cosmetic: every spelling below hangs off this one
# stem, so a control root that cannot yield a well-formed stem must fail
# closed here rather than silently produce garbage ENV names and paths.
TOOL="${CONTROL_ROOT##*/}"
TOOL="${TOOL#.}"
if [[ ! "${TOOL}" =~ ^[a-z][a-z0-9]*(-[a-z0-9]+)*$ ]]; then
  printf 'ERROR: control root %s does not yield a product stem (expected .<lower-kebab>)\n' \
    "${CONTROL_ROOT}" >&2
  exit 2
fi
TOOL_SNAKE="$(printf '%s' "${TOOL}" | tr -- '-' '_')"
TOOL_ENV="$(printf '%s' "${TOOL_SNAKE}" | tr '[:lower:]' '[:upper:]')"
TOOL_NAME=""
TOOL_TRAILER=""
for _tool_word in ${TOOL//-/ }; do
  _tool_word="$(printf '%s' "${_tool_word:0:1}" | tr '[:lower:]' '[:upper:]')${_tool_word:1}"
  TOOL_NAME="${TOOL_NAME:+${TOOL_NAME} }${_tool_word}"
  TOOL_TRAILER="${TOOL_TRAILER:+${TOOL_TRAILER}-}${_tool_word}"
done
unset _tool_word
# Hyphens are PRESERVED here (unlike TOOL_ENV): the marker is a heading word
# embedded in distributed template prose, not an identifier.
TOOL_PLACEHOLDER="$(printf '%s' "${TOOL}" | tr '[:lower:]' '[:upper:]')-TEMPLATE-PLACEHOLDER"

log() { printf '[%s] %s\n' "${TOOL}" "$*"; }
warn() { printf '[%s] WARN: %s\n' "${TOOL}" "$*" >&2; }
err() { printf '[%s] ERROR: %s\n' "${TOOL}" "$*" >&2; }

# §28.6 / §13.1-12: classify a nonzero `claude` exit as `usage` (the plan /
# model USAGE LIMIT was reached), `infra` (API unreachable / auth expired /
# Claude-side error — environment, not the project's code), or `unknown` (a
# nonzero we cannot confidently attribute to either). Classification is
# CONSERVATIVE and fail-safe: it only returns a launch-failure class on a clear
# signal, so a drift in Claude Code's error output (§28.5) degrades to
# `unknown` — which the loop treats as an ordinary §13.2 continue — and never
# falsely latches a stop.
#
#   classify_claude_exit <exit_code> <stderr_file>  ->  echoes ok|usage|infra|unknown
#
# §13.1-12' — why `usage` is its own class and not just `infra`: a plan limit
# is the SINGLE most common launch failure an unattended loop meets, it is
# transient (time resolves it), and the remedy is completely different from an
# infra failure. Reported as the generic "API unreachable" a human goes and
# checks connectivity and `claude auth status`; reported as `idle_cycles` — the
# pre-2026-08-12 behavior — they go and read reflection.jsonl looking for
# stalled work. The 2026-08-12 run lost 9.5 hours to exactly that misreading.
#
# Signal: stderr matches a connection-trouble signature (case-insensitive).
# The current CLI exposes no distinct infra exit code (§28.5), so stderr
# decides. Keep the signature table in sync with the CLI through the
# source-repository maintainer plane (§28.5): the worst case of stale
# signatures is "infra read as unknown → the idle safety net stops after
# 3 cycles" — a degrade to prior behavior, not a runaway.
#
# The match is a bare case-insensitive substring search, so it is
# conservative only in the fail-SAFE sense (a false `infra` classification
# still ends in a STOP, never a runaway), NOT in the sense of "never
# misclassifies": an unrelated nonzero cycle whose stderr happens to contain
# e.g. `timeout`, `dns`, `500`, or `forbidden` will be read as infra and count
# toward the infra_unreachable gate. That only names the wrong cause on an
# already-stopping cycle; the direction is safe (§28.6).
#
# The plan/model USAGE-limit terms are load-bearing and live in their OWN
# table: a subscription limit is a §13.1-12' launch failure with its own
# counter, threshold and gate. The table matches the CLI's own wording
# (`You've reached your <model> limit.` / `usage limit reached`) plus the
# transport-level rate-limit signatures (429 / `rate limit` / `Retry-After`)
# that mean the same thing operationally: waiting is the remedy.
# Deliberately NOT here: the CLI's in-session `... limit reached` conditions
# (context / subagent / budget / spend), which are not launch failures — hence
# the targeted terms instead of a bare `limit reached`.
CLAUDE_USAGE_LIMIT_STDERR_RE='rate.?limit|too many requests|retry.?after|usage limit|weekly limit|credit limit|credit balance|quota|reached your [^.]{0,40}limit|(^|[^0-9])429([^0-9]|$)'

# The residual infra table (§13.1-12): reachability, auth and Claude-side
# faults. `usage` is matched FIRST, so the overlapping terms that used to live
# here (rate limit / usage limit / credit balance) now name the specific cause.
CLAUDE_INFRA_STDERR_RE='connection|network|timeout|timed out|etimedout|overloaded|econnreset|econnrefused|enetunreach|ehostunreach|enotfound|getaddrinfo|dns|tls|ssl|certificate|proxy|unauthorized|authentication|forbidden|api key|internal server error|service unavailable|bad gateway|gateway timeout|(^|[^0-9])(500|502|503|529)([^0-9]|$)'

classify_claude_exit() {
  local code="$1"
  local stderr_file="${2:-}"
  if [[ "${code}" -eq 0 ]]; then
    printf 'ok\n'
    return 0
  fi
  # grep -E -i against the captured stderr. A missing/unreadable capture file
  # simply yields no match (grep returns nonzero) and we fall through to
  # `unknown` — fail-safe, never a false launch-failure class.
  if [[ -n "${stderr_file}" && -r "${stderr_file}" ]]; then
    # `usage` precedes `infra`: naming the specific cause is the whole point.
    if grep -E -i -q "${CLAUDE_USAGE_LIMIT_STDERR_RE}" "${stderr_file}" 2>/dev/null; then
      printf 'usage\n'
      return 0
    fi
    if grep -E -i -q "${CLAUDE_INFRA_STDERR_RE}" "${stderr_file}" 2>/dev/null; then
      printf 'infra\n'
      return 0
    fi
  fi
  printf 'unknown\n'
  return 0
}

# §19.1-8: exponential backoff between launch-failure retries.
#
#   backoff_seconds <attempt> <base> <cap>  ->  echoes base * 2^(attempt-1),
#                                               clamped to [base, cap]
#
# `attempt` is 1-based (the wait taken AFTER the first failure is attempt 1).
# Pure arithmetic, no clock, no sleep — the bats suite pins the whole table.
backoff_seconds() {
  local attempt="${1:-1}" base="${2:-30}" cap="${3:-1800}" wait shift_count
  [[ "${attempt}" =~ ^[0-9]+$ ]] || attempt=1
  ((attempt < 1)) && attempt=1
  wait="${base}"
  # Bounded doubling: stop as soon as the cap is reached so a large attempt
  # count cannot overflow the shell's integer arithmetic.
  for ((shift_count = 1; shift_count < attempt; shift_count++)); do
    ((wait >= cap)) && break
    wait=$((wait * 2))
  done
  ((wait > cap)) && wait="${cap}"
  ((wait < base)) && wait="${base}"
  printf '%s\n' "${wait}"
}

# §19.1-8 (best effort): a retry delay the CLI stated ITSELF, in seconds.
#
#   claude_retry_after_seconds <stderr_file>  ->  echoes a positive integer, or
#                                                 nothing when none is stated
#
# Only DURATION forms are parsed (`Retry-After: 120`, `retry after 90 seconds`,
# `try again in 5 minutes`). Wall-clock reset times (`resets at 3pm
# (Asia/Tokyo)`) are deliberately NOT parsed: they need a locale/timezone-aware
# date parse whose portability and CLI-wording stability are both poor, and a
# misparse would either stall the loop for hours or defeat the backoff. The
# exponential backoff is the floor either way, so a missing hint costs one
# doubling step, never correctness.
claude_retry_after_seconds() {
  local stderr_file="${1:-}" line value
  [[ -n "${stderr_file}" && -r "${stderr_file}" ]] || return 0
  line="$(grep -E -i -o \
    'retry[- ]after:?[[:space:]]*[0-9]+|(retry|try again) (after|in)[[:space:]]+[0-9]+[[:space:]]*(s|sec|secs|second|seconds|m|min|mins|minute|minutes|h|hour|hours)' \
    "${stderr_file}" 2>/dev/null | head -n 1)" || return 0
  [[ -n "${line}" ]] || return 0
  value="$(printf '%s' "${line}" | grep -E -o '[0-9]+' | head -n 1)"
  [[ -n "${value}" ]] || return 0
  case "$(printf '%s' "${line}" | tr '[:upper:]' '[:lower:]')" in
    *hour* | *[0-9]\ h | *[0-9]h) value=$((value * 3600)) ;;
    *min* | *[0-9]\ m | *[0-9]m) value=$((value * 60)) ;;
  esac
  ((value > 0)) || return 0
  printf '%s\n' "${value}"
}

# §19.1-8 / §13.5: sleep that a signal or a `just stop` can cut short.
#
# A plain `sleep N` would defer the INT/TERM/HUP traps for the whole N (bash
# runs traps only between foreground commands), so an unattended loop parked in
# a 20-minute usage backoff would ignore Ctrl-C for 20 minutes. Sleeping in
# short chunks as a background child under `wait` keeps traps immediate, and
# re-checking the drain flag each chunk lets `just stop` (§19.1-7) end the wait
# instead of outliving it.
interruptible_sleep() {
  local total="${1:-0}" chunk="${2:-5}" elapsed=0 pid
  [[ "${total}" =~ ^[0-9]+$ ]] || return 0
  while ((elapsed < total)); do
    if [[ -e "${LOOP_DRAIN_PATH:-}" ]]; then
      log "backoff interrupted by a pending \`just stop\` request (§19.1-7)."
      return 0
    fi
    ((total - elapsed < chunk)) && chunk=$((total - elapsed))
    sleep "${chunk}" &
    pid=$!
    wait "${pid}" 2>/dev/null || true
    elapsed=$((elapsed + chunk))
  done
  return 0
}

# I-001 / I-002: the control-plane scripts run only from CONTROL_ROOT.
assert_control_root() {
  if [[ "$(pwd -P)" != "${CONTROL_ROOT}" ]]; then
    err "This script must run from CONTROL_ROOT (${CONTROL_ROOT})."
    err "Current directory: $(pwd -P)"
    err "Fix: cd ${CONTROL_ROOT} && bash scripts/$(basename "$0") ..."
    exit 2
  fi
}

# Parse --project and resolve PROJECT_ROOT / PROJECT_TITLE / PROJECT_STATE_ROOT.
# Usage: resolve_project "$@"  (reads only the --project flag; leaves "$@" intact)
resolve_project() {
  PROJECT_ARG=""
  local args=("$@")
  for ((i = 0; i < ${#args[@]}; i++)); do
    if [[ "${args[$i]}" == "--project" ]]; then
      PROJECT_ARG="${args[$((i + 1))]:-}"
    fi
  done
  if [[ -z "${PROJECT_ARG}" ]]; then
    err "Missing required option: --project ../PROJECT_TITLE"
    exit 2
  fi
  if [[ ! -d "${PROJECT_ARG}" ]]; then
    err "PROJECT_ROOT not found: ${PROJECT_ARG} (relative to ${CONTROL_ROOT})"
    exit 2
  fi
  PROJECT_ROOT="$(cd "${PROJECT_ARG}" && pwd -P)"
  PROJECT_TITLE="$(basename "${PROJECT_ROOT}")"
  PROJECT_STATE_ROOT="${PROJECT_ROOT}/.${TOOL}"

  case "${PROJECT_ROOT}" in
    "${CONTROL_ROOT}" | "${CONTROL_ROOT}"/*)
      err "PROJECT_ROOT must not be inside CONTROL_ROOT."
      exit 2
      ;;
  esac
  if [[ "${PROJECT_ROOT}" == "$(dirname "${CONTROL_ROOT}")" ]]; then
    err "PROJECT_ROOT must not be the workspace root itself."
    exit 2
  fi
  # META.md §5.1 fixes the topology to siblings; nonstandard nesting silently
  # weakens the path-based checkpoint guards, so it is refused outright.
  if [[ "$(dirname "${PROJECT_ROOT}")" != "$(dirname "${CONTROL_ROOT}")" ]]; then
    err "PROJECT_ROOT must be a sibling of CONTROL_ROOT (<workspace>/.${TOOL} and <workspace>/<project>, META.md §5.1)."
    err "PROJECT_ROOT: ${PROJECT_ROOT}"
    err "CONTROL_ROOT: ${CONTROL_ROOT}"
    exit 2
  fi
}

# Thin wrapper over the Lean state engine (`bin/<tool> state`).
state() {
  require_tool_bin
  "${TOOL_BIN}" state "$@"
}

# Evaluate a state yes/no predicate (should-stop / should-complete / ...).
# Stores the JSON output in the named variable and returns the predicate's
# exit code (0 = yes, 1 = no). Any other exit is a scripting/state failure and
# must never be read as "no" — that would silently unlatch a stop gate — so it
# hard-stops instead.
# Usage: if state_predicate STOP_JSON should-stop --project ...; then ...
state_predicate() {
  local __outvar="$1"
  shift
  local rc=0 out
  out="$(state "$@")" || rc=$?
  printf -v "${__outvar}" '%s' "${out}"
  if ((rc > 1)); then
    err "${TOOL} state $* failed with exit ${rc}; refusing to guess the gate state."
    exit 2
  fi
  return "${rc}"
}

# Run `<tool> state validate` tolerating validation FINDINGS (exit 1 — a
# §13.2 recoverable the next cycle's agent repairs) but never a crash (exit
# >= 2): swallowing a hard error as "validation errors remain" would hide a
# broken engine or unreadable state behind a routine warning (same fail-closed
# rule as state_predicate, I-021).
state_validate_soft() {
  local rc=0
  state validate "$@" || rc=$?
  if ((rc > 1)); then
    err "${TOOL} state validate failed with exit ${rc}; this is a framework/state failure, not a validation finding."
    exit 2
  fi
  return "${rc}"
}

# I-018: at most one canonical-write window runs per control plane at a time.
# These wrappers cover loop/resume/supervise/init/bootstrap; every mutating
# state command independently acquires or inherits the same slot.
# mkdir is the portable atomic lock (macOS ships no flock(1)); the pid file
# lets locks abandoned by dead processes be reclaimed.
LOOP_LOCK_PATH="${CONTROL_ROOT}/.agent/tmp/loop.lock"
LOOP_LOCK_DIR=""
# The per-slot coordination nonce. Children (the Lean engine, a nested
# transition) read it from the environment under the product-derived spelling,
# so the exported NAME is data here while the value lives in one shell
# variable. Seeded from an inherited environment: a cycle child must be able
# to recognize the slot its parent already owns (acquire_or_inherit_loop_lock).
LOCK_TOKEN_ENV="${TOOL_ENV}_LOCK_TOKEN"
LOOP_LOCK_TOKEN="${!LOCK_TOKEN_ENV:-}"

# The owner pid recorded in the single-flight lock; empty when no lock (or no
# pid file yet) exists. The one spelling of the lock's owner read — liveness
# stays with the caller (lock_pid_is_alive), whose reaction to a dead owner
# differs per transition.
loop_lock_owner_pid() {
  cat "${LOOP_LOCK_PATH}/pid" 2>/dev/null || true
}

# Liveness that survives EPERM: bash `kill -0` exits nonzero for a LIVE pid
# owned by another user, so it alone would read a foreign holder as dead and
# reclaim its lock (I-018). `ps -p` needs no signal permission. Fail-closed
# like the Lean twin (Io/Proc.pidAlive): only `ps` exiting 1 with an empty
# stderr positively establishes absence — a `ps` that errors (busybox has no
# `-p`; sandbox may block it) proves nothing and must read as alive (§13.5:
# "permission/sandbox/probe uncertainty never authorizes lock reclamation").
lock_pid_is_alive() {
  kill -0 "$1" 2>/dev/null && return 0
  local ps_err ps_rc=0
  ps_err="$(ps -p "$1" 2>&1 >/dev/null)" || ps_rc=$?
  if [[ ${ps_rc} -eq 0 ]]; then
    return 0
  fi
  if [[ ${ps_rc} -eq 1 && -z "${ps_err}" ]]; then
    return 1 # positively absent
  fi
  return 0 # unknown → alive (fail-closed)
}

# True when the lock directory is old enough that a holder caught between its
# mkdir and its pid write (they are two separate syscalls) cannot still be in
# flight. A vanished directory counts as stale: the next mkdir attempt decides.
loop_lock_is_stale_by_age() {
  require_tool_bin
  "${TOOL_BIN}" util file-age-exceeds "$1" 10
}

acquire_loop_lock() {
  require_tool_bin
  mkdir -p "${CONTROL_ROOT}/.agent/tmp"

  local attempt owner_pid moved_pid
  # shellcheck disable=SC2034  # `attempt` only bounds the retry count.
  for attempt in 1 2 3; do
    if mkdir "${LOOP_LOCK_PATH}" 2>/dev/null; then
      LOOP_LOCK_DIR="${LOOP_LOCK_PATH}"
      trap 'release_loop_lock' EXIT
      printf '%s\n' "$$" >"${LOOP_LOCK_PATH}/pid"
      LOOP_LOCK_TOKEN="$("${TOOL_BIN}" util token)" || {
        err "could not generate the single-flight inheritance token"
        exit 2
      }
      export "${LOCK_TOKEN_ENV}=${LOOP_LOCK_TOKEN}"
      printf '%s\n' "${LOOP_LOCK_TOKEN}" >"${LOOP_LOCK_PATH}/token"
      return 0
    fi
    owner_pid="$(loop_lock_owner_pid)"
    if [[ -n "${owner_pid}" ]] && lock_pid_is_alive "${owner_pid}"; then
      err "another ${TOOL_NAME} mutating transition is already running (pid ${owner_pid}); only one may run per control plane (I-018)."
      err "Wait for it to finish (or stop it) before retrying."
      exit 5
    fi
    if [[ -z "${owner_pid}" ]] && ! loop_lock_is_stale_by_age "${LOOP_LOCK_PATH}"; then
      # A fresh pid-less lock is almost certainly a holder mid-acquisition,
      # not debris. Reclaiming it here would erase the winner's lock and let
      # two transitions run concurrently (I-018) — refuse instead.
      err "another ${TOOL_NAME} mutating transition appears to be acquiring the lock right now (${LOOP_LOCK_PATH}); retry in a few seconds (I-018)."
      exit 5
    fi
    warn "reclaiming stale loop lock (owner pid ${owner_pid:-unknown} is not running)"
    # Reclaim by atomic rename, not rm: two invocations racing over the same
    # stale lock must not let the loser rm the winner's freshly created lock.
    # But `mv` alone is not enough: if a racer already reclaimed and recreated a
    # FRESH lock between our observation and this `mv`, our `mv` would grab and
    # destroy the racer's live lock, and both of us would then hold (I-018). So
    # verify identity — the dir we moved must carry the same (dead) pid we
    # observed. On mismatch we grabbed a stranger's lock: restore it and refuse.
    if mv "${LOOP_LOCK_PATH}" "${LOOP_LOCK_PATH}.reclaim.$$" 2>/dev/null; then
      moved_pid="$(cat "${LOOP_LOCK_PATH}.reclaim.$$/pid" 2>/dev/null || true)"
      if [[ "${moved_pid}" != "${owner_pid}" ]]; then
        # Best-effort restore. If a third party already recreated the lock,
        # POSIX `mv` onto an existing directory NESTS the source inside it
        # rather than replacing it — the racer's own pid/token stay untouched
        # and the nested dir is swept away with the lock on release. Either
        # way we never rm a dir that may be someone's live lock content.
        mv "${LOOP_LOCK_PATH}.reclaim.$$" "${LOOP_LOCK_PATH}" 2>/dev/null || true
        err "the loop lock changed hands during reclamation; retry in a few seconds (I-018)."
        exit 5
      fi
      rm -rf "${LOOP_LOCK_PATH}.reclaim.$$"
    fi
  done

  err "could not acquire the loop lock: ${LOOP_LOCK_PATH}"
  exit 5
}

release_loop_lock() {
  if [[ -n "${LOOP_LOCK_DIR}" && -d "${LOOP_LOCK_DIR}" ]]; then
    # Only remove the lock if it is still ours. A reclamation race (I-018) can
    # move our lock out from under us; deleting a dir that now holds another
    # holder's token would free a live slot for a third entrant.
    local on_disk_token
    on_disk_token="$(cat "${LOOP_LOCK_DIR}/token" 2>/dev/null || true)"
    if [[ -n "${LOOP_LOCK_TOKEN}" && "${on_disk_token}" != "${LOOP_LOCK_TOKEN}" ]]; then
      warn "the loop lock is no longer ours; leaving it in place (I-018)."
    else
      rm -rf "${LOOP_LOCK_DIR}"
    fi
    LOOP_LOCK_DIR=""
    unset "${LOCK_TOKEN_ENV}"
    LOOP_LOCK_TOKEN=""
  fi
}

# §19.1-7: graceful drain — `just stop` asks the RUNNING loop to finish the
# cycle in flight and exit cleanly at the cycle boundary (checkpoint
# committed, worktree clean, no gate latched, no resume needed). The flag is
# an operational signal for ONE loop invocation, never canonical state: it
# must not appear in should-stop reasons, gates, or commit trailers (§13.4's
# vocabulary is for conditions the AGENT hands to the human, not for the
# human pacing their own loop). It lives under .agent/state — NOT .agent/tmp
# — because the control-surface pre-tool guard denies agent writes to that
# whole surface in every domain, and the distributed settings add whatever
# deny floor the domain declares on top (§16.1); .agent/tmp is by contrast the
# agent-writable handoff area, so parking the flag there would hand the
# in-cycle agent both a stop-the-loop channel and a cancel-the-human's-stop
# channel. Gitignored, so a lingering flag never dirties the I-014
# clean-worktree assertion.
LOOP_DRAIN_PATH="${CONTROL_ROOT}/.agent/state/loop.drain"

# §26.1-5: transient staging artifacts a FRESH binding must not inherit.
#
# The distributed control plane shipped with a 2026-08-10 conformance-test
# `high_risk_pre.jsonl` still in `.agent/tmp/` — bootstrap/init never swept it.
# A stale before-hash staging file is not merely untidy: post_tool_audit pairs
# the newest pending before-hash for a path, so a leftover entry from another
# workspace can be paired with THIS project's after-hash and produce a
# high_risk_changes record that describes a change nobody made (§20.4-3).
#
# The sweep is deliberately an ENUMERATION, not `rm -rf .agent/tmp/*`: that
# directory also holds the single-flight lock (`loop.lock`, I-018) — which this
# very process owns while bootstrapping — and the live read-only handoffs
# (`triage/`, `essence/`, I-022/I-027). Blowing it away would delete the lock
# out from under the caller.
prune_stale_control_tmp() {
  local tmp="${CONTROL_ROOT}/.agent/tmp"
  local swept=0 f
  [[ -d "${tmp}" ]] || return 0
  for f in "${tmp}/high_risk_pre.jsonl" "${tmp}/guard_shadow.jsonl" \
    "${tmp}"/claude-stderr.*; do
    if [[ -f "${f}" ]]; then
      rm -f "${f}" && swept=$((swept + 1))
    fi
  done
  ((swept > 0)) && log "swept ${swept} stale staging artifact(s) from .agent/tmp (§26.1-5)"
  return 0
}

# Remove a drain request that predates this invocation (called right after
# the loop acquires its lock). Without this, a request that outlived its
# target — the loop stopped for a gate at the same boundary, or crashed —
# would silently kill the NEXT `just loop` after one cycle. Warns when it
# actually removed one, so a request lost to the (microsecond) window between
# lock acquisition and this clear is visible instead of silently swallowed.
clear_stale_drain_request() {
  if [[ -e "${LOOP_DRAIN_PATH}" ]]; then
    rm -f "${LOOP_DRAIN_PATH}"
    warn "cleared a drain request left over from before this invocation; if you meant to stop THIS loop, run \`just stop\` now (§19.1-7)."
  fi
}

# Consume a pending drain request at the cycle boundary: removes the flag and
# returns 0 when one was pending, 1 otherwise. Consumption happens BEFORE the
# post-gate check so the flag never outlives the boundary it targeted, even
# when a latched gate wins the final report.
consume_drain_request() {
  [[ -e "${LOOP_DRAIN_PATH}" ]] || return 1
  rm -f "${LOOP_DRAIN_PATH}"
  return 0
}

# §19.1-9: display-only loop heartbeat — the runtime machine state `just watch`
# renders (cycle n/max, run_id, session mode, start times). Never canonical:
# no predicate reads it, staleness is judged by the I-018 lock's liveness plus
# the recorded loop_pid (a live lock whose pid differs from the heartbeat's
# writer means a PREVIOUS invocation's record — watch shows it as last-known),
# and it is NOT deleted at loop exit (watch's last-known display). It lives
# under .agent/state for the same reason as LOOP_DRAIN_PATH above: every agent
# layer blocks writes there, so a runaway agent cannot forge a healthy
# heartbeat for the human's monitoring window (I-030 floor). Gitignored (§25).
LOOP_STATUS_PATH="${CONTROL_ROOT}/.agent/state/loop.status.json"

# write_loop_heartbeat <project-title> <cycle> <max-cycles> <run-id> \
#   <session-mode> <loop-pid> <loop-started-at-epoch>
# Best-effort by design (§19.1-9): the heartbeat is display support, so any
# failure — a missing binary included — warns and the cycle continues; it must
# never kill the loop. The JSON is assembled by the Lean subcommand, never by
# bash printf: a project title may contain `"` or `\` (R-7).
write_loop_heartbeat() {
  local bin="${CONTROL_ROOT}/bin/${TOOL}"
  if [[ ! -x "${bin}" ]] ||
    ! "${bin}" util loop-heartbeat "${LOOP_STATUS_PATH}" \
      --project "$1" --cycle "$2" --max-cycles "$3" --run-id "$4" \
      --session-mode "$5" --loop-pid "$6" --loop-started-at-epoch "$7"; then
    warn "could not write the loop heartbeat (display-only, §19.1-9); the cycle continues"
  fi
}

# §15.3: best-effort path of the Claude Code session transcript for a session
# launched from <launch-dir> — Claude Code keeps one JSONL per session at
# ~/.claude/projects/<munged-absolute-cwd>/<session-id>.jsonl, munging every
# character outside [A-Za-z0-9] to `-`. Internal format, no contract: when the
# path or format is wrong, watch degrades to its tool_audit view (§15.3).
# Empty or shape-invalid session ids print nothing (no transcript to follow;
# the shape guard also keeps a hostile session_id from steering the read via
# path segments — the id is interpolated into a filesystem path).
# claude_transcript_path_for <launch-dir> <session-id>
claude_transcript_path_for() {
  local dir="$1" sid="$2"
  [[ "${sid}" =~ ^[A-Za-z0-9_-]+$ ]] || return 0
  printf '%s\n' "${HOME}/.claude/projects/${dir//[^A-Za-z0-9]/-}/${sid}.jsonl"
}

# True when $1 is this process or one of its ancestors (walking ppid).
pid_is_self_or_ancestor() {
  local target="$1"
  local pid=$$
  while [[ "${pid}" =~ ^[0-9]+$ ]] && ((pid > 1)); do
    [[ "${pid}" == "${target}" ]] && return 0
    pid="$(ps -o ppid= -p "${pid}" 2>/dev/null | tr -d '[:space:]')"
  done
  [[ "${pid:-}" == "${target}" ]]
}

# I-018 for the non-loop mutating transitions (init, bootstrap — META.md
# §13.5). A transition invoked DURING a cycle (e.g. init's bootstrap child)
# runs as a descendant of the process that already owns the single-flight
# lock — it inherits that slot. A standalone (human) invocation takes the
# lock itself, and one racing a live foreign loop/resume is refused: it would
# mutate project files mid-cycle.
acquire_or_inherit_loop_lock() {
  local owner_pid owner_token
  owner_pid="$(loop_lock_owner_pid)"
  owner_token="$(cat "${LOOP_LOCK_PATH}/token" 2>/dev/null || true)"
  # CLAUDE_CODE_SUBPROCESS_ENV_SCRUB uses a PID namespace on Linux, so a
  # legitimate cycle child cannot always prove ancestry with ps/kill. The
  # wrapper exports this per-slot coordination nonce through the sanitized
  # session; it grants no authority the in-cycle Agent does not already have.
  if [[ -n "${LOOP_LOCK_TOKEN}" && -n "${owner_token}" && "${LOOP_LOCK_TOKEN}" == "${owner_token}" ]]; then
    log "inheriting the nonce-bound single-flight slot (pid ${owner_pid:-namespace-hidden}, I-018)"
    return 0
  fi
  if [[ -n "${owner_pid}" ]] && lock_pid_is_alive "${owner_pid}"; then
    # The standard init -> bootstrap nesting is a direct parent/child pair;
    # recognize it without ps so inheritance still works in a restricted
    # shell where process-table inspection is unavailable. Deeper descendants
    # use the ancestry walk below and fail closed if ps cannot prove it.
    if [[ "${owner_pid}" == "${PPID}" ]] || pid_is_self_or_ancestor "${owner_pid}"; then
      log "inheriting the ancestor's single-flight lock (pid ${owner_pid}, I-018)"
      return 0
    fi
    err "another ${TOOL_NAME} mutating transition is running (pid ${owner_pid}); refusing a concurrent transition (I-018)."
    err "Wait for it to finish (or stop it) before running this by hand."
    exit 5
  fi
  acquire_loop_lock
}

# The single human re-entry instruction (§13.3, I-017); printed with every
# gated stop so the operator never has to guess the next command. It
# accompanies a STOP report — guidance, not an error (§13.4-3).
print_resume_hint() {
  log "Next: inspect the cause (just status; recommendations.json / blockers.json in canonical state),"
  # The exact resume form has ONE derivation point — the should-stop message,
  # printed on the STOP line just above (§13.4-2). Repeating a fixed
  # `just resume` here would contradict it: with an open gate the bare form is
  # refused (§13.3-4'), and at the must boundary the two-way phase decision is
  # the only accepted shape (§13.1-13).
  log "fix the human-owned inputs if needed, then run the exact \`just resume …\` form named above, followed by \`just loop\` (META.md §13.3)."
  log "Or let \`just triage\` walk you through it interactively (META.md §13.6)."
}

trim_whitespace() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

# Notes travel from free-form input (a terminal paste, --note, the triage
# handoff file) into gate resolutions, the attestation ledger, and checkpoint
# commit bodies — and back onto the terminal when the human confirms them.
# Strip every control character except newline and tab so an embedded escape
# sequence can neither corrupt those records nor alter what the terminal
# shows at confirmation time. Bytes >= 0x80 pass through untouched: under
# LC_ALL=C they are opaque bytes, so multi-byte UTF-8 text (e.g. Japanese
# notes) survives intact.
sanitize_note() {
  printf '%s' "$1" | LC_ALL=C tr -d '\000-\010\013-\037\177'
}

# §13.1-8 / §2.1.1: the shipped guide block or any leftover section FILL
# marker means the Essence is not yet written. The one spelling of both
# markers; reads the file argument, or stdin when called without one. (doctor
# keeps its own per-marker greps — it diagnoses WHICH marker remains.)
essence_has_placeholder_marker() {
  grep -q -e "${TOOL_PLACEHOLDER}" -e "<!-- FILL:" "$@" 2>/dev/null
}

# META.md §8.2: the canonical projection item-id shape, `<PREFIX>-[A-Za-z0-9_+-]+`.
# This is a syntactic pre-filter in front of the state engine (which
# independently checks that the id exists, is open, and is unique); its ONLY
# job is to keep a malformed handoff/CLI string out of an argv. It must
# therefore accept exactly what the engine accepts — the same class as
# `Looper.Core.Text.isIdChar` (lean/Looper/Core/Text.lean) — because a
# stricter shell class rejects legal ids that the engine would have resolved.
# `+` and `_` are load-bearing: every loop-raised gate id embeds a local
# timestamp WITH its UTC offset (`R-LG-20260726T044234+0900-b7f8`, §21.5),
# and the offset sign is `+` for every zone at or east of UTC — a class
# without `+` makes triage unable to hand off any loop gate at all.
# Usage: valid_item_id "<value>" <literal prefix>...   (prefixes are literal,
# never regex fragments, mirroring validIdShape's literal-prefix reading.)
valid_item_id() {
  # ASCII-only like the engine's class: keep a locale's collation from widening
  # the A-Z / a-z ranges over non-ASCII letters.
  local LC_ALL=C
  local value="$1"
  shift
  local prefix rest
  for prefix in "$@"; do
    [[ "${value}" == "${prefix}-"* ]] || continue
    rest="${value#"${prefix}-"}"
    [[ "${rest}" =~ ^[A-Za-z0-9_+-]+$ ]] && return 0
  done
  return 1
}

# META.md §13.6-5: split the triage session's proposed `--resolve` ids into the
# ones resume can actually release and the ones it cannot.
#
# The engine's resolvable set is exactly `essence_blockers ∪
# blocking_recommendations ∪ human_requests` (State/Resume.lean
# `selectionError?`'s openIds). This READS those three published lists off the
# should-stop payload the wrapper already evaluated instead of re-deriving the
# rule from raw state: a second implementation of a gate rule in bash is the
# defect class §13.6-5 records, and consuming the engine's own output cannot
# drift from it.
#
# A Non-blocking Recommendation is deliberately NOT releasable here — it is the
# loop's to resolve (§21.4) — so it must be partitioned out instead of letting
# the engine refuse the entire handoff (`--resolve names no currently open
# gate`). Sets RESOLVABLE_GATE_IDS / UNRESOLVABLE_GATE_IDS (input order
# preserved).
partition_gate_decisions() {
  # Not `stop_json`: with a lowercase twin of the caller's STOP_JSON in scope,
  # every "${STOP_JSON}" in the sourcing scripts is reported as a possible
  # misspelling (SC2153).
  local stop_payload="$1"
  shift
  require_tool_bin
  local open_ids="" authorizing_ids="" key id
  for key in essence_blockers blocking_recommendations human_requests; do
    open_ids+="$(printf '%s' "${stop_payload}" |
      "${TOOL_BIN}" util json-get "${key}" --join $'\n' --default "")"$'\n'
  done
  # §13.3-4'': a supervise authorizing gate is open, but --resolve is refused
  # for it while its High-Risk Todo is unfinished (its answer is running
  # `just supervise`, not resume). The engine exposes the exact list, so the
  # narrowing here consumes it instead of re-deriving the rule from raw state.
  authorizing_ids="$(printf '%s' "${stop_payload}" |
    "${TOOL_BIN}" util json-get supervise_authorizations --join $'\n' --default "")"
  RESOLVABLE_GATE_IDS=()
  UNRESOLVABLE_GATE_IDS=()
  SUPERVISE_AUTH_GATE_IDS=()
  for id in "$@"; do
    if [[ -n "${authorizing_ids}" ]] && grep -qxF -- "${id}" <<<"${authorizing_ids}"; then
      SUPERVISE_AUTH_GATE_IDS+=("${id}")
    elif grep -qxF -- "${id}" <<<"${open_ids}"; then
      RESOLVABLE_GATE_IDS+=("${id}")
    else
      UNRESOLVABLE_GATE_IDS+=("${id}")
    fi
  done
}

# META.md §13.6-5 + §13.3-4''': the last step of the triage handoff mapping —
# turn the final (already narrowed) decision list into the exact resume
# invocation. An EMPTY list is itself a decision — "release nothing, record
# the note" — and it must be STATED to resume as --steer-only: while any
# forcing gate is open, the engine refuses a bare note-only resume (`open
# gates require explicit --resolve <ID>`), and inside triage that refusal can
# only land AFTER the interactive session has ended (observed 2026-08-10: a
# defer-every-gate handoff under an open R gate — exactly the §19.3 steering
# the flag exists for). With no forcing gate open, --steer-only runs the same
# steering transition a note-only resume would (Resume.lean fixes mode to
# steering either way), so the mapping narrows semantics, never broadens.
# Mutates TRIAGE_RESUME_ARGS in place; sets TRIAGE_STEER_ONLY=1 when the
# mapping applied (the wrapper's confirmation text branches on it).
# shellcheck disable=SC2034  # output variable consumed by sourcing launchers.
finalize_triage_resume_args() {
  TRIAGE_STEER_ONLY=0
  if ((${#TRIAGE_RESUME_ARGS[@]} == 0)); then
    TRIAGE_RESUME_ARGS=(--steer-only)
    TRIAGE_STEER_ONLY=1
  fi
}

# META.md §13.3: every resume must carry the human's intent as a natural-
# language note — it becomes each released gate's `resolution`, the
# attestation-ledger entry, and the checkpoint commit body, i.e. the only
# durable answer to "why was this gate released?". When --note is absent or
# blank, ask on the terminal instead of letting a generic default mask an
# unexplained release; without a terminal, refuse — automation must state
# its intent explicitly. Reads and rewrites the global NOTE (trimmed).
require_resume_note() {
  NOTE="$(trim_whitespace "$(sanitize_note "${NOTE:-}")")"
  [[ -n "${NOTE}" ]] && return 0

  if [[ ! -t 0 ]]; then
    err "resume records a human intervention and requires an intent note (META.md §13.3)."
    err "Fix: just resume --note \"why you intervened / what you reviewed or changed\""
    err "(or run it from an interactive terminal to be prompted)."
    exit 2
  fi

  log "resume records WHY you intervened (what you reviewed, fixed, or decided)."
  local answer
  while true; do
    if ! read -e -r -p "[${TOOL}] intent note (natural language; Ctrl-C to abort): " answer; then
      printf '\n' >&2
      err "resume aborted: no intent note was provided (EOF)."
      exit 2
    fi
    answer="$(trim_whitespace "$(sanitize_note "${answer}")")"
    if [[ -n "${answer}" ]]; then
      NOTE="${answer}"
      return 0
    fi
    warn "the note must not be empty; describe your intent in natural language."
  done
}

# Lean runtime binary: fail closed with the build hint when it is missing —
# there is no fallback engine.
require_tool_bin() {
  TOOL_BIN="${CONTROL_ROOT}/bin/${TOOL}"
  if [[ ! -x "${TOOL_BIN}" ]]; then
    err "missing ${TOOL_BIN}; build the Lean runtime first: cd ${CONTROL_ROOT} && just build"
    exit 2
  fi
}

# Domain axes the operation scripts need (META.md §26.1 seed faces, §13.3 human
# adjudication channel). These are DECLARATIONS of the domain pack, not of the
# shell: `scripts/**` is byte-identical across products, so a script that
# enumerated them would be the one place where the tree splits. The engine is
# the single source (Looper.Domain); this reads it once per invocation.
#
# Unknown keys are ignored on purpose — a new axis must not break an older
# script. A MISSING key silently disables its feature, so whoever removes one
# updates the consumer in the same commit.
DOMAIN_SPEC_LOADED=""
ADJUDICATION_FLAG=""
ADJUDICATION_ID_PREFIX=""
ADJUDICATION_ARG_FORM=""
ADJUDICATION_TARGET_NOUN=""
ADJUDICATION_STOP_PAYLOAD_KEY=""
ADJUDICATION_VERDICTS=()
BOOTSTRAP_SEEDS=()
load_domain_spec() {
  [[ -z "${DOMAIN_SPEC_LOADED}" ]] || return 0
  require_tool_bin
  local spec key rest
  # Captured first, not piped: a failing engine must stop the transition, and a
  # `while read` fed by a pipeline would swallow its exit status.
  spec="$("${TOOL_BIN}" util domain-spec)" || {
    err "cannot read the domain axes (${TOOL} util domain-spec); refusing to guess them."
    exit 2
  }
  # shellcheck disable=SC2034  # output variables consumed by sourcing scripts.
  while read -r key rest; do
    case "${key}" in
      seed) BOOTSTRAP_SEEDS+=("${rest}") ;;
      adjudication-flag) ADJUDICATION_FLAG="${rest}" ;;
      adjudication-id-prefix) ADJUDICATION_ID_PREFIX="${rest}" ;;
      adjudication-arg-form) ADJUDICATION_ARG_FORM="${rest}" ;;
      adjudication-target-noun) ADJUDICATION_TARGET_NOUN="${rest}" ;;
      adjudication-stop-payload-key) ADJUDICATION_STOP_PAYLOAD_KEY="${rest}" ;;
      adjudication-verdict) ADJUDICATION_VERDICTS+=("${rest}") ;;
      *) ;;
    esac
  done <<<"${spec}"
  DOMAIN_SPEC_LOADED=1
}

CLAUDE_TRUST_CANDIDATES=()

add_claude_trust_candidate() {
  local candidate="$1"
  local existing
  [[ -n "${candidate}" ]] || return 0
  if ((${#CLAUDE_TRUST_CANDIDATES[@]} > 0)); then
    for existing in "${CLAUDE_TRUST_CANDIDATES[@]}"; do
      [[ "${existing}" == "${candidate}" ]] && return 0
    done
  fi
  CLAUDE_TRUST_CANDIDATES+=("${candidate}")
}

collect_claude_launch_trust_candidates() {
  local launch_root="$1"
  local git_root=""
  CLAUDE_TRUST_CANDIDATES=()

  add_claude_trust_candidate "${launch_root}"
  if command -v git >/dev/null 2>&1; then
    git_root="$(git -C "${launch_root}" rev-parse --show-toplevel 2>/dev/null || true)"
    add_claude_trust_candidate "${git_root}"
  fi
}

# Optional third argument overrides the fix hint — an unbound control plane
# has no baked project, so its callers (e.g. the Essence interview before init)
# pass a hint that carries the explicit --project path.
require_claude_launch_trust() {
  local label="$1"
  local launch_root="$2"
  local fix_hint="${3:-cd ${CONTROL_ROOT} && just trust}"

  collect_claude_launch_trust_candidates "${launch_root}"
  require_tool_bin
  if "${TOOL_BIN}" trust status --quiet "${CLAUDE_TRUST_CANDIDATES[@]}"; then
    return 0
  fi

  err "Claude Code trust is missing for ${label}; refusing to launch a Claude session."
  err "Without trust, Claude Code ignores .claude/settings.json permissions and hooks."
  "${TOOL_BIN}" trust status "${CLAUDE_TRUST_CANDIDATES[@]}" >&2 || true
  err "Fix: ${fix_hint}"
  exit 2
}

# Build the environment prefix for every Claude session the framework launches.
# An Agent that can invoke Bash can inspect its inherited environment, so
# forwarding the operator's full shell environment would turn any API token,
# cloud credential, or deployment secret into Agent-readable input (I-024).
# Claude authentication must therefore come from its normal login/config
# store, not from a secret environment variable. Keep only process/runtime
# metadata required for a stable CLI launch.
build_sanitized_claude_env() {
  # Claude's own scrub is defense in depth for credentials the parent CLI may
  # obtain from its login/provider configuration after this env -i boundary.
  # It removes supported provider secrets again from Bash/hooks/MCP children.
  SANITIZED_CLAUDE_ENV=(env -i CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1)
  local name
  for name in HOME USER LOGNAME PATH SHELL TERM COLORTERM TMPDIR LANG LC_ALL LC_CTYPE NO_COLOR FORCE_COLOR "${TOOL_ENV}_TZ"; do
    # Bash 3.2 compatibility: `[[ -v name ]]` is newer. Empty optional values
    # need not be forwarded.
    if [[ -n "${!name:-}" ]]; then
      SANITIZED_CLAUDE_ENV+=("${name}=${!name}")
    fi
  done
}

# Resolve the session model override for every Claude session the framework
# launches (META.md §16.1, §30). The deployment default lives in the bound
# CONTROL_ROOT/.claude/settings.json `model` field; <TOOL>_MODEL overrides it
# for a single invocation, so a human whose default model is unavailable (usage
# limit, retirement, incident) can re-run triage/essence/supervise/loop on
# another model without editing the bound settings file. The model is a
# deployment/cost policy, never a safety boundary (§16.1): permissions, hooks
# and the sandbox are unchanged by it, so a wrong value can only cost quality,
# never authority.
#
# Sets SESSION_MODEL_ARGS to either an empty array (no override; settings.json
# decides) or (--model <value>). Callers append it with the Bash 3.2 safe
# `"${SESSION_MODEL_ARGS[@]+...}"` expansion.
#
# The value is validated rather than forwarded verbatim: it lands on a claude
# command line, so anything that is neither an official alias nor a model id is
# a typo we must refuse loudly instead of letting the CLI resolve it silently.
SESSION_MODEL_ALIASES="best default opus sonnet haiku fable opusplan"
resolve_session_model() {
  SESSION_MODEL_ARGS=()
  local model_env="${TOOL_ENV}_MODEL"
  local requested="${!model_env:-}"
  [[ -n "${requested}" ]] || return 0
  local alias found=0
  for alias in ${SESSION_MODEL_ALIASES}; do
    [[ "${requested}" == "${alias}" ]] && found=1
  done
  # Full model names (e.g. claude-opus-5) stay usable so a human can pin an
  # exact model when an alias resolves to one that is unavailable.
  if ((found == 0)) && [[ ! "${requested}" =~ ^claude-[A-Za-z0-9._-]+$ ]]; then
    err "invalid ${model_env}: ${requested}"
    err "Use an official alias (${SESSION_MODEL_ALIASES}) or a full model name (e.g. claude-opus-5)."
    exit 2
  fi
  # shellcheck disable=SC2034  # output variable consumed by sourcing launchers.
  SESSION_MODEL_ARGS=(--model "${requested}")
  log "Session model override: ${requested} (${model_env}; settings.json default ignored for this run)."
}

# Construct the mandatory per-session sandbox used by the advisory triage and
# Essence interviews (I-022/I-027). A textual Bash allowlist is not enough:
# read-looking commands such as `git diff` can invoke repository-configured
# external helpers. The OS boundary therefore makes the whole target read-only
# and protects every durable control-plane surface while leaving only the
# wrapper-cleared handoff directory writable. This also supplies the target
# boundary before init, when the project-agnostic settings cannot name it.
build_read_only_session_settings() {
  local project_root="$1"
  local handoff_root="$2"
  local variant="${3:-}" # "" | "essence-new" (ESSENCE.md ask face, §2.1.4)
  require_tool_bin
  # The settings JSON (permission `//` spelling vs sandbox single-slash paths,
  # secret input surfaces, control-plane deny-writes) is built by the pure
  # Lean core (Looper/Core/Settings.lean); the binary only resolves the
  # three roots. Unresolvable roots fail closed with exit 2.
  # shellcheck disable=SC2034  # output variable consumed by sourcing launchers.
  READ_ONLY_SESSION_SETTINGS="$("${TOOL_BIN}" util read-only-settings \
    "${project_root}" "${CONTROL_ROOT}" "${handoff_root}" ${variant:+"${variant}"})"
}

# Construct the per-launch bound-session overlay for the autonomous loop and
# the supervised High-Risk session (META.md §16.1). The git-tracked base
# settings are machine-independent; every path-bearing permission rule and
# the whole sandbox live in this overlay, generated fresh from the
# base-recorded profile and passed inline via --settings (never written to
# disk). Callers invoke this AFTER acquiring the single-flight lock, once per
# invocation: with the slot held, no framework transition can rewrite the
# base (and its profile) mid-invocation (I-018). An unbound or pre-split base fails closed
# inside the binary (exit 2 + a just-init hint) before any state is touched.
build_bound_session_settings() {
  require_tool_bin
  BOUND_SESSION_SETTINGS="$("${TOOL_BIN}" util bound-settings \
    "${PROJECT_ROOT}" "${CONTROL_ROOT}")"
  # shellcheck disable=SC2034  # output variable consumed by sourcing launchers.
  SESSION_SETTINGS_ARGS=(--settings "${BOUND_SESSION_SETTINGS}")

  # Announce a relaxed profile once per launch. This is a NOTICE, never a gate:
  # a relaxed profile is a legitimate §11.5 configuration that only a
  # human-authored ESSENCE line plus a human-only init can put in the base, so
  # there is nothing to fail closed on. It exists because the relaxation is
  # otherwise invisible at launch — after the split it shows up only as the
  # ABSENCE of ask surfaces inside an inline JSON blob nobody reads. The base
  # was just proven readable and profile-bearing by the generation above (an
  # unbound/legacy base exits 2 there), so --lenient --default keeps this
  # read from ever becoming a new failure mode of its own.
  local recorded_profile
  recorded_profile="$("${TOOL_BIN}" util json-get "_${TOOL_SNAKE}_profile" \
    --file "${CONTROL_ROOT}/.claude/settings.json" --lenient --default standard)"
  case "${recorded_profile}" in
    standard) ;;
    unsandboxed)
      warn "relaxed execution profile 'unsandboxed' is recorded in the base settings; the overlay drops the project ask surfaces and lifts the OS sandbox (META.md §11.5)"
      ;;
    *)
      warn "relaxed execution profile '${recorded_profile}' is recorded in the base settings; the overlay drops the project ask surfaces (META.md §11.5)"
      ;;
  esac
}

# Claude Code renamed the interactive "ask before edits" CLI value across
# releases (`default` in the public docs, `manual` in CLI 2.1.207). Select only
# from the choices advertised by the installed binary; never fall back to a
# looser mode. Callers refuse if neither safe spelling is present (§28.5).
resolve_interactive_permission_mode() {
  local help permission_block
  help="$(claude --help 2>/dev/null || true)"
  permission_block="$(sed -n '/--permission-mode <mode>/,/--plugin-dir/p' <<<"${help}")"
  if grep -q 'manual' <<<"${permission_block}"; then
    # shellcheck disable=SC2034  # output variable consumed by sourcing launchers.
    INTERACTIVE_PERMISSION_MODE="manual"
  elif grep -q 'default' <<<"${permission_block}"; then
    # shellcheck disable=SC2034  # output variable consumed by sourcing launchers.
    INTERACTIVE_PERMISSION_MODE="default"
  else
    err "claude CLI advertises neither manual nor default interactive permission mode; refusing an unreviewed fallback (§28.5)."
    # exit 2 (usage/environment) per the framework's exit-code vocabulary
    # (§19.1-6): every other environment refusal in these launchers uses 2, and
    # each caller invokes this as a bare command under `set -e`, so a `return 1`
    # would surface off-contract as exit 1.
    return 2
  fi
}

resolve_git_context() {
  command -v git >/dev/null 2>&1 || {
    err "git not found; cycle commits require git."
    exit 2
  }

  GIT_ROOT="$(git -C "${CONTROL_ROOT}" rev-parse --show-toplevel 2>/dev/null)" ||
    {
      err "CONTROL_ROOT is not inside a git repository."
      exit 2
    }
  PROJECT_GIT_ROOT="$(git -C "${PROJECT_ROOT}" rev-parse --show-toplevel 2>/dev/null)" ||
    {
      err "PROJECT_ROOT is not inside a git repository."
      exit 2
    }

  if [[ "${GIT_ROOT}" != "${PROJECT_GIT_ROOT}" ]]; then
    err "CONTROL_ROOT and PROJECT_ROOT must be in the same git repository for cycle commits."
    err "CONTROL_ROOT git root: ${GIT_ROOT}"
    err "PROJECT_ROOT git root: ${PROJECT_GIT_ROOT}"
    exit 2
  fi

  # Both roots are strict subdirectories of GIT_ROOT: resolve_project enforces
  # the sibling topology and the same-git-root check above already rejected
  # any layout where either root IS the git root.
  CONTROL_REL="${CONTROL_ROOT#"${GIT_ROOT}"/}"
  PROJECT_REL="${PROJECT_ROOT#"${GIT_ROOT}"/}"
}

git_in_progress_path_exists() {
  local name="$1"
  local path
  path="$(git -C "${GIT_ROOT}" rev-parse --git-path "${name}")"
  [[ -e "${path}" ]]
}

assert_git_commit_ready() {
  [[ -n "${GIT_ROOT:-}" ]] || resolve_git_context

  if git_in_progress_path_exists MERGE_HEAD || git_in_progress_path_exists REBASE_HEAD ||
    git_in_progress_path_exists rebase-merge || git_in_progress_path_exists rebase-apply ||
    git_in_progress_path_exists CHERRY_PICK_HEAD || git_in_progress_path_exists REVERT_HEAD; then
    err "git operation in progress; refusing to start a ${TOOL_NAME} cycle."
    exit 4
  fi

  # I-013 durability: a checkpoint on a detached HEAD is reachable only via
  # the reflog and silently disappears from history on the next checkout.
  git -C "${GIT_ROOT}" symbolic-ref -q HEAD >/dev/null ||
    {
      err "HEAD is detached; ${TOOL_NAME} checkpoints must land on a branch (I-013)."
      err "Fix: git -C ${GIT_ROOT} switch <branch>  (or: git switch -c <new-branch>)"
      exit 4
    }

  git -C "${GIT_ROOT}" config user.name >/dev/null ||
    {
      err "git user.name is not configured; cannot create cycle commits."
      exit 4
    }
  git -C "${GIT_ROOT}" config user.email >/dev/null ||
    {
      err "git user.email is not configured; cannot create cycle commits."
      exit 4
    }
}

assert_clean_worktree_for_cycle() {
  [[ -n "${GIT_ROOT:-}" ]] || resolve_git_context
  assert_git_commit_ready

  local status
  status="$(git -C "${GIT_ROOT}" status --porcelain --untracked-files=all)"
  if [[ -n "${status}" ]]; then
    err "${TOOL_NAME} cycle commits require a clean worktree before each cycle (I-014)."
    err "If these are your own edits (e.g. ESSENCE.md), run \`just resume\` to record them as a review checkpoint (META.md §13.3)."
    err "If a loop crashed mid-cycle, review the diff and run \`just resume --force\` (META.md §13.5)."
    git -C "${GIT_ROOT}" status --short --untracked-files=all >&2
    exit 4
  fi
}

is_forbidden_cycle_commit_path() {
  local path="$1"

  # The leading "/" makes the `*/` patterns cover both a workspace at the git
  # root (path ".<tool>/...") and a workspace nested inside a larger repo
  # (path "sub/ws/.<tool>/..."); without it the control-plane patterns went
  # silently blind in nested layouts.
  case "/${path}" in
    */".${TOOL}"/.agent/runs/.gitkeep | */".${TOOL}"/.agent/tmp/.gitkeep)
      return 1
      ;;
    */".${TOOL}"/.agent/runs/* | */".${TOOL}"/.agent/tmp/*)
      return 0
      ;;
    */".${TOOL}"/tmp/.gitkeep)
      return 1
      ;;
    */".${TOOL}"/tmp/*)
      return 0
      ;;
    */.env | */.env.* | */secrets/* | */config/credentials.json)
      return 0
      ;;
    # Atomic-write debris: a crash between the tmp write and its rename leaves
    # <name>.<pid>.<hex>.tmp next to canonical state (write_json), a
    # *.render/*.seed tmp next to a bound file, or a *.essence tmp next to
    # ESSENCE.md (the Essence interview's install). Committing it would launder
    # half-written content into a checkpoint; keep it out so the human deletes
    # or inspects it instead.
    */".${TOOL}"/state/*.tmp | */.agent/state/*.tmp | *.render.*.tmp | *.seed.*.tmp | *.essence.*.tmp)
      return 0
      ;;
  esac

  return 1
}

guard_cycle_commit_paths() {
  [[ -n "${GIT_ROOT:-}" ]] || resolve_git_context

  local path
  while IFS= read -r -d '' path; do
    if is_forbidden_cycle_commit_path "${path}"; then
      err "Forbidden path staged for cycle commit: ${path}"
      return 1
    fi
  done < <(git -C "${GIT_ROOT}" diff --cached --no-renames --name-only -z)
}

# Human-gated paths a non-interactive cycle can never legitimately edit
# (hooks/permissions hold them at deny or ask, and ask auto-denies under
# `claude -p`). A diff on them during a cycle is therefore a HUMAN mid-cycle
# edit; committing it as `<tool>: cycle` would be indistinguishable from an
# agent violation in the audit trail, so cycle checkpoints exclude the whole
# set (I-020 generalized; ESSENCE.md and essences/** additionally latch the
# essence_unreviewed_change stop, the rest surface via the next cycle's
# clean-worktree refusal until the human records them with `just resume`).
# essences/** is the human-owned asset directory ESSENCE.md refers to
# (§2.1.5): like ESSENCE.md itself, its diffs enter history only through a
# human resume checkpoint. README.md is NOT here: it is an ordinary
# implementation file the agent owns (§11.1) and its diffs ride in the cycle
# commit like any src/ change.
is_cycle_human_leftover_path() {
  local path="$1"
  case "${path}" in
    "${PROJECT_REL}/ESSENCE.md" | "${PROJECT_REL}/essences/"* | "${PROJECT_REL}/CLAUDE.md" | "${PROJECT_REL}/.claude/"*)
      return 0
      ;;
  esac
  return 1
}

# An optional first argument names a predicate function for paths a checkpoint
# deliberately leaves uncommitted (I-020: a cycle commit never carries
# ESSENCE.md or the other human-gated control files).
guard_no_unstaged_cycle_changes() {
  local leftover_fn="${1:-}"
  [[ -n "${GIT_ROOT:-}" ]] || resolve_git_context

  local found=0
  local path
  while IFS= read -r -d '' path; do
    [[ -n "${leftover_fn}" ]] && "${leftover_fn}" "${path}" && continue
    err "Unstaged change remains outside the cycle commit: ${path}"
    found=1
  done < <(git -C "${GIT_ROOT}" diff --no-renames --name-only -z)
  while IFS= read -r -d '' path; do
    [[ -n "${leftover_fn}" ]] && "${leftover_fn}" "${path}" && continue
    err "Untracked change remains outside the cycle commit: ${path}"
    found=1
  done < <(git -C "${GIT_ROOT}" ls-files --others --exclude-standard -z)

  [[ "${found}" -eq 0 ]]
}

# Emit every uncommitted path (unstaged, staged, untracked) in GIT_ROOT,
# NUL-terminated, respecting .gitignore — the same set the checkpoint guards
# will later judge.
list_uncommitted_paths() {
  [[ -n "${GIT_ROOT:-}" ]] || resolve_git_context

  git -C "${GIT_ROOT}" diff --no-renames --name-only -z
  git -C "${GIT_ROOT}" diff --cached --no-renames --name-only -z
  git -C "${GIT_ROOT}" ls-files --others --exclude-standard -z
}

# Refuse before any state mutation if the eventual review checkpoint would be
# rejected by the commit guards; a post-mutation abort would leave a
# half-applied resume on disk.
assert_resume_checkpoint_feasible() {
  assert_git_commit_ready

  local ok=1
  local path
  while IFS= read -r -d '' path; do
    if ! path_in_checkpoint_scope "${path}"; then
      err "Uncommitted change outside the checkpoint scope: ${path}"
      ok=0
    elif is_forbidden_cycle_commit_path "${path}"; then
      err "Uncommitted change on a forbidden checkpoint path: ${path}"
      ok=0
    elif [[ -f "${GIT_ROOT}/${path}" ]] &&
      LC_ALL=C grep -I -q -E -e "${SECRET_SCAN_PATTERN}" "${GIT_ROOT}/${path}" 2>/dev/null; then
      # Pre-empt the commit-time staged-blob scan (guard_no_staged_secrets):
      # without this, a resume would release gates and append the attestation,
      # then abort at commit, leaving a half-applied resume on disk. The
      # authoritative scan stays the index-blob scan at commit; this is the
      # worktree-side pre-check that keeps the mutation from starting (§22.1).
      err "Potential secret in an uncommitted file the checkpoint would carry: ${path}"
      ok=0
    fi
  done < <(list_uncommitted_paths)

  if [[ "${ok}" -ne 1 ]]; then
    err "Resume refused before touching state: commit, stash, or remove the paths above first."
    exit 4
  fi
}

path_in_checkpoint_scope() {
  local path="$1"

  case "${path}" in
    "${CONTROL_REL}" | "${CONTROL_REL}"/* | "${PROJECT_REL}" | "${PROJECT_REL}"/*)
      return 0
      ;;
  esac

  return 1
}

guard_no_staged_outside_checkpoint_scope() {
  [[ -n "${GIT_ROOT:-}" ]] || resolve_git_context

  local found=0
  local path
  while IFS= read -r -d '' path; do
    if ! path_in_checkpoint_scope "${path}"; then
      err "Staged change remains outside the checkpoint scope: ${path}"
      found=1
    fi
  done < <(git -C "${GIT_ROOT}" diff --cached --no-renames --name-only -z)

  [[ "${found}" -eq 0 ]]
}

# Last line of defense before a durable checkpoint: scan the exact staged blob
# for high-confidence credential shapes without ever printing the matched
# secret. This complements environment/path isolation—I-024 cannot prevent a
# noisy tool from copying a credential into ordinary source or canonical
# evidence. There is deliberately no in-band suppression marker: an Agent that
# can edit staged content could otherwise authorize its own bypass.
# Single definition of the high-confidence credential signature set, shared by
# the authoritative staged-blob scan (`staged_path_has_secret`, index bytes at
# commit time) and the resume feasibility pre-scan (`assert_resume_checkpoint_
# feasible`, worktree bytes before state mutation). One source keeps the two
# faces from drifting (§22.1 / I-024).
SECRET_SCAN_PATTERN='-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{50,}|xox[baprs]-[A-Za-z0-9-]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|sk-(proj-)?[A-Za-z0-9_-]{32,}'

staged_path_has_secret() {
  local path="$1"
  local pattern="${SECRET_SCAN_PATTERN}"

  # `git grep --cached` reads the exact index blob, not the worktree. `-I`
  # skips binary blobs; `-q` ensures neither the credential nor its line is
  # emitted. Exit >1 remains distinguishable from the clean/no-match exit 1.
  # `-e` is mandatory, not stylistic: the pattern starts with `-----BEGIN`,
  # which a positional argument position would parse as an unknown option and
  # turn every scan into exit 129 (i.e. the guard would fail closed on every
  # checkpoint, never actually scanning).
  git -C "${GIT_ROOT}" grep --cached -I -q -E -e "${pattern}" -- "${path}"
}

guard_no_staged_secrets() {
  [[ -n "${GIT_ROOT:-}" ]] || resolve_git_context

  local found=0
  local path
  local paths_file=""
  paths_file="$(mktemp "${TMPDIR:-/tmp}/${TOOL}-staged-paths.XXXXXX")" || {
    err "Unable to allocate the staged-secret scan input."
    return 1
  }
  if ! git -C "${GIT_ROOT}" diff --cached --name-only -z --diff-filter=ACMR >"${paths_file}"; then
    rm -f "${paths_file}"
    err "Unable to enumerate staged content for the secret scan."
    return 1
  fi
  while IFS= read -r -d '' path; do
    local scan_rc=0
    staged_path_has_secret "${path}" || scan_rc=$?
    if [[ "${scan_rc}" -eq 0 ]]; then
      err "Potential secret detected in staged content: ${path}"
      found=1
    elif [[ "${scan_rc}" -ne 1 ]]; then
      err "Unable to inspect staged content for potential secrets: ${path}"
      found=1
    fi
  done <"${paths_file}"
  rm -f "${paths_file}"
  if [[ "${found}" -ne 0 ]]; then
    err "Checkpoint refused before commit; remove/redact the credential."
    return 1
  fi
}

# Stage every CONTROL_ROOT/PROJECT_ROOT change, enforce the checkpoint path
# guards, and create exactly one commit. `on_empty` is "fail" (cycle commits
# must never be empty) or "skip" (a resume may find nothing left to record).
# `leftover_fn` optionally names a predicate for paths that are deliberately
# excluded from the checkpoint and left dirty for the human (I-020: cycle
# commits never carry ESSENCE.md or the other human-gated control files; a
# mid-cycle human edit waits for its own resume checkpoint).
create_guarded_checkpoint() {
  local subject="$1"
  local body="$2"
  local on_empty="${3:-fail}"
  local leftover_fn="${4:-}"

  [[ -n "${GIT_ROOT:-}" ]] || resolve_git_context
  assert_git_commit_ready

  git -C "${GIT_ROOT}" add -A -- "${CONTROL_REL}" "${PROJECT_REL}"
  if [[ -n "${leftover_fn}" ]]; then
    local staged
    while IFS= read -r -d '' staged; do
      if "${leftover_fn}" "${staged}"; then
        git -C "${GIT_ROOT}" reset -q -- "${staged}" >/dev/null 2>&1 || true
      fi
    done < <(git -C "${GIT_ROOT}" diff --cached --no-renames --name-only -z)
    # Fail-closed: no human-gated path may survive the reset still staged.
    # --no-renames above makes a mid-cycle rename's source-side deletion a
    # distinct staged record the loop resets; this assertion turns any future
    # regression that would let one ride the cycle commit into a loud abort
    # rather than a silent I-020 leak (§24.3).
    while IFS= read -r -d '' staged; do
      if "${leftover_fn}" "${staged}"; then
        git -C "${GIT_ROOT}" reset -q -- "${CONTROL_REL}" "${PROJECT_REL}"
        err "Human-gated path still staged after the leftover reset (I-020): ${staged}"
        exit 4
      fi
    done < <(git -C "${GIT_ROOT}" diff --cached --no-renames --name-only -z)
  fi
  if ! guard_no_staged_outside_checkpoint_scope; then
    git -C "${GIT_ROOT}" reset -q -- "${CONTROL_REL}" "${PROJECT_REL}"
    err "Checkpoint commit aborted; staged changes outside the checkpoint scope require human review."
    exit 4
  fi
  if ! guard_cycle_commit_paths; then
    git -C "${GIT_ROOT}" reset -q -- "${CONTROL_REL}" "${PROJECT_REL}"
    err "Checkpoint commit aborted; forbidden paths were left unstaged for human review."
    exit 4
  fi
  if ! guard_no_unstaged_cycle_changes "${leftover_fn}"; then
    git -C "${GIT_ROOT}" reset -q -- "${CONTROL_REL}" "${PROJECT_REL}"
    err "Checkpoint commit aborted; uncommitted changes outside the checkpoint scope require human review."
    exit 4
  fi
  if ! guard_no_staged_secrets; then
    git -C "${GIT_ROOT}" reset -q -- "${CONTROL_REL}" "${PROJECT_REL}"
    exit 4
  fi

  if git -C "${GIT_ROOT}" diff --cached --quiet --exit-code; then
    if [[ "${on_empty}" == "skip" ]]; then
      log "no changes to commit for: ${subject}"
      return 0
    fi
    err "No staged changes for ${subject}; refusing to create an empty checkpoint."
    exit 4
  fi

  git -C "${GIT_ROOT}" commit -m "${subject}" -m "${body}" >/dev/null
  log "committed: ${subject}"

  # -z (NUL-separated, C-quoting disabled) is mandatory: the default
  # --porcelain quotes and C-escapes any non-ASCII path (core.quotePath=true),
  # so `${line:3}` on a Japanese {project-title} or an essences/入力/… asset
  # (§2.1.5) would misread the leftover path, fail to match it as a human-gated
  # I-020 leftover, and turn a correct cycle checkpoint into a spurious exit 4
  # instead of the designed warn + STOP (§19.1-6, §24.3). Each -z record is the
  # 3-char `XY ` status prefix followed by the verbatim path.
  local rec path dirty_other=0 leftover_dirty=""
  while IFS= read -r -d '' rec; do
    path="${rec:3}"
    if [[ -n "${leftover_fn}" ]] && "${leftover_fn}" "${path}"; then
      leftover_dirty="${leftover_dirty:+${leftover_dirty}, }${path}"
      continue
    fi
    dirty_other=1
  done < <(git -C "${GIT_ROOT}" -c core.quotePath=false status --porcelain -z --untracked-files=all)
  if [[ "${dirty_other}" -eq 1 ]]; then
    err "Checkpoint commit completed, but the worktree is still dirty."
    git -C "${GIT_ROOT}" status --short --untracked-files=all >&2
    exit 4
  fi
  if [[ -n "${leftover_dirty}" ]]; then
    warn "human-gated file(s) changed during this cycle and were NOT committed (I-020): ${leftover_dirty}"
    warn "Record them as a human intervention: \`just resume\` (META.md §13.3) — the next cycle refuses to start until then."
  fi
}

commit_cycle_checkpoint() {
  local run_id="$1"
  local cycle="$2"
  local max_cycles="$3"
  local run_status="$4"
  local validation_status="$5"

  local body
  body="Project: ${PROJECT_TITLE}
Cycle: ${cycle}/${max_cycles}
Run-Status: ${run_status}
Validation: ${validation_status}

${TOOL_TRAILER}-Project: ${PROJECT_TITLE}
${TOOL_TRAILER}-Run-Id: ${run_id}
${TOOL_TRAILER}-Run-Status: ${run_status}
${TOOL_TRAILER}-Validation: ${validation_status}"

  # I-020 (generalized): human-gated files (ESSENCE.md, and — where the target
  # embeds an agent — CLAUDE.md / .claude/** of PROJECT_ROOT) never ride in an
  # agent cycle commit — their diffs stay in the worktree for the human's own
  # resume checkpoint.
  create_guarded_checkpoint "${TOOL}: cycle ${run_id}" "${body}" fail \
    is_cycle_human_leftover_path
}

# Human review checkpoint (META.md §13.3): captures the human's fixes (e.g.
# ESSENCE.md) plus the resume state transition as one commit, so the next
# cycle starts from a clean worktree (I-014). `mode` comes from `<tool> state
# resume`: "gate_release" records a stop-gate release as `human resume`,
# "steering" records a mid-course human edit as `human update`. When the
# resume closed a crashed run (`--force`, §13.5) the checkpoint is labeled
# `crash recovery` instead, because its content includes leftovers of the
# aborted agent cycle, not only human edits.
commit_resume_checkpoint() {
  local note="$1"
  local mode="${2:-gate_release}"
  local closed_runs="${3:-}"

  local event="human-resume"
  local subject="${TOOL}: human resume (${PROJECT_TITLE})"
  if [[ "${mode}" == "steering" ]]; then
    event="human-update"
    subject="${TOOL}: human update (${PROJECT_TITLE})"
  fi
  if [[ -n "${closed_runs}" ]]; then
    event="crash-recovery"
    subject="${TOOL}: crash recovery (${PROJECT_TITLE})"
  fi

  local body
  body="Project: ${PROJECT_TITLE}
Event: ${event}
Mode: ${mode}
Note: ${note:-(none)}

${TOOL_TRAILER}-Project: ${PROJECT_TITLE}
${TOOL_TRAILER}-Event: ${event}"
  if [[ -n "${closed_runs}" ]]; then
    body="${body}
${TOOL_TRAILER}-Closed-Runs: ${closed_runs}"
  fi

  create_guarded_checkpoint "${subject}" "${body}" skip
}

read_validation_status() {
  require_tool_bin
  # --lenient: an unreadable or corrupt validation.json reads as "unknown"
  # (display-only value, never a gate — the gates re-read state themselves).
  "${TOOL_BIN}" util json-get status \
    --file "${PROJECT_STATE_ROOT}/state/validation.json" \
    --default unknown --lenient
}

stop_message_from_json() {
  require_tool_bin
  "${TOOL_BIN}" util json-get message \
    --default "Stop condition detected." <<<"$1"
}

# Run-Status from a should-stop payload. The priority order lives in exactly
# one place — Looper/Core/Stop.lean — shared by this helper via the binary
# (D-005).
stop_run_status_from_json() {
  require_tool_bin
  "${TOOL_BIN}" util stop-status <<<"$1"
}

# §13.4-2: the exact `just resume …` form has ONE derivation point — the
# should-stop message (the same line `just status` prints as STOP and the loop
# prints on a gated exit). A wrapper that tells the human how to resume must
# print THIS instead of spelling a fixed form: with any open gate a bare
# `just resume` is refused (§13.3-4'), so a fixed spelling is wrong exactly
# when the guidance matters most (the 2026-07-27 / 2026-08-04 refusals both
# came from copying a spelled-out form the state no longer accepted).
# Prints the message and returns 0 when a stop is latched. Prints nothing and
# returns 1 when no stop is latched — there the bare `just resume --note "..."`
# steering form IS the accepted form (§13.3) and the caller owns that static
# spelling. Prints nothing and returns 2 when the predicate crashed —
# fail-closed (I-021): guidance is never derived from a gate state that could
# not be read; callers point at `just status` instead.
resume_guidance() {
  local payload rc=0
  payload="$(state should-stop --project "${PROJECT_ARG}")" || rc=$?
  if ((rc == 0)); then
    stop_message_from_json "${payload}"
    return 0
  elif ((rc == 1)); then
    return 1
  else
    return 2
  fi
}
