#!/usr/bin/env bash
# Run live (end-to-end) tests for sub-claude.
#
# WARNING: These tests start real Claude sessions and consume API tokens.
# Each test creates an isolated temporary directory, so they won't interfere
# with your terminal or any running pool sessions.
#
# Usage:
#   ./run.sh                  # Run all live tests
#   ./run.sh pool-lifecycle   # Run a specific test file
#   ./run.sh --filter "init"  # Run tests matching a pattern

set -euo pipefail
cd "$(dirname "$0")"

# Emergency cleanup: kill any leaked tmux servers on exit (e.g. Ctrl-C mid-run)
_emergency_cleanup() {
  local leaked=0
  # Check both /tmp and TMPDIR (macOS uses /var/folders/...)
  local sock_dirs=("/tmp/tmux-$(id -u)")
  [ -n "${TMPDIR:-}" ] && sock_dirs+=("${TMPDIR}tmux-$(id -u)")
  for dir in "${sock_dirs[@]}"; do
    for sock in "$dir"/cp-live-*; do
      [ -S "$sock" ] || continue
      local name
      name=$(basename "$sock")
      tmux -L "$name" kill-server 2>/dev/null || true
      leaked=$((leaked + 1))
    done
  done
  [ "$leaked" -gt 0 ] && echo "Cleaned up $leaked leaked tmux server(s)" >&2
}
trap _emergency_cleanup EXIT

cat >&2 <<'EOF'
╔══════════════════════════════════════════════════════════╗
║  ⚠️  LIVE TESTS — Real Claude sessions, real tokens     ║
║                                                          ║
║  These tests call the Claude API. Each test creates an   ║
║  isolated temp directory and tmux server.                ║
║                                                          ║
║  Expect ~2-5 min per test file. No terminal output from  ║
║  Claude (sessions run in background tmux panes).         ║
╚══════════════════════════════════════════════════════════╝
EOF

# Check prerequisites
if ! command -v claude >/dev/null 2>&1; then
  echo "ERROR: claude CLI not found in PATH" >&2
  exit 1
fi

if ! command -v bats >/dev/null 2>&1; then
  echo "ERROR: bats not found in PATH" >&2
  exit 1
fi

# Run sequentially — live tests are slow and resource-heavy
if [ $# -gt 0 ]; then
  case "$1" in
    --filter)
      shift
      [ $# -gt 0 ] || { echo "ERROR: --filter requires a pattern argument" >&2; exit 1; }
      bats --filter "$1" ./*.bats
      ;;
    *)
      bats "$1".bats
      ;;
  esac
else
  bats ./*.bats
fi
