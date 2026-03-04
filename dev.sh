#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# dev.sh — Run sub-claude tools and tests from source
# =============================================================================
# Usage:
#   ./dev.sh run [args]           Run sub-claude from source
#   ./dev.sh test [unit|integration|live|all]  Run tests

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cmd="${1:-help}"
shift || true

case "$cmd" in
  run)
    export PATH="$REPO_DIR/bin:$PATH"
    exec "$REPO_DIR/bin/sub-claude" "$@"
    ;;
  test)
    suite="${1:-unit}"
    shift || true

    # Parse test flags
    quiet=false
    test_args=()
    for arg in "$@"; do
      case "$arg" in
        -q|--quiet) quiet=true ;;
        *) test_args+=("$arg") ;;
      esac
    done

    # _run_bats <dir-glob> [extra-args...]
    # In quiet mode, only show failures and summary.
    _run_bats() {
      local jobs
      jobs="$(nproc 2>/dev/null || sysctl -n hw.ncpu)"
      if $quiet; then
        bats --jobs "$jobs" "$@" 2>&1 | grep -E "^(not ok |# |1\.\.|$)" || true
        # Exit with bats' status, not grep's
        return "${PIPESTATUS[0]}"
      else
        bats --jobs "$jobs" "$@"
      fi
    }

    case "$suite" in
      unit)
        _run_bats "$REPO_DIR/tests/unit/"*.bats "${test_args[@]+"${test_args[@]}"}"
        ;;
      integration)
        _run_bats "$REPO_DIR/tests/integration/"*.bats "${test_args[@]+"${test_args[@]}"}"
        ;;
      live)
        exec bash "$REPO_DIR/tests/live/run.sh" "$@"
        ;;
      all)
        exec bash "$REPO_DIR/tests/run.sh" "$@"
        ;;
      *)
        echo "Unknown test suite: $suite (use unit, integration, live, or all)" >&2
        exit 1
        ;;
    esac
    ;;
  help|-h|--help)
    cat <<'EOF'
Usage: ./dev.sh <command> [args]

  run [args]                Run sub-claude from source
  test [suite] [args]       Run tests (unit, integration, live, all)
    -q, --quiet             Only show failures and summary

Examples:
  ./dev.sh run pool status
  ./dev.sh test unit
  ./dev.sh test unit -q
  ./dev.sh test all
EOF
    ;;
  *)
    echo "dev.sh: unknown command '$cmd'" >&2
    exit 1
    ;;
esac
