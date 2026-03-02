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
    case "$suite" in
      unit)
        jobs="$(nproc 2>/dev/null || sysctl -n hw.ncpu)"
        bats --jobs "$jobs" "$REPO_DIR/tests/unit/"*.bats "$@"
        ;;
      integration)
        jobs="$(nproc 2>/dev/null || sysctl -n hw.ncpu)"
        bats --jobs "$jobs" "$REPO_DIR/tests/integration/"*.bats "$@"
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

Examples:
  ./dev.sh run pool status
  ./dev.sh test unit
  ./dev.sh test all
EOF
    ;;
  *)
    echo "dev.sh: unknown command '$cmd'" >&2
    exit 1
    ;;
esac
