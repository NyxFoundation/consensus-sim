#!/usr/bin/env bash
# watch.sh — live read-only TUI over the running loop (META.md §15.3).
#
# A pure observer: joins the running `just loop` from another terminal and
# redraws one frame about every second from the same observations the gate
# predicates read — I-018 lock liveness, the §19.1-7 drain flag, the §19.1-9
# heartbeat, canonical state, tool_audit.jsonl, and (best-effort) the Claude
# Code session transcript. Quitting the TUI never touches the loop or
# canonical state, and it also works while no loop runs (last-known display).
#
# The frame is computed by `<tool> state watch-render` (status-shaped: the
# IO shell reads, the pure core renders exactly rows lines of exactly cols
# display width). This wrapper owns only the terminal control (alternate
# screen, cursor, 1s tick, `q`) and the observation legwork the binary cannot
# do portably: stty size, ps liveness, bounded tails.
#
# Human-only: a resident interactive program — a cycle that launches it never
# returns and wedges (§18.4). The pre-tool guard hook denies this script and
# `just watch` to agents; the same information is agent-reachable through the
# permitted `state status` / `should-stop`.
#
# Usage: cd ./.<tool> && bash scripts/watch.sh --project ../PROJECT_TITLE
#
# Exit codes: 0 = quit by the human (q). 130/143/129 = interrupted
# (INT/TERM/HUP — same vocabulary as the other wrappers; the terminal is
# restored either way). 2 = usage/environment error (unknown argument, no TTY,
# unresolvable project) or a watch-render failure — fail-closed: the TUI never
# keeps looping over a frame it could not draw.

# shellcheck source=./_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

assert_control_root

# Consume flags strictly, BEFORE resolve_project scans anything (same rule as
# stop.sh): a silently dropped flag would watch something other than
# what the human asked for.
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
    *)
      err "unknown argument: ${args[$i]}"
      err "usage: bash scripts/watch.sh --project ../PROJECT_TITLE"
      exit 2
      ;;
  esac
done

resolve_project "$@"

# Full-screen TUI: without a terminal there is nothing to draw on, and leaking
# alternate-screen escapes into a pipe would corrupt whatever reads it. Checked
# before any escape byte is emitted (SH-027).
if [[ ! -t 0 || ! -t 1 ]]; then
  err "watch is an interactive, human-only viewer; run it from a terminal (META.md §15.3)."
  exit 2
fi

require_tool_bin

AUDIT_LOG="${CONTROL_ROOT}/.agent/state/tool_audit.jsonl"
mkdir -p "${CONTROL_ROOT}/.agent/tmp"
WATCH_TMP="$(mktemp -d "${CONTROL_ROOT}/.agent/tmp/watch.XXXXXX")"

COLOR_ARGS=()
[[ -n "${NO_COLOR:-}" ]] && COLOR_ARGS=(--no-color)

# Alternate screen + hidden cursor for the session; EXIT restores both and
# removes the tail scratch dir. INT/TERM/HUP funnel through exit so the EXIT
# trap always runs — the terminal must come back, whatever ends us. A failure
# reason is buffered in WATCH_ERR and printed only AFTER the restore: anything
# written while the alternate screen is active is discarded with it, so an
# error printed there would vanish before the human could read it.
WATCH_ERR=""
restore_terminal() {
  printf '\033[?1049l\033[?25h'
  rm -rf "${WATCH_TMP}"
  if [[ -n "${WATCH_ERR}" ]]; then
    err "${WATCH_ERR}"
  fi
}
trap 'restore_terminal' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
printf '\033[?1049h\033[?25l'

while :; do
  TICK_START=${SECONDS}

  # Terminal geometry per tick — resizes just work, no SIGWINCH machinery.
  # Two positive integers required: some pseudo-TTYs (script(1), fresh ptys)
  # report "0 0", which would render a degenerate zero-line frame.
  SIZE="$(stty size </dev/tty 2>/dev/null || true)"
  ROWS=""
  COLS=""
  read -r ROWS COLS _ <<<"${SIZE}" || true
  [[ "${ROWS}" =~ ^[1-9][0-9]*$ && "${COLS}" =~ ^[1-9][0-9]*$ ]] || {
    ROWS=24
    COLS=80
  }

  RENDER_ARGS=(--cols "${COLS}" --rows "${ROWS}" --now "$(date +%s)")
  RENDER_ARGS+=("${COLOR_ARGS[@]+"${COLOR_ARGS[@]}"}")

  OWNER_PID="$(loop_lock_owner_pid)"
  if [[ -n "${OWNER_PID}" ]]; then
    RENDER_ARGS+=(--lock-pid "${OWNER_PID}")
    lock_pid_is_alive "${OWNER_PID}" && RENDER_ARGS+=(--lock-alive yes)
  fi
  [[ -e "${LOOP_DRAIN_PATH}" ]] && RENDER_ARGS+=(--drain-pending)
  [[ -f "${LOOP_STATUS_PATH}" ]] && RENDER_ARGS+=(--heartbeat "${LOOP_STATUS_PATH}")

  if [[ -f "${AUDIT_LOG}" ]]; then
    tail -n 40 "${AUDIT_LOG}" >"${WATCH_TMP}/audit.jsonl" 2>/dev/null || true
    RENDER_ARGS+=(--tool-audit-tail "${WATCH_TMP}/audit.jsonl")
    # §15.3 best-effort: the latest session's transcript, when it exists at the
    # documented location — anything else degrades to the tool_audit view.
    SID="$(tail -n 1 "${AUDIT_LOG}" 2>/dev/null |
      "${TOOL_BIN}" util json-get session_id --lenient)"
    TRANSCRIPT="$(claude_transcript_path_for "${CONTROL_ROOT}" "${SID}")"
    if [[ -n "${TRANSCRIPT}" && -f "${TRANSCRIPT}" ]]; then
      tail -c 131072 "${TRANSCRIPT}" >"${WATCH_TMP}/transcript.jsonl" 2>/dev/null || true
      RENDER_ARGS+=(--transcript-tail "${WATCH_TMP}/transcript.jsonl")
    fi
  fi

  # Fail-closed: a frame that cannot be computed ends the watch (the EXIT trap
  # restores the screen, then prints the buffered reason) instead of spinning
  # over a dead view. Broken STATE renders fine — the engine maps it to an
  # EVAL ERROR frame (§19.1-3); a nonzero here means watch-render itself could
  # not run.
  FRAME="$("${TOOL_BIN}" state watch-render --project "${PROJECT_ARG}" \
    ${RENDER_ARGS[@]+"${RENDER_ARGS[@]}"} 2>"${WATCH_TMP}/render.err")" || {
    WATCH_ERR="watch-render failed: $(tr '\n' ' ' <"${WATCH_TMP}/render.err") — not continuing with a stale screen."
    exit 2
  }
  printf '\033[H%s' "${FRAME}"

  # Pacing: the read's 1s timeout is the tick clock, but on bash 3.2 a
  # timed-out read exits 1 — indistinguishable from a dead /dev/tty — so a
  # read failure must not end the watch. Instead, when the whole tick fit
  # inside one wall-clock second (a >1s timeout always crosses a SECONDS
  # boundary; an instant EOF does not), sleep the remainder out: a dead tty
  # degrades to ~1 fps until the pty itself dies (set -e on the failing
  # printf above), never to a busy loop.
  KEY=""
  IFS= read -rsn1 -t 1 KEY </dev/tty || KEY=""
  ((SECONDS - TICK_START == 0)) && sleep 1
  [[ "${KEY}" == "q" ]] && exit 0
done
