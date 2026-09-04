#!/usr/bin/env bash
# agentic-state-loop — run exactly one cycle.
#
# Usage: cd <target> && bash <loop-dir>/scripts/once.sh

# shellcheck source=./_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

assert_target_root
exec bash "${LOOP_ROOT}/scripts/loop.sh" "$@" --max-cycles 1
