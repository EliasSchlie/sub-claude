# Integration test setup for claude-pool.
# Uses REAL tmux but a MOCK claude binary.
# Each test gets an isolated pool directory and tmux server.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
LIB_DIR="$REPO_ROOT/lib/claude-pool"
OUTPUT_LIB_DIR="$REPO_ROOT/lib/claude-output"
HELPERS_DIR="$(cd "$BATS_TEST_DIRNAME/../helpers" && pwd)"
MOCK_CLAUDE="$HELPERS_DIR/mock-claude.sh"

# How long to wait for tmux operations (seconds)
INTEG_TIMEOUT=30
# Default pool size for integration tests
INTEG_POOL_SIZE=2

_integ_setup() {
  # Ensure tmux is available
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  command -v jq >/dev/null 2>&1 || skip "jq not installed"

  # Create isolated test directory
  export TEST_DIR
  TEST_DIR="$(mktemp -d)"
  export POOL_DIR="$TEST_DIR/pool"
  export TMUX_SOCKET="test-cp-integ-$$-$RANDOM"
  mkdir -p "$POOL_DIR/slots" "$POOL_DIR/jobs" "$POOL_DIR/queue"

  # Isolate HOME so JSONL files go to the test directory, not the real HOME.
  export REAL_HOME="$HOME"
  export HOME="$TEST_DIR"
  mkdir -p "$HOME/.claude/projects"

  # Create a fake project directory
  export INTEG_PROJECT_DIR="$TEST_DIR/project"
  mkdir -p "$INTEG_PROJECT_DIR"

  # Compute the JSONL directory for mock-claude (same encoding as claude_jsonl_find)
  local encoded_project
  encoded_project=$(printf '%s' "$INTEG_PROJECT_DIR" | tr '/' '-')
  export INTEG_JSONL_DIR="$HOME/.claude/projects/$encoded_project"
  mkdir -p "$INTEG_JSONL_DIR"

  # Create a wrapper that uses mock-claude instead of real claude
  export MOCK_CLAUDE_BIN="$TEST_DIR/bin"
  mkdir -p "$MOCK_CLAUDE_BIN"
  cat > "$MOCK_CLAUDE_BIN/claude" <<MOCKEOF
#!/usr/bin/env bash
exec "$MOCK_CLAUDE" "\$@"
MOCKEOF
  chmod +x "$MOCK_CLAUDE_BIN/claude"

  # Put mock claude first in PATH
  export PATH="$MOCK_CLAUDE_BIN:$PATH"

  # Source output libraries (standalone, used by _emit_response for JSONL extraction)
  # shellcheck source=../../lib/claude-output/jsonl.sh
  source "$OUTPUT_LIB_DIR/jsonl.sh"
  # shellcheck source=../../lib/claude-output/parse.sh
  source "$OUTPUT_LIB_DIR/parse.sh"

  # Source all libs in dependency order
  # shellcheck source=../../lib/claude-pool/core.sh
  source "$LIB_DIR/core.sh"
  # shellcheck source=../../lib/claude-pool/tmux.sh
  source "$LIB_DIR/tmux.sh"
  # shellcheck source=../../lib/claude-pool/offload.sh
  source "$LIB_DIR/offload.sh"
  # shellcheck source=../../lib/claude-pool/queue.sh
  source "$LIB_DIR/queue.sh"
  # shellcheck source=../../lib/claude-pool/pool.sh
  source "$LIB_DIR/pool.sh"
  # shellcheck source=../../lib/claude-pool/session.sh
  source "$LIB_DIR/session.sh"

  # Override get_project_dir to use our test project
  # shellcheck disable=SC2329  # invoked indirectly after sourcing
  get_project_dir() { echo "$INTEG_PROJECT_DIR"; }
  # Override get_parent_session_id for deterministic isolation
  # shellcheck disable=SC2329
  get_parent_session_id() { echo "test-parent-$$"; }
  # Override derive_depth to always return 0 (no recursion in tests)
  # shellcheck disable=SC2329
  derive_depth() { echo "0"; }

  # Override write_slot_wrapper to use mock claude directly (not via PATH).
  # Tmux panes inherit a minimal environment, so the mock must be an absolute path.
  # shellcheck disable=SC2329
  write_slot_wrapper() {
    local slot="$1" pool_dir="$2" project_dir="$3"
    local slot_dir="$pool_dir/slots/$slot"
    local enc_proj
    enc_proj=$(printf '%s' "$project_dir" | tr '/' '-')
    local jsonl_dir="$HOME/.claude/projects/$enc_proj"
    mkdir -p "$slot_dir" "$jsonl_dir"
    cat > "$slot_dir/run.sh" <<RUNEOF
#!/usr/bin/env bash
export CLAUDE_POOL=1
export CLAUDE_POOL_SLOT=$slot
export CLAUDE_POOL_DONE_FILE="$slot_dir/done"
export CLAUDE_BELL_OFF=1
export MOCK_CLAUDE_JSONL_DIR="$jsonl_dir"
cd $(printf '%q' "$project_dir")
exec bash "$MOCK_CLAUDE"
RUNEOF
    chmod +x "$slot_dir/run.sh"
  }
}

_integ_teardown() {
  # Restore real HOME before cleanup
  [ -n "${REAL_HOME:-}" ] && export HOME="$REAL_HOME"

  # Kill tmux server for this test
  tmux -L "$TMUX_SOCKET" kill-server 2>/dev/null || true

  # Kill watcher if running (guard: never kill PID 0 — that kills the process group)
  if [ -f "$POOL_DIR/watcher.pid" ]; then
    local pid
    pid=$(cat "$POOL_DIR/watcher.pid" 2>/dev/null || true)
    [ -n "$pid" ] && [ "$pid" -gt 0 ] 2>/dev/null && kill "$pid" 2>/dev/null || true
  fi

  # Clean up test directory
  rm -rf "$TEST_DIR"
}

# _integ_init_pool [size] — initialize pool with mock claude, wait until ready.
_integ_init_pool() {
  local size="${1:-$INTEG_POOL_SIZE}"

  # Override watcher_start to not start watcher (tests control timing).
  # Write a non-existent PID (not 0!) — kill 0 would kill the process group.
  # shellcheck disable=SC2329
  watcher_start() { echo "99999999" > "$POOL_DIR/watcher.pid"; }

  pool_init --size "$size"

  # Verify all slots are fresh
  local slot_count
  slot_count=$(jq '.slots | length' "$POOL_DIR/pool.json")
  [ "$slot_count" -eq "$size" ]
}

# _integ_wait_for_slot_status <slot> <expected_status> [timeout]
_integ_wait_for_slot_status() {
  local slot="$1" expected="$2" timeout="${3:-$INTEG_TIMEOUT}"
  local elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    local actual
    actual=$(jq -r --argjson idx "$slot" \
      '.slots[] | select(.index == $idx) | .status' "$POOL_DIR/pool.json" 2>/dev/null)
    [ "$actual" = "$expected" ] && return 0
    sleep 1
    elapsed=$((elapsed + 1))
  done
  echo "Timeout waiting for slot $slot to reach status '$expected' (was '$actual')" >&2
  return 1
}

# _integ_wait_for_done_file <slot> [timeout] — wait for the done sentinel.
_integ_wait_for_done_file() {
  local slot="$1" timeout="${2:-$INTEG_TIMEOUT}"
  local done_file="$POOL_DIR/slots/$slot/done"
  local elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    [ -f "$done_file" ] && return 0
    sleep 0.5
    elapsed=$((elapsed + 1))
  done
  echo "Timeout waiting for done file on slot $slot" >&2
  return 1
}

# _integ_capture <slot> — capture pane output
_integ_capture() {
  capture_pane "$1"
}

# _integ_complete_job <job_id> <slot> — simulate watcher marking a job complete.
# Waits for done file, then marks the slot idle and job completed.
_integ_complete_job() {
  local job_id="$1" slot="$2"
  _integ_wait_for_done_file "$slot"
  with_pool_lock _locked_mark_job_completed_and_slot_idle "$job_id" "$slot"
}
