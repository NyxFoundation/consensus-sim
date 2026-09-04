#!/usr/bin/env bash
# doctor.sh — inspect CWD, layout, Claude Code availability, settings,
# hooks, and canonical state health (META.md §18.1, §28.5).
#
# Usage: cd ./.<tool> && bash scripts/doctor.sh --project ../PROJECT_TITLE

# shellcheck source=./_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

assert_control_root
resolve_project "$@"

ERRORS=0
WARNINGS=0
fail() {
  err "$*"
  ERRORS=$((ERRORS + 1))
}
note() {
  warn "$*"
  WARNINGS=$((WARNINGS + 1))
}
ok() { log "OK: $*"; }

# $1 = newline-separated issue list (each line becomes one fail),
# $2 = ok message when the list is empty.
report_issues() {
  local issues="$1" ok_msg="$2" issue
  if [[ -z "${issues}" ]]; then
    ok "${ok_msg}"
    return 0
  fi
  while IFS= read -r issue; do
    [[ -n "${issue}" ]] && fail "${issue}"
  done <<<"${issues}"
  # A trailing empty line must not leak the [[ -n ]] failure status into the
  # caller's `set -e`.
  return 0
}

log "Doctor: CONTROL_ROOT=${CONTROL_ROOT}"
log "Doctor: PROJECT_ROOT=${PROJECT_ROOT}"

# --- Toolchain -------------------------------------------------------------
if command -v git >/dev/null 2>&1; then
  ok "git available"
else
  fail "git not found; loop cycle commits cannot run"
fi
CLAUDE_AVAILABLE=0
if command -v claude >/dev/null 2>&1; then
  CLAUDE_AVAILABLE=1
  ok "claude CLI available ($(claude --version 2>/dev/null | head -1 || echo 'version unknown'))"
  CLAUDE_HELP="$(claude --help 2>/dev/null || true)"
  CLAUDE_PERMISSION_BLOCK="$(sed -n '/--permission-mode <mode>/,/--plugin-dir/p' <<<"${CLAUDE_HELP}")"
  if grep -q "dontAsk" <<<"${CLAUDE_PERMISSION_BLOCK}"; then
    ok "claude CLI supports autonomous permission mode dontAsk"
  else
    fail "claude CLI does not advertise required permission mode dontAsk; update ${TOOL_NAME}/Claude before launching sessions (§28.5)"
  fi
  if grep -q "manual" <<<"${CLAUDE_PERMISSION_BLOCK}"; then
    ok "claude CLI supports interactive permission mode manual"
  elif grep -q "default" <<<"${CLAUDE_PERMISSION_BLOCK}"; then
    ok "claude CLI supports interactive permission mode default"
  else
    fail "claude CLI advertises neither manual nor default ask-before-edits mode; update ${TOOL_NAME}/Claude before launching sessions (§28.5)"
  fi
  # §16.1: the model is deployment policy, not a safety boundary, so a CLI
  # without --model only costs the <TOOL>_MODEL escape hatch (settings.json
  # still decides) — informational, never a failure.
  if grep -q -- "--model" <<<"${CLAUDE_HELP}"; then
    ok "claude CLI supports --model; ${TOOL_ENV}_MODEL=<alias|model-id> can override the settings.json model per run (§16.1)"
  else
    note "claude CLI does not advertise --model; ${TOOL_ENV}_MODEL overrides are unavailable and settings.json decides the model (§16.1)"
  fi
  for required_flag in "--setting-sources" "--strict-mcp-config" "--settings"; do
    if grep -q -- "${required_flag}" <<<"${CLAUDE_HELP}"; then
      ok "claude CLI supports required isolation flag ${required_flag}"
    else
      fail "claude CLI does not advertise required isolation flag ${required_flag}; update Claude before launching sessions (§11.4, §28.5)"
    fi
  done

  # §19.1-5 / §28.5: the headless `-p` floor of both session forms is asserted
  # by the launcher-fragment check below ('claude -p "${PROMPT}"' /
  # 'claude -c -p "${PROMPT}"') — a strictly stronger form of the probe that
  # used to live here.
else
  note "claude CLI not found on PATH — the loop cannot run"
fi
# --- lean runtime ------------------------------------------------------------
# The Lean runtime source ships inside CONTROL_ROOT (self-contained
# distribution unit, META.md §31.1 R-1), and `just build` places the built
# binary at CONTROL_ROOT/bin/<tool>. The binary is the control plane's only
# execution engine — state, hooks, trust, and doctor's own JSON diagnostics
# all run on it — so a missing binary is a hard failure.
if [[ -f "${CONTROL_ROOT}/lean/lean-toolchain" ]]; then
  ok "CONTROL_ROOT/lean/lean-toolchain present"
else
  fail "missing CONTROL_ROOT/lean/lean-toolchain; the Lean runtime sources are part of the distributed control plane (META.md §31.1 R-1)"
fi
LEAN_BIN="${CONTROL_ROOT}/bin/${TOOL}"
if [[ -x "${LEAN_BIN}" ]]; then
  ok "CONTROL_ROOT/bin/${TOOL} present and executable"
  LEAN_BIN_VERSION_RC=0
  LEAN_BIN_VERSION_OUTPUT="$("${LEAN_BIN}" version 2>&1)" || LEAN_BIN_VERSION_RC=$?
  if ((LEAN_BIN_VERSION_RC == 0)) && [[ "${LEAN_BIN_VERSION_OUTPUT}" == "${TOOL} "* ]]; then
    ok "bin/${TOOL} version: ${LEAN_BIN_VERSION_OUTPUT}"
  else
    fail "bin/${TOOL} version failed (exit ${LEAN_BIN_VERSION_RC}): ${LEAN_BIN_VERSION_OUTPUT}"
  fi
else
  fail "CONTROL_ROOT/bin/${TOOL} not found; nothing can enforce or transition state without it — run: just build"
fi
if command -v elan >/dev/null 2>&1; then
  ok "elan available ($(elan --version 2>/dev/null | head -1 || echo 'version unknown'))"
else
  note "elan not found on PATH; only required to build the Lean runtime, not to run it"
fi
# --- Git checkpoint readiness ------------------------------------------------
if command -v git >/dev/null 2>&1; then
  CONTROL_GIT_ROOT="$(git -C "${CONTROL_ROOT}" rev-parse --show-toplevel 2>/dev/null || true)"
  PROJECT_GIT_ROOT="$(git -C "${PROJECT_ROOT}" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "${CONTROL_GIT_ROOT}" ]]; then
    ok "CONTROL_ROOT git root: ${CONTROL_GIT_ROOT}"
  else
    fail "CONTROL_ROOT is not inside a git repository"
  fi
  if [[ -n "${PROJECT_GIT_ROOT}" ]]; then
    ok "PROJECT_ROOT git root: ${PROJECT_GIT_ROOT}"
  else
    fail "PROJECT_ROOT is not inside a git repository"
  fi
  if [[ -n "${CONTROL_GIT_ROOT}" && -n "${PROJECT_GIT_ROOT}" ]]; then
    if [[ "${CONTROL_GIT_ROOT}" == "${PROJECT_GIT_ROOT}" ]]; then
      ok "CONTROL_ROOT and PROJECT_ROOT share one git repository"
      if git -C "${CONTROL_GIT_ROOT}" config user.name >/dev/null; then
        ok "git user.name configured"
      else
        fail "git user.name is not configured"
      fi
      if git -C "${CONTROL_GIT_ROOT}" config user.email >/dev/null; then
        ok "git user.email configured"
      else
        fail "git user.email is not configured"
      fi
      if git -C "${CONTROL_GIT_ROOT}" rev-parse --verify HEAD >/dev/null 2>&1; then
        ok "git repository has at least one commit"
      else
        note "git repository has no commits yet; the first cycle commit will create history"
      fi
      for marker in MERGE_HEAD REBASE_HEAD rebase-merge rebase-apply CHERRY_PICK_HEAD REVERT_HEAD; do
        mp="$(git -C "${CONTROL_GIT_ROOT}" rev-parse --git-path "${marker}")"
        [[ -e "${mp}" ]] && fail "git operation in progress: ${marker}"
      done
      if [[ -z "$(git -C "${CONTROL_GIT_ROOT}" status --porcelain --untracked-files=all)" ]]; then
        ok "git worktree clean for next cycle"
      else
        note "git worktree is dirty; loop.sh will refuse to start a cycle until it is clean"
      fi
    else
      fail "CONTROL_ROOT and PROJECT_ROOT are in different git repositories"
    fi
  fi
fi

# --- Claude Code trust ------------------------------------------------------
# Claude Code ignores project .claude/settings.json permissions/hooks until the
# launch workspace is trusted. The framework launches only the Over-Project Agent;
# a target runtime is never started directly in the live project (§10).
if [[ "${CLAUDE_AVAILABLE}" -eq 1 ]]; then
  check_claude_trust() {
    local label="$1"
    shift
    local output
    if [[ ! -x "${LEAN_BIN}" ]]; then
      fail "Claude Code trust check for ${label} requires bin/${TOOL}; run: just build"
      return 0
    fi
    if output="$("${LEAN_BIN}" trust status "$@" 2>&1)"; then
      ok "Claude Code trust for ${label}"
    else
      fail "Claude Code trust missing for ${label}; run 'just trust' from CONTROL_ROOT"
      printf '%s\n' "${output}" >&2
    fi
  }

  collect_claude_launch_trust_candidates "${CONTROL_ROOT}"
  check_claude_trust "Over-Project Agent launch root" "${CLAUDE_TRUST_CANDIDATES[@]}"

else
  note "skipping Claude Code trust check because claude CLI is not on PATH"
fi

# --- CONTROL_ROOT layout ---------------------------------------------------
for f in CLAUDE.md .claude/settings.json "scripts/loop.sh" "scripts/supervise.sh"; do
  if [[ -f "${CONTROL_ROOT}/${f}" ]]; then
    ok "CONTROL_ROOT/${f}"
  else
    fail "missing CONTROL_ROOT/${f}"
  fi
done
for d in .agent/state .agent/runs .agent/prompts; do
  if [[ -d "${CONTROL_ROOT}/${d}" ]]; then
    ok "CONTROL_ROOT/${d}/"
  else
    fail "missing CONTROL_ROOT/${d}/"
  fi
done
# All five hook events run on `bin/<tool> hook <event>` (guard cutover,
# META.md §31.2-42), whose binary presence + version the lean runtime block
# above already diagnoses.

# settings.json must parse, bind exactly to the project, and wire the safety hooks.
# The structural checks live in the pure Lean core (Looper/Core/SettingsDoctor);
# the launcher source-fragment checks below are plain grep and stay here.
if [[ ! -x "${LEAN_BIN}" ]]; then
  fail ".claude/settings.json safety-wiring check requires bin/${TOOL}; run: just build"
else
  # ESSENCE-declared execution profile (META.md §11.5): the settings check is
  # a symmetric three-way match against the declaration, so the doctor is the
  # single place where a declaration/rendering mismatch surfaces (launchers
  # carry no pre-flight check — both mismatch directions fail safe, §11.5).
  # An invalid/conflicting declaration is itself a failure and the settings
  # are then checked against standard (the value it degrades to).
  if DOCTOR_PROFILE="$("${LEAN_BIN}" util essence-profile "${PROJECT_ROOT}/ESSENCE.md")"; then
    ok "ESSENCE execution profile: ${DOCTOR_PROFILE} (META.md §11.5)"
  else
    fail "ESSENCE.md declares an invalid or conflicting profile; it runs as standard until fixed (META.md §11.5)"
    DOCTOR_PROFILE="standard"
  fi
  SETTINGS_ISSUES="$("${LEAN_BIN}" util settings-doctor .claude/settings.json "${PROJECT_ROOT}" "${CONTROL_ROOT}" "${DOCTOR_PROFILE}")"
  WIRING_ISSUES="$(
    # Each launcher must keep its session-isolation and fail-closed fragments.
    # claude -p / claude -c -p are not cosmetic: credential scrubbing makes
    # the CLI resolve default mode, so the headless session IS the fail-closed
    # floor (§19.1-5, §28.5). NOTE: bash 3.2 (macOS) mis-parses quotes and
    # backticks inside command-substitution comments — keep them out of every
    # comment within this substitution.
    emit_missing_fragments() {
      local path="$1" fragment
      shift
      if [[ ! -f "${path}" ]]; then
        printf 'cannot inspect Claude launcher %s\n' "${path}"
        return 0
      fi
      for fragment in "$@"; do
        if ! grep -qF -- "${fragment}" "${path}"; then
          printf "%s must contain '%s'\n" "${path}" "${fragment}"
        fi
      done
    }
    # shellcheck disable=SC2016  # the fragments are literal source text, not expansions
    emit_missing_fragments "scripts/loop.sh" \
      'claude -p "${PROMPT}"' 'claude -c -p "${PROMPT}"' \
      build_sanitized_claude_env '"${LOCK_TOKEN_ENV}=${LOOP_LOCK_TOKEN}"' \
      build_bound_session_settings '"${SESSION_SETTINGS_ARGS[@]+' \
      '--setting-sources project' --strict-mcp-config
    # shellcheck disable=SC2016  # the fragments are literal source text, not expansions
    emit_missing_fragments "scripts/triage.sh" \
      '"${TOOL_ENV}_SESSION_MODE=triage"' '"${TOOL_ENV}_SESSION_PROJECT_ROOT=' \
      CLAUDE_CODE_SKIP_PROMPT_HISTORY=1 resolve_interactive_permission_mode \
      build_sanitized_claude_env build_read_only_session_settings \
      '--add-dir "${PROJECT_ROOT}"' --disallowedTools \
      --settings '--setting-sources project' --strict-mcp-config
    # shellcheck disable=SC2016  # the fragments are literal source text, not expansions
    emit_missing_fragments "scripts/essence.sh" \
      '"${TOOL_ENV}_SESSION_MODE=essence"' '"${TOOL_ENV}_SESSION_PROJECT_ROOT=' \
      CLAUDE_CODE_SKIP_PROMPT_HISTORY=1 resolve_interactive_permission_mode \
      build_sanitized_claude_env build_read_only_session_settings \
      '--add-dir "${PROJECT_ROOT}"' --disallowedTools \
      --settings '--setting-sources project' --strict-mcp-config
    # shellcheck disable=SC2016  # the fragments are literal source text, not expansions
    emit_missing_fragments "scripts/supervise.sh" \
      CLAUDE_CODE_SKIP_PROMPT_HISTORY=1 '"${LOCK_TOKEN_ENV}=${LOOP_LOCK_TOKEN}"' \
      resolve_interactive_permission_mode build_sanitized_claude_env \
      build_bound_session_settings '"${SESSION_SETTINGS_ARGS[@]+' \
      '--setting-sources project' --strict-mcp-config
    if [[ ! -f scripts/_lib.sh ]]; then
      printf 'cannot inspect scripts/_lib.sh\n'
    else
      # The read-only session settings construction lives in the Lean core
      # (Looper/Core/Settings.lean); what _lib.sh must still prove here is
      # the wiring: sanitized env -i launches, advisory sessions fed from
      # <tool> util read-only-settings, and no CLAUDE_CONFIG_DIR forwarded
      # into Agent sessions.
      if ! grep -qF -- 'SANITIZED_CLAUDE_ENV=(env -i CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1)' scripts/_lib.sh; then
        printf 'scripts/_lib.sh must launch Claude through env -i plus subprocess credential scrubbing\n'
      fi
      if ! grep -qF -- 'util read-only-settings' scripts/_lib.sh; then
        # shellcheck disable=SC2016  # backticks are message formatting, not expansion
        printf 'scripts/_lib.sh must build advisory-session settings via %s (read-only target roots)\n' \
          '`<tool> util read-only-settings`'
      fi
      if ! grep -qF -- 'util bound-settings' scripts/_lib.sh; then
        # shellcheck disable=SC2016  # backticks are message formatting, not expansion
        printf 'scripts/_lib.sh must build the bound session overlay via %s (per-launch path rules and sandbox)\n' \
          '`<tool> util bound-settings`'
      fi
      if grep -qF -- 'CLAUDE_CONFIG_DIR' scripts/_lib.sh; then
        printf 'scripts/_lib.sh must not forward CLAUDE_CONFIG_DIR into Agent sessions\n'
      fi
    fi
  )"
  NEWLINE=$'\n'
  report_issues "${SETTINGS_ISSUES:+${SETTINGS_ISSUES}${NEWLINE}}${WIRING_ISSUES}" ".claude/settings.json safety wiring"
fi

if [[ ! -x "${LEAN_BIN}" ]]; then
  fail "hook smoke tests require bin/${TOOL}; run: just build"
else
  HOOK_ISSUES="$(
    # Both payloads embed CONTROL_ROOT/PROJECT_ROOT verbatim in JSON string
    # literals. Paths containing double quotes or backslashes are outside the
    # supported layout (the permission templates and lock paths would break
    # long before this smoke test does). Comments in this substitution must
    # stay free of quotes and backticks (bash 3.2 parser bug, see above).
    if ! session_err="$(printf '{"cwd":"%s","session_id":"doctor"}' "${CONTROL_ROOT}" |
      "${LEAN_BIN}" hook session-start 2>&1 >/dev/null)"; then
      printf 'session_start_guard smoke test failed: %s\n' "${session_err}"
    fi
    # The Lean guard is the production PreToolUse hook (guard cutover, META.md
    # §31.2-42). Drop the guard shadow flag from the environment: an inherited
    # flag would put the hook in the legacy opinion-free shadow mode and turn
    # this smoke into a false failure.
    decision=""
    if pre_out="$(printf '{"cwd":"%s","session_id":"doctor","tool_name":"Edit","tool_input":{"file_path":"%s/ESSENCE.md"}}' \
      "${CONTROL_ROOT}" "${PROJECT_ROOT}" |
      env -u "${TOOL_ENV}_GUARD_SHADOW" "${LEAN_BIN}" hook pre-tool 2>/dev/null)"; then
      decision="$(printf '%s' "${pre_out}" |
        "${LEAN_BIN}" util json-get hookSpecificOutput.permissionDecision --default '' --lenient)"
    fi
    if [[ "${decision}" != "deny" ]]; then
      printf 'lean pre-tool smoke test did not deny PROJECT_ROOT/ESSENCE.md edit\n'
    fi
  )"
  report_issues "${HOOK_ISSUES}" "hook smoke tests passed"
fi

# --- PROJECT_ROOT layout ---------------------------------------------------
if [[ -f "${PROJECT_ROOT}/ESSENCE.md" ]]; then
  ok "PROJECT_ROOT/ESSENCE.md exists"
  if grep -q "${TOOL_PLACEHOLDER}" "${PROJECT_ROOT}/ESSENCE.md" 2>/dev/null; then
    fail "ESSENCE.md is still the placeholder template — a human must write the real Essence (directly, or via \`just new-essence\`, §2.1.4)"
  elif [[ -z "$(tr -d '[:space:]' <"${PROJECT_ROOT}/ESSENCE.md" 2>/dev/null)" ]]; then
    fail "ESSENCE.md is empty — the loop treats it like the placeholder (§13.1-8)"
  elif grep -q "<!-- FILL:" "${PROJECT_ROOT}/ESSENCE.md" 2>/dev/null; then
    # §13.1-8 / §2.1.1: a leftover section FILL marker means an unwritten
    # section; the loop treats it as a placeholder just like the top block.
    fail "ESSENCE.md still has an unfilled '<!-- FILL:' section marker — replace every FILL marker with real content (directly, or via \`just new-essence\`, §2.1.1, §13.1-8)"
  fi
else
  fail "PROJECT_ROOT/ESSENCE.md is missing (human-owned, required before bootstrap; write it directly, or draft it interactively with \`just new-essence\`, §2.1.4)"
fi
# §5.0: the target's CLAUDE.md / .claude/** are the project's own executable
# content. The framework neither seeds nor trusts them, and never starts them in the
# live project. Parsing is only a low-cost product-quality diagnostic; an
# isolated project-defined runner remains mandatory for behavioral verification
# (§10). Its content is project-owned and is not adopted by the control plane.
if [[ -f "${PROJECT_ROOT}/CLAUDE.md" ]]; then
  ok "PROJECT_ROOT/CLAUDE.md present (project-owned content; not inspected)"
fi
if [[ -f "${PROJECT_ROOT}/.claude/settings.json" ]]; then
  if [[ ! -x "${LEAN_BIN}" ]]; then
    fail "PROJECT_ROOT/.claude/settings.json JSON check requires bin/${TOOL}; run: just build"
  elif "${LEAN_BIN}" util json-check "${PROJECT_ROOT}/.claude/settings.json" 2>/dev/null; then
    ok "PROJECT_ROOT/.claude/settings.json parses (project-owned content; not inspected)"
  else
    note "PROJECT_ROOT/.claude/settings.json is not valid JSON — the project's isolated runtime would load a broken config (§10)"
  fi
fi
if [[ -d "${PROJECT_STATE_ROOT}/state" ]]; then
  ok "PROJECT_STATE_ROOT/state/"
else
  note "missing ${PROJECT_STATE_ROOT}/state (run scripts/bootstrap.sh)"
fi

# --- 1:1 binding integrity (§5.2, §8.1, §18.1, §18.2) -----------------------
# project_index.json must register the single project matching the bound
# title. A stale binding silently widens the path-based checkpoint guards
# (§5.2).
INDEX_PATH="${CONTROL_ROOT}/.agent/state/project_index.json"
if [[ ! -f "${INDEX_PATH}" ]]; then
  ok "1:1 binding integrity (project_index)"
elif [[ ! -x "${LEAN_BIN}" ]]; then
  fail "project_index binding check requires bin/${TOOL}; run: just build"
elif ! "${LEAN_BIN}" util json-check "${INDEX_PATH}" 2>/dev/null; then
  fail "project_index.json is unreadable; repair it (§8.1)"
else
  # --lenient: a registry whose `project` is null / not an object reads as
  # "no bound title" (display-only diagnostic; the registry shape is
  # state-engine managed).
  BOUND_TITLE="$("${LEAN_BIN}" util json-get project.title --file "${INDEX_PATH}" --default "" --lenient)"
  if [[ -n "${BOUND_TITLE}" && "${BOUND_TITLE}" != "${PROJECT_TITLE}" ]]; then
    fail "project_index.json is bound to '${BOUND_TITLE}', not '${PROJECT_TITLE}' (§5.2)"
  else
    ok "1:1 binding integrity (project_index)"
  fi
fi

# --- Static-config projection drift (§8.1) ----------------------------------
# workspace.json is a git-managed projection of the Lean SSOT
# (Looper/Core/StaticConfig); the runtime never mutates it. A deployed plane
# may carry a deliberate human repair, so drift is a warning with guidance,
# never an auto-overwrite (§11 direct-editing policy). Byte-exact comparison:
# the same check the maintainer plane freezes as sync test D-008.
WORKSPACE_JSON="${CONTROL_ROOT}/.agent/state/workspace.json"
if [[ ! -f "${WORKSPACE_JSON}" ]]; then
  note "missing .agent/state/workspace.json; restore it (git restore .agent/state/workspace.json) — it is a static projection of the Lean definition (§8.1)"
elif [[ ! -x "${LEAN_BIN}" ]]; then
  fail "workspace.json drift check requires bin/${TOOL}; run: just build"
elif "${LEAN_BIN}" util static-config workspace | cmp -s - "${WORKSPACE_JSON}"; then
  ok "workspace.json matches its Lean definition (Core/StaticConfig)"
else
  note "workspace.json drifted from its Lean definition (Looper/Core/StaticConfig); review the local edit, then restore it (git restore .agent/state/workspace.json) — the framework maintainer regenerates it with 'just render-static' (§8.1)"
fi

# --- Canonical state validation ---------------------------------------------
if [[ -d "${PROJECT_STATE_ROOT}/state" ]]; then
  VALIDATE_RC=0
  state validate --project "${PROJECT_ARG}" || VALIDATE_RC=$?
  if ((VALIDATE_RC == 0)); then
    ok "${TOOL} state validate passed"
  elif ((VALIDATE_RC == 1)); then
    fail "${TOOL} state validate reported errors (see validation.json)"
  else
    fail "${TOOL} state validate failed with exit ${VALIDATE_RC}; canonical state or the state engine itself is broken (I-021)"
  fi
fi

# --- Loop runtime health -----------------------------------------------------
if [[ -d "${LOOP_LOCK_PATH}" ]]; then
  LOCK_PID="$(loop_lock_owner_pid)"
  if [[ -n "${LOCK_PID}" ]] && lock_pid_is_alive "${LOCK_PID}"; then
    note "a ${TOOL_NAME} mutating transition appears to be running right now (pid ${LOCK_PID}, I-018)"
  else
    note "stale loop lock found (pid ${LOCK_PID:-unknown} not running); the next loop/resume reclaims it"
  fi
fi
RUNS_JSONL="${PROJECT_STATE_ROOT}/state/runs.jsonl"
if [[ -f "${RUNS_JSONL}" ]] && [[ ! -x "${LEAN_BIN}" ]]; then
  fail "runs.jsonl in-flight check requires bin/${TOOL}; run: just build"
elif [[ -f "${RUNS_JSONL}" ]]; then
  # §13.5 / I-021: an unreadable or shape-corrupt runs.jsonl means "in-flight
  # unknown" — doctor must guide recovery, never report "none". The scan
  # itself lives in the pure Lean core (Looper/Core/Runs.lean).
  DANGLING_RUN="$("${LEAN_BIN}" util dangling-run "${RUNS_JSONL}")"
  if [[ "${DANGLING_RUN}" == "__UNREADABLE__" ]]; then
    fail "runs.jsonl is unreadable, so in-flight runs cannot be proven; restore it from the last checkpoint commit (git restore) or remove the truncated trailing line (META.md §13.5)"
  elif [[ -n "${DANGLING_RUN}" ]]; then
    note "runs.jsonl has an unfinished run (${DANGLING_RUN}); if the loop crashed, recover with 'just resume --force' (META.md §13.5)"
  fi
fi

# §12.2 / §20.3-3: workspace-root sessions load no framework settings, so no
# hook can detect them — doctor's reminder is part of the documented
# mitigation (operating rule + workspace README + doctor).
log "Reminder: launch the Over-Project Agent through CONTROL_ROOT's just wrappers; raw Claude bypasses their session-isolation flags AND the per-launch --settings overlay (§16.1) — without it the session has no OS sandbox and no path permission rules, leaving only the hook deny floor (I-030)."
log "${TOOL_NAME} also never starts an embedded target agent directly in the live PROJECT_ROOT; use a project-defined isolated runner (§10)."

log "Doctor finished: ${ERRORS} error(s), ${WARNINGS} warning(s)."
[[ "${ERRORS}" -eq 0 ]] || exit 1
