#!/usr/bin/env bash
# resume.sh — the human-only intervention transition (META.md §13.3).
#
# The single re-entry point after the human reviews or fixes human-owned
# inputs (typically ESSENCE.md), whether or not the loop is stopped:
#
#   - gate release: the loop latched a stop (Essence block, human-review
#     recommendation, loop-raised gate, idle-cycle safety net). Resume
#     resolves the latches.
#   - steering: nothing is latched, but the human edited inputs mid-project.
#     Resume records the intervention so the next cycle can trust the new
#     ESSENCE.md hash as human-reviewed (§13.1-5) instead of suspecting an
#     agent edit.
#   - crash recovery: runs.jsonl shows an unfinished run and the loop is not
#     running. `--force` closes that run (status aborted_by_resume) and the
#     checkpoint is labeled `crash recovery`, because it contains leftovers
#     of the aborted agent cycle (§13.5). Never use --force under a running
#     loop.
#
# Every shape ends with validate -> one review checkpoint
# commit, so the next `just loop` starts from a clean worktree (I-014). When
# nothing is latched and nothing changed, resume is a no-op and commits
# nothing.
#
# Resume grants re-evaluation, not resolution: the next cycle re-reads
# ESSENCE.md and re-raises any stop condition that still holds.
#
# Human-only: the pre-tool guard hook denies this script and `<tool> state resume` to
# agents so the loop can never release its own stop conditions (I-011).
#
# Usage: cd ./.<tool> && bash scripts/resume.sh --project ../PROJECT_TITLE \
#          [--note "..."] [--resolve R-001]... [--retract-approval R-001]... \
#          [<domain adjudication flag> <id>=<verdict>]... \
#          [--approve-should | --close-at-must] [--steer-only] [--force]
#
# The adjudication flag exists only where the domain pack declares one (§13.3);
# its spelling and vocabulary come from `util domain-spec`, never from here.
#
# `--steer-only` (META.md §13.3-4'''): record the human's edits to human-owned
# inputs (typically ESSENCE.md) WITHOUT touching any gate. Open gates otherwise
# force an explicit --resolve, which makes the ordinary steering checkpoint
# inexpressible exactly where §19.3 prescribes it — after a must boundary, the
# human raises the requirements by editing ESSENCE.md while the boundary's own
# phase gate is still open. This flag states that intent instead of loosening
# the rule, so it cannot be combined with --resolve / --retract-approval /
# --approve-should / --close-at-must.
#
# `--retract-approval` (META.md §13.3-4''): a supervise authorizing gate — an
# open Recommendation that currently makes `just supervise --todo T-...
# --recommendation R-...` pass its preflight — cannot be closed with --resolve
# while its High-Risk Todo is unfinished (closing it would leave that supervise
# permanently refused). Resolve it after the supervised diff is reviewed, or
# withdraw the approval deliberately with this explicit flag.
#
# The intent note is mandatory (§13.3): pass it with --note, or an interactive
# prompt asks for it before anything is locked or mutated. A non-interactive
# invocation without --note is refused.

# shellcheck source=./_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

assert_control_root

# Consume flags strictly as flag/value pairs, BEFORE resolve_project scans
# anything: a flag's value must never be re-scanned as a flag (`--note
# "--force"` must not act as a real --force — an unintended --force closes an
# in-flight run as crash recovery, §13.5). Unknown arguments are refused for
# the same reason: a silently dropped flag would run a different transition
# than the human asked for.
PROJECT_OPT=""
NOTE=""
FORCE=0
APPROVE_SHOULD=0
CLOSE_AT_MUST=0
STEER_ONLY=0
RESOLVE_IDS=()
RETRACT_IDS=()
# §13.3: the domain's own adjudication flag, when it declares one. The spelling,
# the argument form and the accepted verdicts are the domain pack's (read via
# util domain-spec); this wrapper only enforces the strict flag/value shape and
# forwards. A domain without a channel leaves ADJUDICATION_FLAG empty and the
# flag simply does not exist — there is nothing to spell and nothing to accept.
load_domain_spec
ADJUDICATIONS=()
args=("$@")
i=0
while ((i < ${#args[@]})); do
  # Matched before the case: a `case` pattern built from a variable would match
  # the EMPTY argument when the domain declares no channel.
  if [[ -n "${ADJUDICATION_FLAG}" && "${args[$i]}" == "${ADJUDICATION_FLAG}" ]]; then
    ((i + 1 < ${#args[@]})) || {
      err "${ADJUDICATION_FLAG} requires ${ADJUDICATION_ARG_FORM} (META.md §13.3)."
      exit 2
    }
    [[ -n "${args[$((i + 1))]}" && "${args[$((i + 1))]}" != --* && "${args[$((i + 1))]}" == *=* ]] || {
      err "${ADJUDICATION_FLAG} requires ${ADJUDICATION_ARG_FORM} (the vocabulary is checked by the engine)."
      exit 2
    }
    ADJUDICATIONS+=("${args[$((i + 1))]}")
    i=$((i + 2))
    continue
  fi
  case "${args[$i]}" in
    --project)
      ((i + 1 < ${#args[@]})) || {
        err "--project requires a value."
        exit 2
      }
      PROJECT_OPT="${args[$((i + 1))]}"
      i=$((i + 2))
      ;;
    --note)
      ((i + 1 < ${#args[@]})) || {
        err "--note requires a value (META.md §13.3)."
        exit 2
      }
      NOTE="${args[$((i + 1))]}"
      case "${NOTE}" in
        --note | --force | --project | --resolve | --retract-approval | --approve-should | --close-at-must | --steer-only)
          err "the --note value looks like a flag (${NOTE}); quote a real intent note (META.md §13.3)."
          exit 2
          ;;
        *)
          if [[ -n "${ADJUDICATION_FLAG}" && "${NOTE}" == "${ADJUDICATION_FLAG}" ]]; then
            err "the --note value looks like a flag (${NOTE}); quote a real intent note (META.md §13.3)."
            exit 2
          fi
          ;;
      esac
      i=$((i + 2))
      ;;
    --resolve)
      ((i + 1 < ${#args[@]})) || {
        err "--resolve requires a Recommendation/Blocker ID."
        exit 2
      }
      [[ -n "${args[$((i + 1))]}" && "${args[$((i + 1))]}" != --* ]] || {
        err "--resolve requires a non-flag Recommendation/Blocker ID."
        exit 2
      }
      RESOLVE_IDS+=("${args[$((i + 1))]}")
      i=$((i + 2))
      ;;
    --retract-approval)
      ((i + 1 < ${#args[@]})) || {
        err "--retract-approval requires a Recommendation ID (META.md §13.3-4'')."
        exit 2
      }
      [[ -n "${args[$((i + 1))]}" && "${args[$((i + 1))]}" != --* ]] || {
        err "--retract-approval requires a non-flag Recommendation ID."
        exit 2
      }
      RETRACT_IDS+=("${args[$((i + 1))]}")
      i=$((i + 2))
      ;;
    --approve-should)
      APPROVE_SHOULD=1
      i=$((i + 1))
      ;;
    --close-at-must)
      CLOSE_AT_MUST=1
      i=$((i + 1))
      ;;
    --steer-only)
      STEER_ONLY=1
      i=$((i + 1))
      ;;
    --force)
      FORCE=1
      i=$((i + 1))
      ;;
    *)
      err "unknown argument: ${args[$i]}"
      err "Usage: bash scripts/resume.sh --project ../PROJECT_TITLE [--note \"...\"] [--resolve ID]... [--retract-approval ID]...${ADJUDICATION_FLAG:+ [${ADJUDICATION_FLAG} ${ADJUDICATION_ARG_FORM}]...} [--approve-should|--close-at-must] [--steer-only] [--force]"
      exit 2
      ;;
  esac
done

if [[ "${APPROVE_SHOULD}" -eq 1 && "${CLOSE_AT_MUST}" -eq 1 ]]; then
  err "--approve-should and --close-at-must are mutually exclusive."
  exit 2
fi

# §13.3-4''': the engine refuses this combination too (its `selectionError?` is
# the single decision point). Checking it here as well keeps the mixed intent
# from ever taking the I-018 lock or reaching a state read.
if [[ "${STEER_ONLY}" -eq 1 ]] &&
  { [[ "${#RESOLVE_IDS[@]}" -gt 0 ]] || [[ "${#RETRACT_IDS[@]}" -gt 0 ]] ||
    [[ "${#ADJUDICATIONS[@]}" -gt 0 ]] ||
    [[ "${APPROVE_SHOULD}" -eq 1 ]] || [[ "${CLOSE_AT_MUST}" -eq 1 ]]; }; then
  err "--steer-only records your input edits without touching any gate, so it"
  err "cannot be combined with --resolve / --retract-approval${ADJUDICATION_FLAG:+ / ${ADJUDICATION_FLAG}}"
  err "/ --approve-should / --close-at-must (META.md §13.3-4''')."
  exit 2
fi

resolve_project --project "${PROJECT_OPT}"
resolve_git_context

# §13.3: the intent note is mandatory; prompt for it BEFORE taking the
# single-flight lock. The prompt can wait on the human indefinitely, and an
# abandoned prompt must not pin the I-018 lock (a live holder pid is never
# reclaimed as stale). Everything the lock protects runs after it.
require_resume_note

acquire_loop_lock
# §13.5: untrapped INT/TERM would free the lock (EXIT trap) while a foreground
# child (<tool> state resume, git) is still mutating state. Trapping defers the
# signal until the child returns, so the transition never outlives its lock.
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
assert_resume_checkpoint_feasible

RESUME_ARGS=(resume --project "${PROJECT_ARG}")
[[ -n "${NOTE}" ]] && RESUME_ARGS+=(--note "${NOTE}")
# `[@]+` guard: on bash 3.2 (macOS) `set -u` aborts on a bare "${ARR[@]}" when
# ARR is EMPTY, and a resume with no --resolve is the ordinary steering /
# file-fact-stop invocation (§13.3) — unguarded, the most common resume dies
# here with `RESOLVE_IDS[@]: unbound variable`, after the lock is taken.
for RESOLVE_ID in ${RESOLVE_IDS[@]+"${RESOLVE_IDS[@]}"}; do
  RESUME_ARGS+=(--resolve "${RESOLVE_ID}")
done
for RETRACT_ID in ${RETRACT_IDS[@]+"${RETRACT_IDS[@]}"}; do
  RESUME_ARGS+=(--retract-approval "${RETRACT_ID}")
done
for ADJUDICATION in ${ADJUDICATIONS[@]+"${ADJUDICATIONS[@]}"}; do
  RESUME_ARGS+=("${ADJUDICATION_FLAG}" "${ADJUDICATION}")
done
[[ "${APPROVE_SHOULD}" -eq 1 ]] && RESUME_ARGS+=(--approve-should)
[[ "${CLOSE_AT_MUST}" -eq 1 ]] && RESUME_ARGS+=(--close-at-must)
[[ "${STEER_ONLY}" -eq 1 ]] && RESUME_ARGS+=(--steer-only)
[[ "${FORCE}" -eq 1 ]] && RESUME_ARGS+=(--force)

RESUME_JSON=""
RESUME_RC=0
RESUME_JSON="$(state "${RESUME_ARGS[@]}")" || RESUME_RC=$?
if ((RESUME_RC == 1)); then
  # Exit 1 is the refusal path: the state engine checked its preconditions and wrote
  # nothing (refuse_resume). Exit >= 2 is a crash and gives no such guarantee.
  [[ -n "${RESUME_JSON}" ]] && printf '%s\n' "${RESUME_JSON}"
  err "Resume refused (see output above); no state was changed."
  # Constructive refusal (§13.3): the engine's error says what was wrong with
  # THIS invocation; the form it accepts NOW is the should-stop message — the
  # single derivation point `just status` prints (§13.4-2). Without it the
  # human has to reverse-engineer the accepted flags from the refusal text
  # alone (the 2026-07-27 double refusal). A refusal with nothing latched
  # (rc 1) adds nothing the error did not already say, and a crashed
  # predicate (rc >= 2) yields no guidance at all (I-021) — only a pointer.
  GUIDANCE_RC=0
  GUIDANCE="$(resume_guidance)" || GUIDANCE_RC=$?
  if ((GUIDANCE_RC == 0)); then
    log "STOP: ${GUIDANCE}"
    log "HELP: \`just status\` shows this same evaluation; \`just triage\` triages the gates interactively (META.md §13.6); each gate's full request text is in ${PROJECT_STATE_ROOT}/state/recommendations.json (B- ids: blockers.json)."
  elif ((GUIDANCE_RC >= 2)); then
    warn "${TOOL} state should-stop failed; run \`just status\` once the state is readable (I-021)."
  fi
  exit 3
elif ((RESUME_RC != 0)); then
  [[ -n "${RESUME_JSON}" ]] && printf '%s\n' "${RESUME_JSON}"
  err "${TOOL} state resume failed unexpectedly (exit ${RESUME_RC}); the transition may be half-applied."
  err "Inspect \`git status\` and the state files before retrying (META.md §13.5)."
  exit 2
fi
printf '%s\n' "${RESUME_JSON}"

require_tool_bin
MODE="$("${TOOL_BIN}" util json-get mode <<<"${RESUME_JSON}")"
CLOSED_RUNS="$("${TOOL_BIN}" util json-get closed_runs --join , <<<"${RESUME_JSON}")"
REMAINING_SHOULD_STOP="$("${TOOL_BIN}" util json-get \
  should_stop_after_resume.should_stop <<<"${RESUME_JSON}")"
REMAINING_STOP=""
if [[ "${REMAINING_SHOULD_STOP}" == "true" ]]; then
  REMAINING_STOP="$("${TOOL_BIN}" util json-get \
    should_stop_after_resume.message <<<"${RESUME_JSON}")"
fi

if [[ "${MODE}" == "noop" ]]; then
  log "Nothing to release or record; gates and worktree are already clean."
  exit 0
fi

state_validate_soft --project "${PROJECT_ARG}" ||
  warn "validation errors remain; the next cycle's agent must repair state first (§13.2)"

commit_resume_checkpoint "${NOTE}" "${MODE}" "${CLOSED_RUNS}"

if [[ -n "${REMAINING_STOP}" ]]; then
  warn "stop conditions remain after resume: ${REMAINING_STOP}"
  warn "the next \`just loop\` will re-gate until they are addressed."
fi

if [[ -n "${CLOSED_RUNS}" ]]; then
  log "Crash recovery recorded (closed run(s) ${CLOSED_RUNS}). Review the checkpoint, then run \`just loop\`."
elif [[ "${MODE}" == "steering" ]]; then
  log "Human update recorded. Run \`just loop\` (or \`just once\`) to continue."
else
  log "Human gates released. Run \`just loop\` (or \`just once\`) to continue."
fi
