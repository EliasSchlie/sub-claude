#!/usr/bin/env bash
# Run claude-pool tests.
# By default runs unit + integration tests (mocked, fast).
# Use --live to also run live tests (real Claude, slow, costs tokens).
set -euo pipefail
cd "$(dirname "$0")"

run_live=false
args=()
for arg in "$@"; do
  case "$arg" in
    --live) run_live=true ;;
    *) args+=("$arg") ;;
  esac
done

jobs="$(nproc 2>/dev/null || sysctl -n hw.ncpu)"
dirs=(unit/)
[ -d integration/ ] && dirs+=(integration/)
bats --jobs "$jobs" "${dirs[@]}" "${args[@]+"${args[@]}"}"

if $run_live; then
  echo ""
  echo "=== Running live tests (real Claude, real tokens) ==="
  bash live/run.sh "${args[@]+"${args[@]}"}"
fi
