#!/usr/bin/env bash
# claude-trust.sh — explicit human command for Claude Code workspace trust.
#
# This intentionally does not match the agent-allowed <tool>-*.sh pattern:
# it writes ~/.claude.json and must be a human-operated setup step.

# shellcheck source=./_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

assert_control_root
resolve_project "$@"

MODE="check"
for arg in "$@"; do
  case "${arg}" in
    --apply) MODE="apply" ;;
    --check) MODE="check" ;;
  esac
done

collect_claude_launch_trust_candidates "${CONTROL_ROOT}"

# The framework never launches Claude from live PROJECT_ROOT (§10, I-003), so do
# not pre-trust that executable product root. Essence/triage read it only as
# an additional directory from a CONTROL_ROOT session; the launch root (and
# its Git-root spelling, for CLI-version compatibility) is the complete trust
# set the framework needs.

require_tool_bin

case "${MODE}" in
  apply)
    log "Ensuring Claude Code trust for ${TOOL_NAME} launch roots..."
    "${TOOL_BIN}" trust ensure "${CLAUDE_TRUST_CANDIDATES[@]}"
    log "Claude Code trust is ready. Re-run: just doctor"
    ;;
  check)
    "${TOOL_BIN}" trust status "${CLAUDE_TRUST_CANDIDATES[@]}"
    ;;
esac
