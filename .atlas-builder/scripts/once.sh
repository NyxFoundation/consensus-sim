#!/usr/bin/env bash
# once.sh — run exactly one framework cycle (META.md §18.1).
#
# Usage: cd ./.<tool> && bash scripts/once.sh --project ../PROJECT_TITLE

# shellcheck source=./_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

assert_control_root
exec bash "${CONTROL_ROOT}/scripts/loop.sh" "$@" --max-cycles 1
