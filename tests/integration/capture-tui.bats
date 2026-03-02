#!/usr/bin/env bats
# Integration tests for capture on TUI sessions (alternate screen).
#
# These tests verify that capture returns meaningful content even when
# the Claude process uses the alternate screen buffer, which has no
# scrollback. This is the scenario described in issue #24.

load '../helpers/integration-setup'

setup() {
  _integ_setup

  # Override to use the TUI mock instead of the plain-text mock.
  export MOCK_CLAUDE="$HELPERS_DIR/mock-claude-tui.sh"

  # Also override write_slot_wrapper to use the TUI mock.
  # shellcheck disable=SC2329  # invoked indirectly after sourcing
  write_slot_wrapper() {
    local slot="$1" pool_dir="$2" project_dir="$3"
    local slot_dir="$pool_dir/slots/$slot"
    mkdir -p "$slot_dir"
    cat > "$slot_dir/run.sh" <<RUNEOF
#!/usr/bin/env bash
export SUB_CLAUDE=1
export SUB_CLAUDE_SLOT=$slot
export SUB_CLAUDE_DONE_FILE="$slot_dir/done"
export CLAUDE_BELL_OFF=1
export MOCK_TUI_LINES=200
cd $(printf '%q' "$project_dir")
exec bash "$MOCK_CLAUDE"
RUNEOF
    chmod +x "$slot_dir/run.sh"
  }
}

teardown() { _integ_teardown; }

# --- Core issue: capture on TUI with lots of output ---

@test "capture returns content beyond visible pane height for TUI sessions" {
  _integ_init_pool 1

  local id
  id=$(cmd_start "generate long output")

  # Wait for the mock to finish processing (it generates 200 lines)
  _integ_wait_for_done_file 0

  local output
  output=$(cmd_capture "$id")

  # The pane is 50 lines tall. The mock generates 200+ lines of output.
  # Without the fix, capture only returns ~50 visible lines.
  # With the fix (pane expansion), capture should return significantly more.
  local line_count
  line_count=$(printf '%s\n' "$output" | grep -c "RESPONSE LINE" || true)

  # We should get at least 100 response lines (out of 200).
  # Without the fix, we'd get at most ~45 (visible pane minus chrome).
  [ "$line_count" -gt 100 ]
}

@test "capture includes early output lines for TUI sessions" {
  _integ_init_pool 1

  local id
  id=$(cmd_start "test early content")

  _integ_wait_for_done_file 0

  local output
  output=$(cmd_capture "$id")

  # Early lines (like RESPONSE LINE 001) should be present in capture.
  # Without the fix, these scroll off the 50-line visible area.
  [[ "$output" == *"RESPONSE LINE 001"* ]]
}
