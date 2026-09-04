#!/usr/bin/env bash
# Continuous-integration entry point for consensus-sim.
#
# The GitHub Pages workflow at the repository root is a thin shim: it checks
# the repository out, installs Node and calls this script once from
# consensus-sim/, then publishes dist/ only if the script exited 0. What CI
# actually does — the dependency install and the checks, in this order — is
# decided here:
#
#   1. npm ci          clean install from package-lock.json
#   2. npm test        vitest (model, chain state, fork choice, attacks, UI shell,
#                      design contract)
#   3. npm run build   tsc --noEmit, then vite build into dist/
#   4. dist check      dist/ is self-contained: index.html references its
#                      assets only by relative path, so the bundle works from
#                      the Pages subpath (or any other)
#
# The script stops at the first failure (set -e) and exits non-zero, which
# is what keeps a broken commit from being published. It has no arguments and
# no environment requirements beyond Node and npm; run it from anywhere:
#
#   bash consensus-sim/scripts/ci.sh
#
# To reproduce the deploy contract locally, run it in a fresh clone (or a
# copy without node_modules/) — `npm ci` replaces node_modules/ wholesale.

set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> npm ci"
npm ci

echo "==> npm test"
npm test

echo "==> npm run build"
npm run build

echo "==> dist/ self-containment"
index="dist/index.html"
if [ ! -f "$index" ]; then
  echo "ci: $index was not produced" >&2
  exit 1
fi
# Every src= / href= must be relative: none may start with "/" or a scheme.
if grep -Eq '(src|href)="(/|[a-zA-Z][a-zA-Z0-9+.-]*:)' "$index"; then
  echo "ci: $index references an absolute or scheme URL:" >&2
  grep -Eo '(src|href)="[^"]*"' "$index" >&2
  exit 1
fi
if ! grep -Eq '(src|href)="\./assets/' "$index"; then
  echo "ci: $index does not reference ./assets/ — unexpected bundle layout:" >&2
  grep -Eo '(src|href)="[^"]*"' "$index" >&2
  exit 1
fi
echo "ok: $index references assets by relative path only"
