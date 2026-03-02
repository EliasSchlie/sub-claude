# shellcheck disable=SC2317
# Mock helpers for tmux and claude operations.
# Override functions so tests don't need a real tmux server or claude binary.
# Source this after setup.bash in each test file's setup().

# Core tmux wrapper — no-op
tmux_cmd() { return 0; }

# Key / text sending
send_keys()        { return 0; }
send_special_key() { return 0; }
send_prompt()      { return 0; }

# Pane capture — return predictable output
capture_pane()        { echo "mock pane output"; }
capture_pane_recent() { echo "mock recent output"; }

# Pane liveness — always alive
is_pane_alive() { return 0; }

# UUID extraction — return a fixed UUID
extract_uuid() { echo "550e8400-e29b-41d4-a716-446655440000"; }

# Trust / session lifecycle
accept_trust_prompt() { return 0; }
init_tmux_server()    { return 0; }
create_slot_pane()    { return 0; }

# Slot wrapper — create the minimal directory structure expected by pool code
write_slot_wrapper() {
  local slot="$1"
  mkdir -p "$POOL_DIR/slots/$slot"
  touch "$POOL_DIR/slots/$slot/run.sh"
}

# Conversation commands
send_slash_clear()  { return 0; }
send_slash_resume() { echo "1"; return 0; }

# Output logging
setup_pipe_pane() { return 0; }

# Completion
wait_for_done() { return 0; }

# Watcher
watcher_start() { return 0; }
