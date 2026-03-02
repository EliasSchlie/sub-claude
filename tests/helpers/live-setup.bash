# Live test setup for sub-claude.
# Uses REAL claude binary — no mocking. Each test burns actual tokens.
# Each test gets an isolated temporary project directory and pool.
#
# WARNING: These tests call the real Claude API and consume tokens.
# Run only when you explicitly want end-to-end validation.
#
# Prerequisites:
#   - claude CLI in PATH and authenticated
#   - tmux installed
#   - jq installed

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
LIB_DIR="$REPO_ROOT/lib/sub-claude"

# Timeouts (real Claude is slower than mocks)
LIVE_TIMEOUT=120
LIVE_POLL_INTERVAL=2
LIVE_POOL_SIZE=2

_live_setup() {
  # Check prerequisites
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  command -v jq >/dev/null 2>&1 || skip "jq not installed"
  command -v claude >/dev/null 2>&1 || skip "claude CLI not in PATH"

  # Create isolated project directory (avoids interfering with real pools)
  export TEST_DIR
  TEST_DIR="$(mktemp -d)"
  export INTEG_PROJECT_DIR="$TEST_DIR/project"
  mkdir -p "$INTEG_PROJECT_DIR"

  # Resolve pool dir for this project
  export POOL_DIR="$TEST_DIR/pool"
  # Use mktemp for guaranteed unique socket name (avoids PID/RANDOM collisions)
  export TMUX_SOCKET
  TMUX_SOCKET="cp-live-$(basename "$(mktemp -u -t cp-XXXXXXXX)")"
  mkdir -p "$POOL_DIR/slots" "$POOL_DIR/jobs" "$POOL_DIR/queue"

  # Source all libs in dependency order
  # shellcheck source=../../lib/sub-claude/core.sh
  source "$LIB_DIR/core.sh"
  # shellcheck source=../../lib/sub-claude/tmux.sh
  source "$LIB_DIR/tmux.sh"
  # shellcheck source=../../lib/sub-claude/offload.sh
  source "$LIB_DIR/offload.sh"
  # shellcheck source=../../lib/sub-claude/queue.sh
  source "$LIB_DIR/queue.sh"
  # shellcheck source=../../lib/sub-claude/pool.sh
  source "$LIB_DIR/pool.sh"
  # shellcheck source=../../lib/sub-claude/session.sh
  source "$LIB_DIR/session.sh"

  # Override get_project_dir to use our isolated test project
  # shellcheck disable=SC2329
  get_project_dir() { echo "$INTEG_PROJECT_DIR"; }
  # Override get_parent_session_id for deterministic isolation
  # shellcheck disable=SC2329
  get_parent_session_id() { echo "live-test-parent-$$"; }
  # Override derive_depth to always return 0
  # shellcheck disable=SC2329
  derive_depth() { echo "0"; }

  # Create a CLAUDE.md that constrains Claude for fast, cheap test runs
  cat > "$INTEG_PROJECT_DIR/CLAUDE.md" <<'EOF'
# Test Project — Automated Testing

CRITICAL: You are in an automated test harness. Follow these rules exactly:
- NEVER use tools. NEVER read files. NEVER write files. NEVER run commands.
- Respond in 1-2 sentences only. Be as terse as possible.
- When asked to "say exactly" something, reply with ONLY that text.
- This is a temporary project. There is no real work to do.
EOF
}

_live_teardown() {
  # Kill all claude processes in our tmux panes before destroying the server.
  # Prevents orphaned Claude processes from burning tokens after test failure.
  if tmux -L "$TMUX_SOCKET" has-session 2>/dev/null; then
    local pids
    pids=$(tmux -L "$TMUX_SOCKET" list-panes -a -F '#{pane_pid}' 2>/dev/null || true)
    for p in $pids; do
      kill "$p" 2>/dev/null || true
    done
    sleep 1
    # SIGKILL stragglers
    for p in $pids; do
      kill -9 "$p" 2>/dev/null || true
    done
  fi

  # Kill tmux server
  tmux -L "$TMUX_SOCKET" kill-server 2>/dev/null || true

  # Kill watcher if running
  if [ -f "$POOL_DIR/watcher.pid" ]; then
    local pid
    pid=$(cat "$POOL_DIR/watcher.pid" 2>/dev/null || true)
    { [ -n "$pid" ] && [ "$pid" -gt 0 ] 2>/dev/null && kill "$pid" 2>/dev/null; } || true
  fi

  # Clean up test directory
  rm -rf "$TEST_DIR"
}

# _live_init_pool [size] — initialize pool with real claude, wait until ready.
_live_init_pool() {
  local size="${1:-$LIVE_POOL_SIZE}"
  pool_init --size "$size"
}

# _live_wait_for_status <job_id> <expected_status> [timeout]
# Poll job status until it matches expected (exact match), or timeout.
_live_wait_for_status() {
  local job_id="$1" expected="$2" timeout="${3:-$LIVE_TIMEOUT}"
  local elapsed=0 actual=""
  while [ "$elapsed" -lt "$timeout" ]; do
    actual=$(get_job_status "$job_id" 2>/dev/null) || true
    [ "$actual" = "$expected" ] && return 0
    sleep "$LIVE_POLL_INTERVAL"
    elapsed=$((elapsed + LIVE_POLL_INTERVAL))
  done
  echo "Timeout: job $job_id did not reach '$expected' within ${timeout}s (was '$actual')" >&2
  return 1
}

# _live_wait_for_done <slot> [timeout]
# Wait for the done sentinel file to appear on a slot.
_live_wait_for_done() {
  local slot="$1" timeout="${2:-$LIVE_TIMEOUT}"
  local done_file="$POOL_DIR/slots/$slot/done"
  local elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    [ -f "$done_file" ] && return 0
    sleep 1
    elapsed=$((elapsed + 1))
  done
  echo "Timeout: done file for slot $slot did not appear within ${timeout}s" >&2
  return 1
}

# _live_wait_for_slot_status <slot> <expected_status> [timeout]
_live_wait_for_slot_status() {
  local slot="$1" expected="$2" timeout="${3:-$LIVE_TIMEOUT}"
  local elapsed=0 actual=""
  while [ "$elapsed" -lt "$timeout" ]; do
    actual=$(jq -r --argjson idx "$slot" \
      '.slots[] | select(.index == $idx) | .status' "$POOL_DIR/pool.json" 2>/dev/null)
    [ "$actual" = "$expected" ] && return 0
    sleep "$LIVE_POLL_INTERVAL"
    elapsed=$((elapsed + LIVE_POLL_INTERVAL))
  done
  echo "Timeout: slot $slot did not reach '$expected' within ${timeout}s (was '$actual')" >&2
  return 1
}

# _live_wait_finished <job_id> [timeout]
# Wait until job reaches any finished state (prefix match on "finished").
_live_wait_finished() {
  local job_id="$1" timeout="${2:-$LIVE_TIMEOUT}"
  local elapsed=0 actual=""
  while [ "$elapsed" -lt "$timeout" ]; do
    actual=$(get_job_status "$job_id" 2>/dev/null) || true
    case "$actual" in
      finished*) return 0 ;;
    esac
    sleep "$LIVE_POLL_INTERVAL"
    elapsed=$((elapsed + LIVE_POLL_INTERVAL))
  done
  echo "Timeout: job $job_id did not finish within ${timeout}s (status: $actual)" >&2
  return 1
}

# _live_wait_for_output <slot> [timeout]
# Wait for the pane to produce any output (raw.log has content).
_live_wait_for_output() {
  local slot="$1" timeout="${2:-30}"
  local raw_log="$POOL_DIR/slots/$slot/raw.log"
  local elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    local sz
    sz=$(wc -c < "$raw_log" 2>/dev/null | tr -d ' ')
    [ "${sz:-0}" -gt 0 ] && return 0
    sleep 1
    elapsed=$((elapsed + 1))
  done
  return 1
}
