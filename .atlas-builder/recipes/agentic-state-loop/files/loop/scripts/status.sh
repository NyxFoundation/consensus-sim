#!/usr/bin/env bash
# agentic-state-loop — human-readable state summary (read-only; computed from
# canonical state on demand, no generated summary file exists).
#
# Usage: cd <target> && bash <loop-dir>/scripts/status.sh

# shellcheck source=./_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

assert_target_root
require_asl_bin
exec "${ASL_BIN}" state status
