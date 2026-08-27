#!/usr/bin/env bash
# triage.sh — human-only interactive triage of the current stop gates
# (META.md §13.6).
#
# When the loop has stopped on human gates, this launches an INTERACTIVE
# Claude session at CONTROL_ROOT (slash command /triage) that takes over the
# human's side of the stop: it classifies every open gate item into
#   - dispatchable: the answer is a fact derivable from the Essence, the
#     canonical state, or the repository — the session settles it
#     on the human's behalf and folds the conclusion into the resume note;
#   - human-required: a genuine human decision (priorities, requirement
#     trade-offs, spend/permission approvals, secrets, ESSENCE.md changes) —
#     the session asks the minimal essential questions, refines the
#     requirement, and presents step-by-step actions for the human.
#
# The session is advisory and read-only (I-022): Edit/NotebookEdit tools are
# disabled, the Write tool is hook-confined to the gitignored handoff dir
# .agent/tmp/triage/ (the only path the session writes — §13.6-3), and
# permission mode is the CLI's ask-before-edits mode (no auto-accept). It never
# implements anything — implementation belongs to `just loop` after resume.
#
# Handoff: the session writes both the proposed resume intent note and an
# explicit decision list (resolve IDs / phase decision). An EMPTY decision
# list maps to a `--steer-only` resume — the note and the human's input edits
# are recorded, every open gate stays open (§13.3-4'''). This wrapper shows
# the exact invocation and runs resume.sh ONLY after an explicit y on
# the terminal; it never passes --force and never starts `just loop`.
#
# Human-only: refuses without a terminal, and the pre-tool guard hook denies this
# script / `just triage` to agents (I-011, §18.2) — an agent can neither
# spawn a triage session nor reach resume through it.
#
# Triage sits outside the single-flight boundary (I-018): the session is
# read-only and takes no lock; the confirmed resume child acquires and
# arbitrates the lock itself as usual.
#
# Usage: cd ./.<tool> && bash scripts/triage.sh --project ../PROJECT_TITLE

# shellcheck source=./_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

assert_control_root

# Strict flag parsing (same rule as stop.sh / loop.sh / resume.sh): a silently
# dropped argument would run a different action than the human asked for.
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
      err "usage: bash scripts/triage.sh --project ../PROJECT_TITLE"
      exit 2
      ;;
  esac
done

resolve_project "$@"

TRIAGE_DIR="${CONTROL_ROOT}/.agent/tmp/triage"
NOTE_FILE="${TRIAGE_DIR}/resume_note.txt"
DECISIONS_FILE="${TRIAGE_DIR}/resume_decisions.txt"
TRIAGE_COMMAND_FILE="${CONTROL_ROOT}/.claude/commands/triage.md"

# Interactive and human-only by definition: the session interviews the human,
# and the handoff below can end in a resume. Without a terminal there is no
# human to interview or to confirm (agents are additionally denied by
# the pre-tool guard hook before ever reaching this check).
if [[ ! -t 0 || ! -t 1 ]]; then
  err "triage is an interactive, human-only session; run it from a terminal (META.md §13.6)."
  exit 2
fi

command -v claude >/dev/null 2>&1 || {
  err "claude CLI not found; cannot run triage."
  exit 2
}
resolve_interactive_permission_mode
resolve_session_model
build_sanitized_claude_env
[[ -f "${TRIAGE_COMMAND_FILE}" ]] ||
  {
    err "missing ${TRIAGE_COMMAND_FILE}; the /triage slash command is not installed."
    exit 2
  }
require_claude_launch_trust "Over-Project Agent" "${CONTROL_ROOT}"

# Read-only pre-flight, same fail-closed predicate discipline as the loop
# (I-021): triage exists for a stopped workflow only. Steering and crash
# recovery keep their own entrances (§13.3, §13.5).
if state_predicate STOP_JSON should-stop --project "${PROJECT_ARG}"; then
  log "STOP: $(stop_message_from_json "${STOP_JSON}")"
elif state_predicate COMPLETE_JSON should-complete --project "${PROJECT_ARG}"; then
  COMPLETION_SCOPE="$("${TOOL_BIN}" util json-get completion_scope <<<"${COMPLETE_JSON}")"
  log "COMPLETE: full_complete (${COMPLETION_SCOPE} scope, §19.3); nothing to triage."
  exit 0
else
  log "RUNNABLE: no stop gate is latched; nothing to triage."
  log "For mid-course edits, edit the inputs and run \`just resume\` (steering, META.md §13.3);"
  log "after a crash, follow \`just status\` / \`just doctor\` guidance (META.md §13.5)."
  exit 0
fi

# Fresh handoff dir BEFORE the session: only a note written by THIS session
# may reach the confirmation below — a stale or foreign note must never be
# offered for resume (§13.6-5).
rm -rf "${TRIAGE_DIR}"
mkdir -p "${TRIAGE_DIR}"
build_read_only_session_settings "${PROJECT_ROOT}" "${TRIAGE_DIR}"

log "Launching the interactive triage session (read-only; writes confined to the handoff dir — I-022)."
log "End the session (/exit or Ctrl+D) once it has printed its summary and written the note."
# The prompt comes FIRST so the variadic --disallowedTools list cannot swallow
# it. Write stays enabled — the pre-tool guard confines it to the handoff dir
# (allow inside, teaching deny outside; §13.6-3) so the session can hand off
# the note without wrestling a heredoc. This only works because no settings
# deny covers .agent/tmp: a permissions deny always outranks a hook allow, and
# on CLI >=2.1.216 an Edit deny also reaches Bash write targets and the
# sandbox profile (§19.1-5, §28.5-3). --add-dir grants read access to the
# target: the base settings carry no additionalDirectories since the
# base/overlay split (§16.1), and the read-only overlay's sandbox keeps the
# target read-only regardless. The resolved interactive permission mode keeps
# every unmatched action behind an interactive ask; the control-plane hooks
# stay fully active inside.
CLAUDE_RC=0
"${SANITIZED_CLAUDE_ENV[@]}" CLAUDE_CODE_SKIP_PROMPT_HISTORY=1 "${TOOL_ENV}_SESSION_MODE=triage" "${TOOL_ENV}_SESSION_PROJECT_ROOT=${PROJECT_ROOT}" claude "/triage --project ${PROJECT_ARG}" \
  "${SESSION_MODEL_ARGS[@]+"${SESSION_MODEL_ARGS[@]}"}" \
  --permission-mode "${INTERACTIVE_PERMISSION_MODE}" \
  --setting-sources project \
  --strict-mcp-config \
  --add-dir "${PROJECT_ROOT}" \
  --settings "${READ_ONLY_SESSION_SETTINGS}" \
  --disallowedTools Edit NotebookEdit || CLAUDE_RC=$?
((CLAUDE_RC == 0)) || warn "claude exited nonzero (${CLAUDE_RC}); reviewing any handoff it left anyway."

# Sanitize before showing: the note is session-written free text that goes
# straight to the human's terminal for the y/N confirmation and then into the
# canonical records (§13.6-5), so control characters must not reach either.
# A note that is blank after sanitizing is no note at all — offering it would
# just re-open the interactive note prompt inside resume (§13.3).
NOTE=""
if [[ -s "${NOTE_FILE}" ]]; then
  NOTE="$(trim_whitespace "$(sanitize_note "$(cat "${NOTE_FILE}")")")"
fi
if [[ -z "${NOTE}" ]]; then
  log "No usable resume note was handed off; nothing was changed."
  print_resume_hint
  exit 0
fi

# The advisory session may propose decisions, but it cannot silently broaden
# them: accept only the tiny line protocol documented in /triage. The state
# engine independently checks that every named ID is open and unique.
PROPOSED_RESOLVE_IDS=()
PROPOSED_ADJUDICATIONS=()
PHASE_ARGS=()
PHASE_DECISION=""
# The domain's adjudication line, when the domain declares a channel (§13.3).
# Its keyword is the flag without the leading dashes, so the two spellings
# cannot drift apart; the id prefix and the verdict vocabulary come from the
# same declaration. Where no channel exists the keyword stays empty and the
# line form does not exist.
load_domain_spec
ADJUDICATION_KEYWORD="${ADJUDICATION_FLAG#--}"
ALLOWED_DECISION_FORMS="resolve B-... | resolve R-...${ADJUDICATION_KEYWORD:+ | ${ADJUDICATION_KEYWORD} ${ADJUDICATION_ARG_FORM}} | approve-should | close-at-must"
if [[ -s "${DECISIONS_FILE}" ]]; then
  while IFS= read -r RAW_DECISION || [[ -n "${RAW_DECISION}" ]]; do
    DECISION="$(trim_whitespace "$(sanitize_note "${RAW_DECISION}")")"
    [[ -n "${DECISION}" ]] || continue
    # Matched before the case for the same reason as in resume.sh: a pattern
    # built from an empty variable would swallow unrelated lines.
    if [[ -n "${ADJUDICATION_KEYWORD}" && "${DECISION}" == "${ADJUDICATION_KEYWORD} "* ]]; then
      DECISION_SPEC="${DECISION#"${ADJUDICATION_KEYWORD}" }"
      ADJUDICATION_ID="${DECISION_SPEC%%=*}"
      ADJUDICATION_VERDICT="${DECISION_SPEC#*=}"
      if [[ "${DECISION_SPEC}" != *=* ]] ||
        ! valid_item_id "${ADJUDICATION_ID}" "${ADJUDICATION_ID_PREFIX}"; then
        err "Invalid triage ${ADJUDICATION_KEYWORD} line: ${DECISION}"
        err "Allowed form: ${ADJUDICATION_KEYWORD} ${ADJUDICATION_ARG_FORM}"
        exit 2
      fi
      ADJUDICATION_VERDICT_OK=0
      for ALLOWED_VERDICT in ${ADJUDICATION_VERDICTS[@]+"${ADJUDICATION_VERDICTS[@]}"}; do
        [[ "${ADJUDICATION_VERDICT}" == "${ALLOWED_VERDICT}" ]] && ADJUDICATION_VERDICT_OK=1
      done
      if ((ADJUDICATION_VERDICT_OK == 0)); then
        err "Invalid ${ADJUDICATION_KEYWORD} verdict: ${ADJUDICATION_VERDICT} (allowed: ${ADJUDICATION_VERDICTS[*]+${ADJUDICATION_VERDICTS[*]}})"
        exit 2
      fi
      PROPOSED_ADJUDICATIONS+=("${DECISION_SPEC}")
      continue
    fi
    case "${DECISION}" in
      resolve\ *)
        DECISION_ID="${DECISION#resolve }"
        if ! valid_item_id "${DECISION_ID}" B R; then
          err "Invalid triage decision ID: ${DECISION_ID}"
          err "The handoff was not executed; fix ${DECISIONS_FILE} or run just resume explicitly."
          exit 2
        fi
        PROPOSED_RESOLVE_IDS+=("${DECISION_ID}")
        ;;
      approve-should | close-at-must)
        if [[ -n "${PHASE_DECISION}" ]]; then
          err "The triage handoff contains multiple phase decisions (${PHASE_DECISION}, ${DECISION})."
          exit 2
        fi
        PHASE_DECISION="${DECISION}"
        PHASE_ARGS+=(--"${DECISION}")
        ;;
      *)
        err "Invalid triage decision line: ${DECISION}"
        err "Allowed forms: ${ALLOWED_DECISION_FORMS}"
        exit 2
        ;;
    esac
  done <"${DECISIONS_FILE}"
fi

# Keep only what resume can actually release (§13.6-5). The engine refuses the
# WHOLE handoff when a single named ID is not an open gate, and that refusal
# would land after the interactive session has already ended — so the check
# happens here, against the same should-stop payload the pre-flight evaluated,
# and the human sees exactly which IDs were dropped before confirming. Dropping
# only ever narrows the release; nothing is broadened.
TRIAGE_RESUME_ARGS=()
if ((${#PROPOSED_RESOLVE_IDS[@]} > 0)); then
  partition_gate_decisions "${STOP_JSON}" "${PROPOSED_RESOLVE_IDS[@]}"
  if ((${#SUPERVISE_AUTH_GATE_IDS[@]} > 0)); then
    warn "Open supervise authorization, so resume must not resolve it yet: ${SUPERVISE_AUTH_GATE_IDS[*]}"
    log "That gate authorizes a pending High-Risk supervise session (§12.1, §13.3-4''):"
    log "run the \`just supervise --todo ... --recommendation ...\` form shown by just status,"
    log "and resolve the ID only after the supervised diff is reviewed. To withdraw the"
    log "approval instead, run just resume --retract-approval <ID> --note \"...\" yourself."
    log "Those IDs are dropped from the handoff (narrowing only, §13.6-5)."
  fi
  if ((${#UNRESOLVABLE_GATE_IDS[@]} > 0)); then
    warn "Not an open gate, so resume cannot release it: ${UNRESOLVABLE_GATE_IDS[*]}"
    log "resume releases only open gate items — proposed human-gated Recommendations"
    log "and active essence_blocking Blockers. A Non-blocking Recommendation is not one:"
    log "its conclusion rides in the note and the loop resolves it next cycle (§21.4)."
    log "Those IDs are dropped from the handoff. If one of them WAS a gate you meant to"
    log "release (a typo, or a gate that has since closed), answer N below and check just status."
  fi
  for RESOLVE_ID in ${RESOLVABLE_GATE_IDS[@]+"${RESOLVABLE_GATE_IDS[@]}"}; do
    TRIAGE_RESUME_ARGS+=(--resolve "${RESOLVE_ID}")
  done
fi
if ((${#PROPOSED_ADJUDICATIONS[@]} > 0)); then
  # Same narrowing, one face further out (§13.6-5): the domain publishes the
  # ids its channel can currently move on the should-stop payload, so this
  # consumes that list instead of re-deriving the rule from raw state.
  ADJUDICABLE_IDS="$(printf '%s' "${STOP_JSON}" |
    "${TOOL_BIN}" util json-get "${ADJUDICATION_STOP_PAYLOAD_KEY}" --join $'\n' --default "")"
  for ADJUDICATION_SPEC in ${PROPOSED_ADJUDICATIONS[@]+"${PROPOSED_ADJUDICATIONS[@]}"}; do
    ADJUDICATION_ID="${ADJUDICATION_SPEC%%=*}"
    if [[ -n "${ADJUDICABLE_IDS}" ]] && grep -qxF -- "${ADJUDICATION_ID}" <<<"${ADJUDICABLE_IDS}"; then
      TRIAGE_RESUME_ARGS+=("${ADJUDICATION_FLAG}" "${ADJUDICATION_SPEC}")
    else
      warn "Not one of the ${ADJUDICATION_TARGET_NOUN}, so resume cannot adjudicate it: ${ADJUDICATION_ID}"
      log "${ADJUDICATION_FLAG} targets only the ${ADJUDICATION_TARGET_NOUN} listed in the"
      log "should-stop payload; that line is dropped from the handoff (narrowing only, §13.6-5)."
    fi
  done
fi
TRIAGE_RESUME_ARGS+=(${PHASE_ARGS[@]+"${PHASE_ARGS[@]}"})
# §13.3-4''': an empty decision list must reach resume as an explicit
# --steer-only. With any forcing gate open, the engine refuses a bare
# note-only resume (`open gates require explicit --resolve <ID>`), and here
# that refusal would surface only after the interactive session has ended
# (the 2026-08-10 failure: defer-every-gate steering under an open R gate).
finalize_triage_resume_args
log "The triage session proposed this resume intent note (§13.3):"
printf '  ----------------------------------------\n'
printf '%s\n' "${NOTE}" | sed 's/^/  /'
printf '  ----------------------------------------\n'
if ((TRIAGE_STEER_ONLY)); then
  log "No item/phase decision remains (valid for a file-fact stop or steering; also the"
  log "case when every proposed ID was dropped above). Resume runs with --steer-only:"
  log "the note records your intervention and EVERY open gate stays open for its own"
  log "explicit decision (§13.3-4''')."
else
  log "It also proposed these exact gate decisions:"
  printf '  %q' "${TRIAGE_RESUME_ARGS[@]}"
  printf '\n'
fi
log "Finish any manual steps it listed FIRST (e.g. editing ESSENCE.md) — resume records"
log "your intervention, releases the latched gates, and creates the review checkpoint."
ANSWER=""
read -e -r -p "[${TOOL}] Run \`just resume\` with this note now? [y/N] " ANSWER || ANSWER=""
case "${ANSWER}" in
  y | Y | yes | YES)
    # finalize_triage_resume_args guarantees a non-empty list (an empty
    # decision handoff became --steer-only above), but the `[@]+` guard stays:
    # on bash 3.2 (macOS) `set -u` aborts a bare "${ARR[@]}" on an EMPTY
    # array, and a regression here would kill the handoff at the worst
    # moment — after the interactive session has already ended.
    if bash "${CONTROL_ROOT}/scripts/resume.sh" --project "${PROJECT_ARG}" \
      --note "${NOTE}" ${TRIAGE_RESUME_ARGS[@]+"${TRIAGE_RESUME_ARGS[@]}"}; then
      rm -f "${NOTE_FILE}" "${DECISIONS_FILE}"
      log "Triage complete. Run \`just loop\` yourself to continue — triage never starts the loop (§13.6-6)."
    else
      RESUME_RC=$?
      err "resume did not complete (exit ${RESUME_RC}); the note is kept at ${NOTE_FILE}."
      err "Address the refusal above, then run just resume with explicit --resolve / phase flags (META.md §13.3)."
      exit "${RESUME_RC}"
    fi
    ;;
  *)
    log "Not resuming. When ready, run just resume with the reviewed note and exact decision flags, then just loop."
    ;;
esac
