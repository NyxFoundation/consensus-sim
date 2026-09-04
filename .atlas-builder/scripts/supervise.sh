#!/usr/bin/env bash
# supervise.sh — human-supervised session for an approved High-Risk
# change. Autonomous cycles are headless and cannot cross an ask gate; this
# interactive, single-flight session is the only Agent-assisted implementation
# path for such a change. The human reviews every prompt and checkpoints the
# resulting dirty worktree with `just resume`.

# shellcheck source=./_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

assert_control_root

# Bind the interactive approval to one canonical Todo (and, when supplied,
# the exact Recommendation that authorized it). A generic supervised session
# is too broad: permission prompts alone do not identify the approved scope.
PROJECT_OPT=""
TODO_ID=""
RECOMMENDATION_ID=""
args=("$@")
i=0
while ((i < ${#args[@]})); do
  case "${args[$i]}" in
    --project | --todo | --recommendation)
      FLAG="${args[$i]}"
      ((i + 1 < ${#args[@]})) || {
        err "${FLAG} requires a value."
        exit 2
      }
      VALUE="${args[$((i + 1))]}"
      case "${FLAG}" in
        --project) PROJECT_OPT="${VALUE}" ;;
        --todo) TODO_ID="${VALUE}" ;;
        --recommendation) RECOMMENDATION_ID="${VALUE}" ;;
      esac
      i=$((i + 2))
      ;;
    *)
      err "unknown argument: ${args[$i]}"
      err "Usage: just supervise --todo T-... [--recommendation R-...]"
      exit 2
      ;;
  esac
done

valid_item_id "${TODO_ID}" T || {
  err "supervise requires one canonical Todo ID: --todo T-..."
  exit 2
}
if [[ -n "${RECOMMENDATION_ID}" ]] && ! valid_item_id "${RECOMMENDATION_ID}" R; then
  err "--recommendation must name a canonical Recommendation ID (R-...)."
  exit 2
fi

resolve_project --project "${PROJECT_OPT}"
resolve_git_context

if [[ ! -t 0 || ! -t 1 ]]; then
  err "supervise is an interactive, human-only session; run it from a terminal."
  exit 2
fi
command -v claude >/dev/null 2>&1 || {
  err "claude CLI not found; cannot start a supervised session."
  exit 2
}
resolve_interactive_permission_mode
resolve_session_model

require_claude_launch_trust "Over-Project Agent" "${CONTROL_ROOT}"
build_sanitized_claude_env
acquire_loop_lock
# §13.5 / I-018: without a trap, an INT/TERM/HUP to this wrapper takes its default
# action — the shell dies immediately, the EXIT trap frees the single-flight lock,
# but the interactive `claude` child (a foreground descendant, not sent the signal
# on a bare `kill`) survives and keeps editing PROJECT_ROOT and canonical state.
# A concurrent `just loop` / `just resume --force` would then race those writes.
# Trapping defers the signal until the foreground `claude` returns, so the lock is
# held for the whole session and released only after the child exits — the same
# discipline resume.sh / init.sh / bootstrap.sh use.
# (The loop's group-kill form is for its HEADLESS `-p` child; backgrounding an
# INTERACTIVE claude would break its terminal I/O, so defer-until-return is the
# correct shape here.)
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
# §16.1: the bound overlay (path rules + sandbox) is generated once per
# invocation, after the lock — with the slot held, no framework transition
# can rewrite the base (and its recorded profile) mid-invocation (I-018). An
# unbound or pre-split base fails closed here (exit 2) before Claude is started.
build_bound_session_settings
assert_clean_worktree_for_cycle

# Refuse before launching Claude unless canonical state itself authorizes the
# exact Todo and scope. The prompt repeats this binding, but is not the source
# of authority.
PREFLIGHT_ARGS=(supervise-check --project "${PROJECT_ARG}" --todo "${TODO_ID}")
[[ -n "${RECOMMENDATION_ID}" ]] &&
  PREFLIGHT_ARGS+=(--recommendation "${RECOMMENDATION_ID}")
PREFLIGHT_JSON=""
PREFLIGHT_RC=0
PREFLIGHT_JSON="$(state "${PREFLIGHT_ARGS[@]}")" || PREFLIGHT_RC=$?
if ((PREFLIGHT_RC != 0)); then
  [[ -n "${PREFLIGHT_JSON}" ]] && printf '%s\n' "${PREFLIGHT_JSON}"
  err "Supervise preflight refused the requested Todo/Recommendation; Claude was not started."
  exit 2
fi
require_tool_bin
APPROVED_TARGET="$("${TOOL_BIN}" util json-get target <<<"${PREFLIGHT_JSON}")"

log "Starting a human-supervised High-Risk session for Todo ${TODO_ID}."
if [[ -n "${RECOMMENDATION_ID}" ]]; then
  log "Approval is additionally bound to Recommendation ${RECOMMENDATION_ID}."
fi
log "Canonical approved target: ${APPROVED_TARGET}"
log "Approve only that reviewed scope; end the session when the bounded change is verified."
SUPERVISE_PROMPT="Canonical preflight approved Todo ${TODO_ID} with exact target ${APPROVED_TARGET}. Re-read that Todo and implement only its requested change inside this target; refuse any broader path or another Todo."
if [[ -n "${RECOMMENDATION_ID}" ]]; then
  SUPERVISE_PROMPT+=" Canonical preflight also verified open human approval Recommendation ${RECOMMENDATION_ID}, its source linkage to ${TODO_ID}, and exact target equality."
fi
SUPERVISE_PROMPT+=" Keep it separate from normal work, record the required before/after hashes and evidence, and stop for human review without running resume or committing."
CLAUDE_RC=0
"${SANITIZED_CLAUDE_ENV[@]}" CLAUDE_CODE_SKIP_PROMPT_HISTORY=1 "${LOCK_TOKEN_ENV}=${LOOP_LOCK_TOKEN}" claude \
  "${SUPERVISE_PROMPT}" \
  "${SESSION_MODEL_ARGS[@]+"${SESSION_MODEL_ARGS[@]}"}" \
  --permission-mode "${INTERACTIVE_PERMISSION_MODE}" \
  --setting-sources project \
  --strict-mcp-config \
  "${SESSION_SETTINGS_ARGS[@]+"${SESSION_SETTINGS_ARGS[@]}"}" || CLAUDE_RC=$?

((CLAUDE_RC == 0)) || warn "claude exited nonzero (${CLAUDE_RC}); review any partial diff before proceeding."
if [[ -n "$(git -C "${GIT_ROOT}" status --porcelain --untracked-files=all)" ]]; then
  log "Supervised changes for ${TODO_ID} are uncommitted. Review the full diff."
  # §13.4-2: the resume form is derived from the single should-stop message,
  # never spelled as fixed text — a fixed `--resolve ${RECOMMENDATION_ID}` is
  # exactly the form the engine refuses while the Todo is still unfinished
  # (§13.3-4'': the authorization must stay open until the diff review), so a
  # hardcoded spelling here would be wrong precisely when the session ended
  # without finishing the Todo.
  GUIDANCE_RC=0
  GUIDANCE="$(resume_guidance)" || GUIDANCE_RC=$?
  if ((GUIDANCE_RC == 0)) && [[ -n "${GUIDANCE}" ]]; then
    log "After the review, follow the current gate guidance (§13.4-2):"
    printf '%s
' "${GUIDANCE}" | sed 's/^/  /'
  elif ((GUIDANCE_RC == 1)); then
    log "No stop gate is latched; record the review with: just resume --note \"approved High-Risk Todo ${TODO_ID} reviewed\""
  else
    warn "could not derive the resume guidance (should-stop hard error, I-021); run \`just status\`."
  fi
else
  log "The supervised session left no worktree changes."
fi
exit "${CLAUDE_RC}"
