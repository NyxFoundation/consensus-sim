#!/usr/bin/env bash
# essence.sh — human-only interactive authoring/updating of
# ESSENCE.md (Essence interview, META.md §2.1.4).
#
# ESSENCE.md is the single human requirement-input file (I-004), but a GOOD
# Essence is hard to write from scratch: the terrain knowledge lives in the
# human's head while the format discipline (observable success conditions,
# non-contradictory musts, won't fences — §2.1.1..§2.1.3) lives in the framework.
# This command launches an INTERACTIVE Claude session at CONTROL_ROOT (slash
# command /essence) in one of two modes (--mode, gated below):
#   - new (just new-essence): from-scratch authoring — interrogates the human,
#     critical-first, refines every answer into verifiable wording, and drafts
#     a fully format-compliant Essence. Refuses when a real (non-placeholder)
#     Essence already exists: revising canon must go through update mode.
#   - update (just update-essence): mid-course revision of an EXISTING real
#     Essence — the session reads the current text, asks the human's CHANGE
#     INTENT first, interviews only what that intent touches, and carries the
#     rest forward verbatim. Refuses when no real Essence exists yet.
#
# The session is advisory and read-only (I-027): Edit/NotebookEdit tools are
# disabled, the Write tool is hook-confined to the gitignored handoff dir
# .agent/tmp/essence/ (the only path the session writes — §2.1.4-2), and
# permission mode is the CLI's ask-before-edits mode (no auto-accept). It
# cannot write ESSENCE.md itself (the control-plane hooks deny that in every
# spelling, I-004) and it never binds, resumes, or starts the loop.
#
# Because the read-only session cannot parse binary workbooks (Read handles
# text/images; Bash is confined to the handoff heredoc), this wrapper
# pre-dumps every Excel asset under PROJECT_ROOT/essences/ into the handoff
# dir as a text cell listing (xlsx/<relpath>.txt, via xlsx-dump.py)
# before launching the session — trusted human-side preprocessing that adds
# no session write surface (§2.1.4-2). Best-effort: a failed dump warns and
# the interview proceeds without it.
#
# Handoff: the session ends by writing the complete draft to
# .agent/tmp/essence/ESSENCE.draft.md. This wrapper validates the draft
# against the placeholder gate (§13.1-8), shows the full text (plus the diff
# when a real Essence would be replaced), and installs it to
# PROJECT_ROOT/ESSENCE.md ONLY after an explicit y on the terminal. The
# human reviews and signs the full text, so the installed content stays
# human-authored: every statement in it originates from the human's answers
# and the confirmation keystroke is the human's writing act (§2.1.4).
#
# Works both before and after binding:
#   - before `just init` (the standard new-project flow, §26.1): bootstrap
#     then anchors the installed hash as the human-reviewed baseline;
#   - after binding (refinement): the human records the replacement with
#     `just resume`, else the next loop stops as essence_unreviewed_change
#     (§13.1-10). The wrapper detects which case applies and prints the
#     matching next step.
#
# Human-only: refuses without a terminal, and the pre-tool guard hook denies this
# script / `just new-essence` / `just update-essence` to agents (I-011, §18.2)
# — an agent can neither spawn an interview nor author the Essence through it.
#
# Outside the single-flight boundary (I-018): the session is read-only and
# takes no lock; the install is the same class of act as the human editing
# ESSENCE.md in $EDITOR, so a mid-cycle install is caught by the existing
# I-020 / essence_unreviewed_change fences.
#
# Usage: cd ./.<tool> && bash scripts/essence.sh --project ../PROJECT_TITLE --mode new|update

# shellcheck source=./_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

assert_control_root
resolve_project "$@"

# --mode new|update (default new). Parsed the same way resolve_project reads
# --project.
MODE="new"
_MODE_ARGS=("$@")
for ((i = 0; i < ${#_MODE_ARGS[@]}; i++)); do
  if [[ "${_MODE_ARGS[$i]}" == "--mode" ]]; then
    MODE="${_MODE_ARGS[$((i + 1))]:-}"
  fi
done
case "${MODE}" in
  new | update) ;;
  *)
    err "invalid --mode '${MODE}' (expected: new | update)."
    exit 2
    ;;
esac
RECIPE="new-essence"
[[ "${MODE}" == "update" ]] && RECIPE="update-essence"

ESSENCE_TMP_DIR="${CONTROL_ROOT}/.agent/tmp/essence"
DRAFT_FILE="${ESSENCE_TMP_DIR}/ESSENCE.draft.md"
ESSENCE_FILE="${PROJECT_ROOT}/ESSENCE.md"
ESSENCE_COMMAND_FILE="${CONTROL_ROOT}/.claude/commands/essence.md"

# Mode gate: "real" means non-placeholder, non-empty — the same predicate the
# placeholder stop gate uses (§13.1-8) and REPLACING_REAL reuses below.
essence_is_real() {
  [[ -f "${ESSENCE_FILE}" ]] &&
    ! essence_has_placeholder_marker "${ESSENCE_FILE}" &&
    [[ -n "$(tr -d '[:space:]' <"${ESSENCE_FILE}" 2>/dev/null)" ]]
}
if [[ "${MODE}" == "new" ]] && essence_is_real; then
  err "${PROJECT_TITLE}/ESSENCE.md already contains a real (non-placeholder) Essence."
  err "Refusing a from-scratch interview over existing canon — run \`just update-essence\` instead:"
  err "it starts from your change intent and revises the current text (META.md §2.1.4)."
  exit 2
fi
if [[ "${MODE}" == "update" ]] && ! essence_is_real; then
  err "no real ESSENCE.md to update at ${ESSENCE_FILE} (missing, empty, or still the placeholder)."
  err "Run \`just new-essence\` first — update-essence revises an existing Essence (META.md §2.1.4)."
  exit 2
fi

# Interactive and human-only by definition: the session interviews the human,
# and the handoff below can end in installing ESSENCE.md. Without a terminal
# there is no human to interview or to confirm (agents are additionally
# denied by the pre-tool guard hook before ever reaching this check).
if [[ ! -t 0 || ! -t 1 ]]; then
  err "essence is an interactive, human-only interview; run it from a terminal (META.md §2.1.4)."
  exit 2
fi

command -v claude >/dev/null 2>&1 || {
  err "claude CLI not found; cannot run the essence interview."
  exit 2
}
resolve_interactive_permission_mode
resolve_session_model
build_sanitized_claude_env
[[ -f "${ESSENCE_COMMAND_FILE}" ]] ||
  {
    err "missing ${ESSENCE_COMMAND_FILE}; the /essence slash command is not installed."
    exit 2
  }
# Trust must exist BEFORE the session: without it Claude Code ignores the
# control-plane permissions/hooks, and the read-only boundary of this session
# (I-027, and the ESSENCE.md deny inside it) would not be enforced. The hint
# carries the explicit project path so it works on an unbound plane too.
require_claude_launch_trust "Over-Project Agent" "${CONTROL_ROOT}" \
  "cd ${CONTROL_ROOT} && just trust ${PROJECT_ARG}"

# Fresh handoff dir BEFORE the session: only a draft written by THIS session
# may reach the confirmation below — a stale or foreign draft must never be
# offered for install (same rule as the triage handoff, §13.6-5).
rm -rf "${ESSENCE_TMP_DIR}"
mkdir -p "${ESSENCE_TMP_DIR}"

# Excel assets under essences/ are unreadable INSIDE the session: the Read
# tool cannot parse binary workbooks and Bash is confined to the handoff
# heredoc (G-T2), so without help the interview must ask the human for cell
# coordinates it should be able to see. Pre-dump every workbook as a text
# cell listing into the handoff dir (§2.1.4-2). This is trusted human-side
# preprocessing: it runs before the session, changes no permission surface
# (I-027), leaves the human-only originals untouched (I-004), and the dumps
# die with the handoff dir. Best-effort — a failed dump only warns, and the
# interview falls back to asking the human as before. `~$*` are Excel lock
# files, not assets; -maxdepth 3 mirrors the essences/ depth cap (§2.1.5).
ESSENCES_DIR="${PROJECT_ROOT}/essences"
if [[ -d "${ESSENCES_DIR}" ]]; then
  while IFS= read -r -d '' WORKBOOK; do
    WORKBOOK_REL="${WORKBOOK#"${ESSENCES_DIR}/"}"
    DUMP_FILE="${ESSENCE_TMP_DIR}/xlsx/${WORKBOOK_REL}.txt"
    if ! command -v python3 >/dev/null 2>&1; then
      warn "python3 not found; essences/${WORKBOOK_REL} stays unreadable to the session (it will ask you instead)."
      continue
    fi
    mkdir -p "$(dirname "${DUMP_FILE}")"
    if python3 "${CONTROL_ROOT}/scripts/xlsx-dump.py" \
      "${WORKBOOK}" "${DUMP_FILE}" "essences/${WORKBOOK_REL}" 2>/dev/null; then
      log "essences asset dumped for the session: essences/${WORKBOOK_REL} -> .agent/tmp/essence/xlsx/${WORKBOOK_REL}.txt"
    else
      rm -f "${DUMP_FILE}"
      warn "could not dump essences/${WORKBOOK_REL} as text (unreadable workbook?); the session will ask you instead."
    fi
  done < <(find "${ESSENCES_DIR}" -maxdepth 3 -type f \
    \( -name '*.xlsx' -o -name '*.xlsm' \) ! -name '~$*' -print0 2>/dev/null)
fi

# Before init, the project-agnostic settings cannot name PROJECT_ROOT and the
# session receives it through --add-dir. Add the target-bound read-only layer
# on every interview so the unbound path is no weaker than the bound one.
# The new-mode variant swaps the blanket project Edit deny for an ESSENCE.md
# ask entry (I-027 second path): a deny would outrank the hook's ask and close
# the human-approved direct-install fallback. Every other project write stays
# hook-denied, and Bash stays behind the sandbox denyWrite (G-T2).
if [[ "${MODE}" == "new" ]]; then
  build_read_only_session_settings "${PROJECT_ROOT}" "${ESSENCE_TMP_DIR}" essence-new
else
  build_read_only_session_settings "${PROJECT_ROOT}" "${ESSENCE_TMP_DIR}"
fi

if [[ "${MODE}" == "update" ]]; then
  log "Launching the interactive Essence UPDATE interview (read-only; writes confined to the handoff dir — I-027)."
  log "It starts by asking your change intent, then revises the existing ESSENCE.md around it."
else
  log "Launching the interactive Essence interview (read-only; writes confined to the handoff dir — I-027)."
fi
log "Answer its questions; end the session (/exit or Ctrl+D) once it reports the draft is written."
# The prompt comes FIRST so the variadic --disallowedTools list cannot swallow
# it. Write stays enabled — the pre-tool guard confines it to the handoff dir
# (allow inside, teaching deny outside; §2.1.4-2) so the session can hand off
# the draft without wrestling a heredoc. This only works because no settings
# deny covers .agent/tmp: a permissions deny always outranks a hook allow, and
# on CLI >=2.1.216 an Edit deny also reaches Bash write targets and the
# sandbox profile (§19.1-5, §28.5-3). --add-dir grants read access to the
# target BEFORE binding (the unbound settings.json reaches only CONTROL_ROOT);
# in update mode the hooks still deny every ESSENCE.md write, in new mode
# ESSENCE.md is an ask face (I-027 second path: a direct install needs the
# human's approval on the permission prompt), and the resolved interactive
# mode keeps every unmatched action behind an interactive ask.
CLAUDE_RC=0
"${SANITIZED_CLAUDE_ENV[@]}" CLAUDE_CODE_SKIP_PROMPT_HISTORY=1 "${TOOL_ENV}_SESSION_MODE=essence" "${TOOL_ENV}_SESSION_ESSENCE_MODE=${MODE}" "${TOOL_ENV}_SESSION_PROJECT_ROOT=${PROJECT_ROOT}" claude "/essence --project ${PROJECT_ARG} --mode ${MODE}" \
  "${SESSION_MODEL_ARGS[@]+"${SESSION_MODEL_ARGS[@]}"}" \
  --permission-mode "${INTERACTIVE_PERMISSION_MODE}" \
  --setting-sources project \
  --strict-mcp-config \
  --add-dir "${PROJECT_ROOT}" \
  --settings "${READ_ONLY_SESSION_SETTINGS}" \
  --disallowedTools Edit NotebookEdit || CLAUDE_RC=$?
((CLAUDE_RC == 0)) || warn "claude exited nonzero (${CLAUDE_RC}); reviewing any draft it left anyway."

if [[ ! -s "${DRAFT_FILE}" ]]; then
  log "No draft was handed off; nothing was changed."
  log "Re-run \`just ${RECIPE}\` to interview again, or write ${ESSENCE_FILE} yourself."
  exit 0
fi

# Same sanitization discipline as resume notes (§13.3): the draft goes to the
# human's terminal for the y/N confirmation and then becomes the requirement
# canon, so control characters (newline/tab excepted) must reach neither.
DRAFT="$(sanitize_note "$(cat "${DRAFT_FILE}")")"
if [[ -z "$(trim_whitespace "${DRAFT}")" ]]; then
  log "The handed-off draft is empty after sanitizing; nothing was changed."
  exit 0
fi

# Installing a draft the placeholder gate (§13.1-8) would reject is pointless:
# doctor/loop would immediately stop on it as an unwritten Essence. The
# session's protocol requires a complete draft, so this is a visible failure.
if essence_has_placeholder_marker <<<"${DRAFT}"; then
  err "the draft still contains a placeholder marker (guide block or an unfilled FILL section marker)."
  err "Refusing to install it — the loop would immediately stop on essence_placeholder (§13.1-8)."
  err "Draft kept at ${DRAFT_FILE}; re-run \`just ${RECIPE}\` to finish the interview."
  exit 2
fi

# A "real" existing Essence (non-placeholder, non-empty) deserves a louder
# confirmation than replacing the seeded skeleton: show the diff and say
# REPLACE explicitly. Re-evaluated here (not reused from the mode gate):
# the file may have changed while the session ran. In update mode this is
# normally 1 by construction; in new mode 0 unless a racing write appeared.
REPLACING_REAL=0
essence_is_real && REPLACING_REAL=1
if [[ -f "${ESSENCE_FILE}" ]] && printf '%s\n' "${DRAFT}" | cmp -s - "${ESSENCE_FILE}"; then
  log "The draft is identical to the current ESSENCE.md; nothing to install."
  # §2.1.4-4: the no-op cleans the whole handoff (the xlsx dumps included),
  # not just the draft file.
  rm -rf "${ESSENCE_TMP_DIR}"
  exit 0
fi

log "The interview produced this ESSENCE.md draft (META.md §2.1.4):"
printf '  ----------------------------------------\n'
printf '%s\n' "${DRAFT}" | sed 's/^/  /'
printf '  ----------------------------------------\n'
if ((REPLACING_REAL)); then
  warn "${PROJECT_TITLE}/ESSENCE.md already contains a real (non-placeholder) Essence; installing REPLACES it."
  log "Diff against the current ESSENCE.md:"
  diff -u "${ESSENCE_FILE}" <(printf '%s\n' "${DRAFT}") | sed 's/^/  /' || true
fi
# Installing while a loop runs is the same as a mid-cycle $EDITOR edit: safe
# by design (I-020 keeps it out of the cycle commit; §13.1-10 stops the loop
# for the attestation), but worth saying out loud before the human confirms.
LOCK_PID="$(loop_lock_owner_pid)"
if [[ -n "${LOCK_PID}" ]] && lock_pid_is_alive "${LOCK_PID}"; then
  warn "a loop/resume is running right now (pid ${LOCK_PID}); installing mid-cycle stops the loop as an unreviewed Essence change until you \`just resume\` (I-020, §13.1-10)."
fi

ANSWER=""
read -e -r -p "[${TOOL}] Install this draft as ${PROJECT_TITLE}/ESSENCE.md now? [y/N] " ANSWER || ANSWER=""
case "${ANSWER}" in
  y | Y | yes | YES)
    # Atomic like every canonical write (§13.5): a crash mid-install must not
    # leave a truncated ESSENCE.md that the placeholder gate reads as "real".
    # The *.essence.*.tmp debris is excluded from checkpoints by _lib.sh.
    INSTALL_TMP="${ESSENCE_FILE}.essence.$$.tmp"
    printf '%s\n' "${DRAFT}" >"${INSTALL_TMP}"
    mv "${INSTALL_TMP}" "${ESSENCE_FILE}"
    rm -f "${DRAFT_FILE}"
    log "Installed: ${ESSENCE_FILE}"
    if [[ -f "${PROJECT_STATE_ROOT}/state/project.json" ]]; then
      log "This project is already bootstrapped: record the new Essence as a human intervention FIRST — without the attestation the next loop stops as essence_unreviewed_change (§13.1-10)."
      # The install just changed the state this guidance is about, so derive
      # the resume form from it (resume_guidance, §13.4-2) instead of spelling
      # one: the fixed `just resume --note` line this block used to print is
      # refused whenever another gate is open (§13.3-4') — precisely the
      # update-essence-while-gated case (2026-08-04).
      GUIDANCE_RC=0
      GUIDANCE="$(resume_guidance)" || GUIDANCE_RC=$?
      case "${GUIDANCE_RC}" in
        0) log "NEXT: ${GUIDANCE}" ;;
        1) log "NEXT: run \`just resume --note \"...\"\`, then \`just loop\`." ;;
        *) warn "${TOOL} state should-stop failed; run \`just status\` for the exact \`just resume …\` form (I-021)." ;;
      esac
    else
      log "Next: bind + bootstrap — just init ${PROJECT_ARG}"
      log "(bootstrap keeps this ESSENCE.md and anchors its hash as the human-reviewed baseline, §13.1-10)."
    fi
    ;;
  *)
    log "Not installing. The draft is kept at ${DRAFT_FILE} (a new \`just ${RECIPE}\` run deletes it)."
    log "After your own review/edits you can install it yourself:  cp ${DRAFT_FILE} ${ESSENCE_FILE}"
    ;;
esac
