#!/usr/bin/env bats
# Integration tests for JSONL-based output extraction.
# Verifies that _emit_output / _emit_response correctly extracts responses
# from JSONL transcripts for: first start, follow-ups, and new sessions.

load '../helpers/integration-setup'

setup()    { _integ_setup; }
teardown() { _integ_teardown; }

# --- Helpers ---

# _get_job_uuid <job_id> — read claude_session_id from meta.json
_get_job_uuid() {
  jq -r '.claude_session_id // empty' "$POOL_DIR/jobs/$1/meta.json"
}

# _get_slot_uuid <slot> — read claude_session_id from pool.json
_get_slot_uuid() {
  jq -r --argjson idx "$1" '.slots[] | select(.index == $idx) | .claude_session_id // empty' "$POOL_DIR/pool.json"
}

# _assert_jsonl_output <output> — verify output is JSONL-extracted (no terminal chrome)
_assert_jsonl_output() {
  local output="$1"
  # JSONL output should contain the response text
  [[ "$output" == *"Result: completed task"* ]] || {
    echo "Expected JSONL output with 'Result: completed task', got: $output" >&2
    return 1
  }
  # JSONL output should NOT contain terminal chrome
  [[ "$output" != *"Claude Code ready"* ]] || {
    echo "Output contains terminal chrome 'Claude Code ready' — JSONL extraction failed, fell back to terminal capture" >&2
    return 1
  }
  [[ "$output" != *"Do you trust"* ]] || {
    echo "Output contains terminal chrome 'Do you trust' — JSONL extraction failed" >&2
    return 1
  }
}

# --- Tests ---

@test "JSONL: first start extracts response from JSONL" {
  _integ_init_pool 1

  local id
  id=$(cmd_start "hello world")

  # Wait for mock-claude to process and write JSONL
  _integ_complete_job "$id" 0

  # Verify UUID is set in meta.json
  local uuid
  uuid=$(_get_job_uuid "$id")
  [ -n "$uuid" ] || {
    echo "claude_session_id not set in meta.json" >&2
    false
  }

  # Verify JSONL file exists
  claude_jsonl_find "$uuid" "$INTEG_PROJECT_DIR" >/dev/null || {
    echo "JSONL file not found for uuid=$uuid project=$INTEG_PROJECT_DIR" >&2
    # Debug: list what's in the JSONL directory
    echo "JSONL dir contents:" >&2
    ls -la "$INTEG_JSONL_DIR/" >&2 || true
    echo "meta.json:" >&2
    cat "$POOL_DIR/jobs/$id/meta.json" >&2
    false
  }

  # Get result — should use JSONL extraction
  local output
  output=$(cmd_result "$id")
  _assert_jsonl_output "$output"
}

@test "JSONL: follow-up on idle session extracts from JSONL" {
  _integ_init_pool 1

  # Start initial session
  local id
  id=$(cmd_start "initial question")
  _integ_complete_job "$id" 0

  # Clear done file so follow-up can re-trigger
  rm -f "$POOL_DIR/slots/0/done"

  # Send follow-up
  local fid
  fid=$(cmd_followup "$id" "follow-up question")
  [ "$fid" = "$id" ]

  # Wait for follow-up to complete
  _integ_complete_job "$id" 0

  # Get result — should use JSONL extraction with the latest response
  local output
  output=$(cmd_result "$id")
  _assert_jsonl_output "$output"
  [[ "$output" == *"follow-up question"* ]] || {
    echo "Expected follow-up response text, got: $output" >&2
    false
  }
}

@test "JSONL: new start after offload extracts from JSONL" {
  _integ_init_pool 1

  # Start first session
  local id1
  id1=$(cmd_start "first task")
  _integ_complete_job "$id1" 0

  # Start second session — offloads first, creates new session
  local id2
  id2=$(cmd_start "second task")

  # Get the new slot assignment
  local slot2
  slot2=$(get_slot_for_job "$id2")
  [ -n "$slot2" ] || {
    echo "second job not assigned to a slot" >&2
    false
  }

  _integ_complete_job "$id2" "$slot2"

  # Verify UUID is set for the new job
  local uuid2
  uuid2=$(_get_job_uuid "$id2")
  [ -n "$uuid2" ] || {
    echo "claude_session_id not set for second job" >&2
    false
  }

  # Get result — should use JSONL extraction
  local output
  output=$(cmd_result "$id2")
  _assert_jsonl_output "$output"
  [[ "$output" == *"second task"* ]]
}

@test "JSONL: UUID propagated to meta.json on start" {
  _integ_init_pool 1

  local id
  id=$(cmd_start "test uuid propagation")

  # UUID should be in pool.json for the slot
  local slot_uuid
  slot_uuid=$(_get_slot_uuid 0)
  [ -n "$slot_uuid" ]

  # UUID should also be in job's meta.json
  local job_uuid
  job_uuid=$(_get_job_uuid "$id")
  [ -n "$job_uuid" ]

  # They should match
  [ "$slot_uuid" = "$job_uuid" ] || {
    echo "UUID mismatch: slot=$slot_uuid job=$job_uuid" >&2
    false
  }
}

@test "JSONL: extraction works when meta.json cwd diverges from pool.json project_dir" {
  # Regression test: on macOS, /tmp → /private/tmp causes cwd in meta.json
  # to differ from the resolved project_dir. JSONL lookup must use pool.json's
  # project_dir, not meta.json's cwd.
  _integ_init_pool 1

  local id
  id=$(cmd_start "symlink regression test")
  _integ_complete_job "$id" 0

  # Corrupt meta.json cwd to simulate the symlink divergence
  local meta="$POOL_DIR/jobs/$id/meta.json"
  local tmp_meta="$meta.tmp"
  jq '.cwd = "/some/wrong/symlinked/path"' "$meta" > "$tmp_meta" && mv "$tmp_meta" "$meta"

  # Result should still succeed because _emit_response uses pool.json's project_dir
  local output
  output=$(cmd_result "$id")
  _assert_jsonl_output "$output"
}

@test "JSONL: UUID preserved across follow-up" {
  _integ_init_pool 1

  local id
  id=$(cmd_start "original")
  _integ_complete_job "$id" 0

  local uuid_before
  uuid_before=$(_get_job_uuid "$id")
  [ -n "$uuid_before" ]

  # Clear done file
  rm -f "$POOL_DIR/slots/0/done"

  # Follow up
  cmd_followup "$id" "more" >/dev/null
  _integ_complete_job "$id" 0

  # UUID should be unchanged
  local uuid_after
  uuid_after=$(_get_job_uuid "$id")
  [ "$uuid_before" = "$uuid_after" ] || {
    echo "UUID changed after follow-up: before=$uuid_before after=$uuid_after" >&2
    false
  }
}
