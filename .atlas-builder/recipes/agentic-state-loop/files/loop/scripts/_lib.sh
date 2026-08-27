#!/usr/bin/env bash
# agentic-state-loop — shared helpers. Source only, do not execute.
#
# Path vocabulary:
#   LOOP_ROOT   = <target>/<loop-dir>   (parent of this scripts/ dir)
#   TARGET_ROOT = <target>              (the product root; scripts run from here)

set -euo pipefail

# Physical paths everywhere: git prints physical paths from rev-parse, so a
# symlinked logical path would break every prefix computation below.
_ASL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")" && pwd -P)"
LOOP_ROOT="$(cd "${_ASL_SCRIPT_DIR}/.." && pwd -P)"
TARGET_ROOT="$(cd "${LOOP_ROOT}/.." && pwd -P)"
LOOP_DIR_NAME="$(basename "${LOOP_ROOT}")"
# The loop's judgment/state engine: a multi-call binary built from the
# vendored Lean sources in <loop_dir>/lean/ (state + hooks + util + trust).
ASL_BIN="${LOOP_ROOT}/bin/asl-loop"

log() { printf '[loop] %s\n' "$*"; }
warn() { printf '[loop] WARN: %s\n' "$*" >&2; }
err() { printf '[loop] ERROR: %s\n' "$*" >&2; }

require_asl_bin() {
  if [[ ! -x "${ASL_BIN}" ]]; then
    err "engine binary not found: ${ASL_BIN}"
    err "Build it first: just engine-build   (or: cd ${LOOP_ROOT}/lean && lake build && mkdir -p ../bin && install -m 755 .lake/build/bin/asl-loop ../bin/asl-loop)"
    exit 2
  fi
}

state() {
  require_asl_bin
  "${ASL_BIN}" state "$@"
}

# Do not expose the operator's shell secrets to the autonomous Agent through
# inherited environment variables. Authentication must use Claude's normal
# login/config store; only stable process metadata is forwarded.
build_sanitized_claude_env() {
  SANITIZED_CLAUDE_ENV=(env -i CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1)
  local name
  for name in HOME USER LOGNAME PATH SHELL TERM COLORTERM TMPDIR LANG LC_ALL LC_CTYPE NO_COLOR FORCE_COLOR LOOP_TZ; do
    if [[ -n "${!name:-}" ]]; then
      SANITIZED_CLAUDE_ENV+=("${name}=${!name}")
    fi
  done
}

# Evaluate a state-engine yes/no predicate. Exit >= 2 is an engine/state
# failure and must never be read as "no" — that would silently unlatch a gate.
state_predicate() {
  local __outvar="$1"
  shift
  local rc=0 out
  out="$(state "$@")" || rc=$?
  printf -v "${__outvar}" '%s' "${out}"
  if ((rc > 1)); then
    err "asl-loop state $* failed with exit ${rc}; refusing to guess the gate state."
    exit 2
  fi
  return "${rc}"
}

# validate tolerating FINDINGS (exit 1 — recoverable by the next cycle's
# agent) but never a crash (exit >= 2).
# shellcheck disable=SC2120  # "$@" just forwards optional extra flags; callers pass none.
state_validate_soft() {
  local rc=0
  state validate "$@" || rc=$?
  if ((rc > 1)); then
    err "asl-loop state validate crashed (exit ${rc}); this is an engine failure, not a finding."
    exit 2
  fi
  return "${rc}"
}

# The loop always runs from TARGET_ROOT so every relative path and the agent
# session CWD are anchored to the product root.
assert_target_root() {
  if [[ "$(pwd -P)" != "${TARGET_ROOT}" ]]; then
    err "Run this from the product root (${TARGET_ROOT})."
    err "Fix: cd ${TARGET_ROOT} && bash ${LOOP_DIR_NAME}/scripts/$(basename "$0") ..."
    exit 2
  fi
}

# Refuse to run while the instantiation placeholders are unfilled: an
# unparameterized instance must not execute a single cycle.
assert_instance_parameterized() {
  local marker="ASL-PARAMETER-UNFILLED"
  local f
  for f in "${LOOP_ROOT}/schema.json" "${LOOP_ROOT}/prompts/cycle.md"; do
    if [[ ! -f "${f}" ]]; then
      err "missing instance file: ${f}"
      exit 2
    fi
    if grep -q "${marker}" "${f}"; then
      err "${f} still carries ${marker}; fill the instance parameters before running."
      exit 2
    fi
  done
  # A surviving substitution token means the harness guards the wrong paths
  # (the hooks would silently protect a directory literally named after the
  # token); the post-install check catches this once, this guard catches it
  # forever. The constant is spelled split so the instantiation substitution
  # ("every token in the installed files") cannot rewrite the checker itself.
  local token='__ASL_LOOP''_DIR__'
  local f="${TARGET_ROOT}/.claude/settings.json"
  if [[ -f "${f}" ]] && grep -q "${token}" "${f}"; then
    err "${f} still carries the ${token} substitution token; the harness is guarding the wrong paths. Re-run the instantiation substitution."
    exit 2
  fi
}

# --- Claude Code launch trust --------------------------------------------
# Without trust, Claude Code ignores .claude/settings.json permissions and
# hooks — the harness would silently not exist. Refuse to launch untrusted.
# Trusted when EITHER the product root or its git toplevel is accepted
# (`asl-loop trust status` reads ~/.claude.json; both paths are physical).
require_claude_trust() {
  require_asl_bin
  local candidates=("${TARGET_ROOT}") top candidate
  top="$(git -C "${TARGET_ROOT}" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "${top}" && "${top}" != "${TARGET_ROOT}" ]]; then
    candidates+=("${top}")
  fi
  for candidate in "${candidates[@]}"; do
    if "${ASL_BIN}" trust status --quiet "${candidate}"; then
      return 0
    fi
  done
  err "Claude Code trust is missing for ${TARGET_ROOT}; hooks/permissions would not be enforced."
  err "Fix: cd ${TARGET_ROOT} && CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 CLAUDE_CODE_SKIP_PROMPT_HISTORY=1 claude --setting-sources project --strict-mcp-config"
  err "Accept the trust dialog once, then exit."
  exit 2
}

# --- single-flight lock ----------------------------------------------------
# At most one loop/resume transition per instance. mkdir is the portable
# atomic lock; the pid file lets locks abandoned by dead processes be
# reclaimed.
LOOP_LOCK_DIR=""

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

acquire_loop_lock() {
  local lock_dir="${LOOP_ROOT}/tmp/loop.lock"
  mkdir -p "${LOOP_ROOT}/tmp"
  local attempt owner_pid moved_pid
  # shellcheck disable=SC2034  # `attempt` only bounds the retry count.
  for attempt in 1 2 3; do
    if mkdir "${lock_dir}" 2>/dev/null; then
      LOOP_LOCK_DIR="${lock_dir}"
      # Arm the release trap BEFORE writing the pid so a crash in the tiny
      # mkdir->pid-write window still cleans up on exit.
      trap 'release_loop_lock' EXIT
      printf '%s\n' "$$" >"${lock_dir}/pid"
      return 0
    fi
    owner_pid="$(cat "${lock_dir}/pid" 2>/dev/null || true)"
    if [[ -n "${owner_pid}" ]] && lock_pid_is_alive "${owner_pid}"; then
      err "another loop/resume is already running (pid ${owner_pid}); only one may run per instance."
      exit 5
    fi
    if [[ -z "${owner_pid}" ]] && [[ -z "$(find "${lock_dir}" -maxdepth 0 -mmin +1 2>/dev/null)" ]]; then
      # A pid-less lock younger than a minute is almost certainly a holder
      # caught between its mkdir and its pid write, not debris. Reclaiming it
      # would erase the winner's lock and let two transitions run — refuse.
      err "another loop/resume appears to be acquiring the lock right now (${lock_dir}); retry in a few seconds."
      exit 5
    fi
    warn "reclaiming stale loop lock (owner pid ${owner_pid:-unknown} is not running)"
    # Reclaim by atomic rename, and verify identity: if a racer already
    # recreated a fresh lock, our mv would grab and destroy it and both of us
    # would hold. On mismatch, restore it and refuse.
    if mv "${lock_dir}" "${lock_dir}.reclaim.$$" 2>/dev/null; then
      moved_pid="$(cat "${lock_dir}.reclaim.$$/pid" 2>/dev/null || true)"
      if [[ "${moved_pid}" != "${owner_pid}" ]]; then
        mv "${lock_dir}.reclaim.$$" "${lock_dir}" 2>/dev/null || true
        err "the loop lock changed hands during reclamation; retry in a few seconds."
        exit 5
      fi
      rm -rf "${lock_dir}.reclaim.$$"
    fi
  done
  err "could not acquire the loop lock: ${lock_dir}"
  exit 5
}

release_loop_lock() {
  if [[ -n "${LOOP_LOCK_DIR}" && -d "${LOOP_LOCK_DIR}" ]]; then
    # Only remove the lock if it is still ours (its pid is this process); a
    # reclamation race may have moved ours out from under us.
    local on_disk_pid
    on_disk_pid="$(cat "${LOOP_LOCK_DIR}/pid" 2>/dev/null || true)"
    if [[ -n "${on_disk_pid}" && "${on_disk_pid}" != "$$" ]]; then
      warn "the loop lock is no longer ours; leaving it in place."
    else
      rm -rf "${LOOP_LOCK_DIR}"
    fi
    LOOP_LOCK_DIR=""
  fi
}

# --- git context and the atomic-commit discipline ---------------------------

resolve_git_context() {
  command -v git >/dev/null 2>&1 || {
    err "git not found; cycle commits require git."
    exit 2
  }
  GIT_ROOT="$(git -C "${TARGET_ROOT}" rev-parse --show-toplevel 2>/dev/null)" ||
    {
      err "TARGET_ROOT is not inside a git repository."
      exit 2
    }
  if [[ "${TARGET_ROOT}" == "${GIT_ROOT}" ]]; then
    TARGET_REL="."
  else
    TARGET_REL="${TARGET_ROOT#"${GIT_ROOT}"/}"
  fi
}

git_in_progress_path_exists() {
  local path
  path="$(git -C "${GIT_ROOT}" rev-parse --git-path "$1")"
  [[ -e "${path}" ]]
}

assert_git_commit_ready() {
  [[ -n "${GIT_ROOT:-}" ]] || resolve_git_context
  if git_in_progress_path_exists MERGE_HEAD || git_in_progress_path_exists rebase-merge ||
    git_in_progress_path_exists rebase-apply || git_in_progress_path_exists CHERRY_PICK_HEAD ||
    git_in_progress_path_exists REVERT_HEAD; then
    err "git operation in progress; refusing to start a cycle."
    exit 4
  fi
  # A checkpoint on a detached HEAD silently disappears on the next checkout.
  git -C "${GIT_ROOT}" symbolic-ref -q HEAD >/dev/null ||
    {
      err "HEAD is detached; checkpoints must land on a branch."
      exit 4
    }
  git -C "${GIT_ROOT}" config user.name >/dev/null ||
    {
      err "git user.name is not configured."
      exit 4
    }
  git -C "${GIT_ROOT}" config user.email >/dev/null ||
    {
      err "git user.email is not configured."
      exit 4
    }
}

# One cycle = one commit requires each cycle to start clean: a dirty worktree
# would mix foreign diffs into the cycle's checkpoint.
assert_clean_worktree_for_cycle() {
  assert_git_commit_ready
  local status
  status="$(git -C "${GIT_ROOT}" status --porcelain --untracked-files=all)"
  if [[ -n "${status}" ]]; then
    err "a cycle requires a clean worktree (one cycle = one atomic commit)."
    err "If these are your own edits, commit them (or record them with resume.sh)."
    git -C "${GIT_ROOT}" status --short --untracked-files=all >&2
    exit 4
  fi
}

# Paths a checkpoint must never carry: runtime debris, secrets, atomic-write
# leftovers. Committing them would launder junk or secrets into history.
is_forbidden_checkpoint_path() {
  case "/$1" in
    */"${LOOP_DIR_NAME}"/tmp/.gitkeep) return 1 ;;
    */"${LOOP_DIR_NAME}"/tmp/*) return 0 ;;
    */.env | */.env.* | */secrets/* | */config/credentials.json) return 0 ;;
    */state/*.tmp) return 0 ;;
  esac
  return 1
}

# Protected paths (declared in schema.json `protected_paths`, target-relative):
# files only a human may change. A diff on them is left out of the cycle
# commit and waits for the human's own resume checkpoint.
is_protected_leftover_path() {
  local path="$1"
  local rel="${path}"
  [[ "${TARGET_REL}" != "." ]] && rel="${path#"${TARGET_REL}"/}"
  "${ASL_BIN}" util protected-match --loop-root "${LOOP_ROOT}" "${rel}"
}

# --- checkpoint scope and the credential guard ------------------------------
# A checkpoint may only carry the target. When the target is a subdirectory of
# a larger repository, anything the human staged elsewhere is theirs: a cycle
# cannot reach it (each cycle starts from a clean worktree) but a resume can,
# because a resume deliberately records a dirty worktree.
path_in_checkpoint_scope() {
  [[ "${TARGET_REL}" == "." ]] && return 0
  case "$1" in
    "${TARGET_REL}" | "${TARGET_REL}"/*) return 0 ;;
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
# secret. Path isolation (is_forbidden_checkpoint_path, and the harness deny
# rules) cannot prevent a noisy tool from copying a credential into ordinary
# source or a log the cycle produced. There is deliberately no in-band
# suppression marker: an agent that can edit staged content could otherwise
# authorize its own bypass.
# One definition shared by the authoritative staged-blob scan (index bytes at
# commit time) and the resume feasibility pre-scan (worktree bytes before any
# state mutation).
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
  # Captured to a file, not read from a pipeline: an enumeration that failed
  # must not read as "nothing staged" — that is a scan reporting clean because
  # it never ran.
  paths_file="$(mktemp "${TMPDIR:-/tmp}/asl-loop-staged-paths.XXXXXX")" || {
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
# rejected by the commit guards. A resume releases gates and appends to the
# state ledger BEFORE it commits, so an abort at commit time would leave a
# half-applied resume on disk — the transition would be recorded as done while
# no checkpoint carries it.
assert_resume_checkpoint_feasible() {
  assert_git_commit_ready

  local ok=1
  local path
  while IFS= read -r -d '' path; do
    if ! path_in_checkpoint_scope "${path}"; then
      err "Uncommitted change outside the checkpoint scope: ${path}"
      ok=0
    elif is_forbidden_checkpoint_path "${path}"; then
      err "Uncommitted change on a forbidden checkpoint path: ${path}"
      ok=0
    elif [[ -f "${GIT_ROOT}/${path}" ]] &&
      LC_ALL=C grep -I -q -E -e "${SECRET_SCAN_PATTERN}" "${GIT_ROOT}/${path}" 2>/dev/null; then
      # The authoritative scan stays the index-blob scan at commit
      # (guard_no_staged_secrets); this is the worktree-side pre-check that
      # keeps the mutation from starting at all.
      err "Potential secret in an uncommitted file the checkpoint would carry: ${path}"
      ok=0
    fi
  done < <(list_uncommitted_paths)

  if [[ "${ok}" -ne 1 ]]; then
    err "Resume refused before touching state: commit, stash, or remove the paths above first."
    exit 4
  fi
}

# Stage every TARGET_ROOT change, enforce the guards, and create exactly one
# commit. on_empty: "fail" (cycle commits must never be empty) or "skip"
# (a resume may find nothing left to record).
create_guarded_checkpoint() {
  local subject="$1"
  local body="$2"
  local on_empty="${3:-fail}"
  local honor_protected="${4:-yes}"

  [[ -n "${GIT_ROOT:-}" ]] || resolve_git_context
  assert_git_commit_ready

  git -C "${GIT_ROOT}" add -A -- "${TARGET_REL}"

  # --no-renames is mandatory: with rename detection a human's mid-cycle move
  # of a protected file reports only the destination, hiding the source-side
  # deletion, which would then ride the cycle commit. Splitting the rename into
  # two records lets the reset below unstage both sides.
  local staged aborted=0
  while IFS= read -r -d '' staged; do
    if is_forbidden_checkpoint_path "${staged}"; then
      err "forbidden path staged for checkpoint: ${staged}"
      aborted=1
    elif [[ "${honor_protected}" == "yes" ]] && is_protected_leftover_path "${staged}"; then
      git -C "${GIT_ROOT}" reset -q -- "${staged}" >/dev/null 2>&1 || true
    fi
  done < <(git -C "${GIT_ROOT}" diff --cached --no-renames --name-only -z)
  if [[ "${aborted}" -eq 1 ]]; then
    git -C "${GIT_ROOT}" reset -q -- "${TARGET_REL}"
    err "checkpoint aborted; remove or ignore the forbidden paths first."
    exit 4
  fi
  # Fail-closed: no protected path may survive the reset still staged.
  if [[ "${honor_protected}" == "yes" ]]; then
    while IFS= read -r -d '' staged; do
      if is_protected_leftover_path "${staged}"; then
        git -C "${GIT_ROOT}" reset -q -- "${TARGET_REL}"
        err "protected path still staged after the reset: ${staged}"
        exit 4
      fi
    done < <(git -C "${GIT_ROOT}" diff --cached --no-renames --name-only -z)
  fi

  # A cycle cannot reach either of the next two (it starts from a clean
  # worktree), but a resume records a dirty one — and that is exactly where a
  # foreign staged path or a credential would ride into history.
  if ! guard_no_staged_outside_checkpoint_scope; then
    git -C "${GIT_ROOT}" reset -q -- "${TARGET_REL}"
    err "checkpoint aborted; staged changes outside the target require human review."
    exit 4
  fi
  if ! guard_no_staged_secrets; then
    git -C "${GIT_ROOT}" reset -q -- "${TARGET_REL}"
    exit 4
  fi

  if git -C "${GIT_ROOT}" diff --cached --quiet --exit-code; then
    if [[ "${on_empty}" == "skip" ]]; then
      log "no changes to commit for: ${subject}"
      return 0
    fi
    err "no staged changes for ${subject}; refusing an empty checkpoint."
    exit 4
  fi

  git -C "${GIT_ROOT}" commit -m "${subject}" -m "${body}" >/dev/null
  log "committed: ${subject}"

  # Anything still dirty is either a protected leftover (human's own resume
  # checkpoint records it) or an anomaly worth failing loudly on.
  #
  # -z (NUL-separated, C-quoting disabled) is mandatory: the default
  # --porcelain quotes and C-escapes any non-ASCII path (core.quotePath=true),
  # so `${line:3}` on a non-ASCII target directory or asset would misread the
  # leftover path, fail to match it as a protected leftover, and turn a correct
  # cycle checkpoint into a spurious exit 4. Each -z record is the 3-char
  # `XY ` status prefix followed by the verbatim path.
  local rec path leftover="" anomaly=0
  while IFS= read -r -d '' rec; do
    path="${rec:3}"
    if is_forbidden_checkpoint_path "${path}"; then
      continue
    fi
    if [[ "${honor_protected}" == "yes" ]] && is_protected_leftover_path "${path}"; then
      leftover="${leftover:+${leftover}, }${path}"
      continue
    fi
    anomaly=1
  done < <(git -C "${GIT_ROOT}" -c core.quotePath=false status --porcelain -z --untracked-files=all)
  if [[ "${anomaly}" -eq 1 ]]; then
    err "checkpoint completed, but the worktree is still dirty:"
    git -C "${GIT_ROOT}" status --short --untracked-files=all >&2
    exit 4
  fi
  if [[ -n "${leftover}" ]]; then
    warn "protected file(s) changed during this cycle and were NOT committed: ${leftover}"
    warn "Record them as a human checkpoint: bash ${LOOP_DIR_NAME}/scripts/resume.sh --note \"...\""
  fi
}

# True when the current worktree diff contains anything OUTSIDE the loop's
# own state directory — the cycle produced real product progress, not just
# bookkeeping.
worktree_has_non_state_changes() {
  [[ -n "${GIT_ROOT:-}" ]] || resolve_git_context
  local rec path state_prefix
  if [[ "${TARGET_REL}" == "." ]]; then
    state_prefix="${LOOP_DIR_NAME}/state/"
  else
    state_prefix="${TARGET_REL}/${LOOP_DIR_NAME}/state/"
  fi
  # -z for the same reason as the checkpoint scan above: a C-quoted non-ASCII
  # path would not compare equal to the verbatim state_prefix, so bookkeeping
  # under a non-ASCII target would read as real product progress and poison
  # the idle-cycle counter in both directions.
  while IFS= read -r -d '' rec; do
    path="${rec:3}"
    [[ "${path}" == "${state_prefix}"* ]] && continue
    is_forbidden_checkpoint_path "${path}" && continue
    return 0
  done < <(git -C "${GIT_ROOT}" -c core.quotePath=false status --porcelain -z --untracked-files=all)
  return 1
}

stop_message_from_json() {
  "${ASL_BIN}" util stop-message <<<"$1"
}
