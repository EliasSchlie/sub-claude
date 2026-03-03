#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031,SC2329
# Unit tests for:
#   - _derive_parent_job_id: resolves the caller's active job
#   - cmd_list --tree: shows ALL jobs as a tree with proper nesting

load '../helpers/setup'
load '../helpers/mocks'

setup()    { _common_setup;    }
teardown() { _common_teardown; }

# ---------------------------------------------------------------------------
# Helper: create a job meta.json with given fields
# ---------------------------------------------------------------------------
_create_job() {
  local id="$1" status="$2" parent_session="${3:-standalone}" parent_job_id="${4:-}"
  local prompt="${5:-test prompt}"
  mkdir -p "$POOL_DIR/jobs/$id"
  local pjid_json="null"
  [ -z "$parent_job_id" ] || pjid_json="\"$parent_job_id\""
  cat > "$POOL_DIR/jobs/$id/meta.json" <<EOF
{
  "id": "$id",
  "prompt": "$prompt",
  "parent_session": "$parent_session",
  "parent_job_id": $pjid_json,
  "cwd": "/tmp",
  "created_at": "2025-01-01T00:00:00Z",
  "status": "$status",
  "slot": null,
  "claude_session_id": null,
  "offloaded": false,
  "depth": 0
}
EOF
}

# ---------------------------------------------------------------------------
# _derive_parent_job_id
# ---------------------------------------------------------------------------

@test "_derive_parent_job_id returns empty for standalone" {
  run _derive_parent_job_id "standalone"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_derive_parent_job_id returns empty when no jobs dir" {
  rm -rf "$POOL_DIR/jobs"
  run _derive_parent_job_id "session-123"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_derive_parent_job_id returns empty when no matching processing job" {
  _create_job "job-a" "completed" "session-123"
  _create_job "job-b" "queued" "session-123"
  run _derive_parent_job_id "session-123"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_derive_parent_job_id finds processing job matching parent_session" {
  _create_job "job-a" "completed" "session-123"
  _create_job "job-b" "processing" "session-123"
  _create_job "job-c" "processing" "session-other"
  run _derive_parent_job_id "session-123"
  [ "$status" -eq 0 ]
  [ "$output" = "job-b" ]
}

# ---------------------------------------------------------------------------
# _derive_parent_job_id — SUB_CLAUDE_SLOT fast path
# ---------------------------------------------------------------------------

@test "_derive_parent_job_id uses SUB_CLAUDE_SLOT when set" {
  # Create pool.json with a slot pointing to a job
  jq -n '{version:1, slots:[{index:0, status:"busy", job_id:"slot-job-1"}]}' \
    > "$POOL_DIR/pool.json"
  _create_job "slot-job-1" "processing" "session-abc"

  SUB_CLAUDE_SLOT=0 run _derive_parent_job_id "standalone"
  [ "$status" -eq 0 ]
  [ "$output" = "slot-job-1" ]
}

@test "_derive_parent_job_id SUB_CLAUDE_SLOT takes priority over fallback" {
  # Slot points to slot-job, but there's also a session-matching job
  jq -n '{version:1, slots:[{index:1, status:"busy", job_id:"slot-job-2"}]}' \
    > "$POOL_DIR/pool.json"
  _create_job "slot-job-2" "processing" "session-x"
  _create_job "fallback-job" "processing" "session-x"

  SUB_CLAUDE_SLOT=1 run _derive_parent_job_id "session-x"
  [ "$status" -eq 0 ]
  [ "$output" = "slot-job-2" ]
}

@test "_derive_parent_job_id falls back when SUB_CLAUDE_SLOT has no job" {
  # Slot exists but has no job_id assigned
  jq -n '{version:1, slots:[{index:0, status:"idle", job_id:null}]}' \
    > "$POOL_DIR/pool.json"
  _create_job "fallback-job" "processing" "session-y"

  SUB_CLAUDE_SLOT=0 run _derive_parent_job_id "session-y"
  [ "$status" -eq 0 ]
  [ "$output" = "fallback-job" ]
}

# ---------------------------------------------------------------------------
# cmd_list --tree
# ---------------------------------------------------------------------------

@test "cmd_list --tree shows flat list of root jobs" {
  echo '{"version":1}' > "$POOL_DIR/pool.json"
  _create_job "aaa" "processing" "standalone" "" "do thing A"
  _create_job "bbb" "completed" "standalone" "" "do thing B"

  run cmd_list --tree
  [ "$status" -eq 0 ]
  # Both jobs appear, no tree connectors at root when only roots exist
  [[ "$output" == *"aaa"* ]]
  [[ "$output" == *"bbb"* ]]
}

@test "cmd_list --tree nests children under parent jobs" {
  echo '{"version":1}' > "$POOL_DIR/pool.json"
  _create_job "root1" "processing" "standalone" "" "root task"
  _create_job "child1" "processing" "sess-1" "root1" "child task"
  _create_job "child2" "completed" "sess-1" "root1" "another child"

  run cmd_list --tree
  [ "$status" -eq 0 ]

  # Root appears without connector, children use tree chars.
  # Glob order is alphabetical: child1 = ├─ (not last), child2 = └─ (last).
  local root_line child1_line child2_line
  root_line=$(echo "$output" | grep "root1")
  child1_line=$(echo "$output" | grep "child1")
  child2_line=$(echo "$output" | grep "child2")
  [[ "$root_line" != *"├─"* ]] && [[ "$root_line" != *"└─"* ]]
  [[ "$child1_line" == *"├─ child1"* ]]
  [[ "$child2_line" == *"└─ child2"* ]]
}

@test "cmd_list --tree shows grandchildren with deeper nesting" {
  echo '{"version":1}' > "$POOL_DIR/pool.json"
  _create_job "root1" "processing" "standalone" "" "root"
  _create_job "child1" "processing" "sess-1" "root1" "child"
  _create_job "grand1" "processing" "sess-2" "child1" "grandchild"

  run cmd_list --tree
  [ "$status" -eq 0 ]

  # All three levels appear
  [[ "$output" == *"root1"* ]]
  [[ "$output" == *"child1"* ]]
  [[ "$output" == *"grand1"* ]]

  # Grandchild line should have deeper indentation than child
  local child_line grand_line
  child_line=$(echo "$output" | grep "child1")
  grand_line=$(echo "$output" | grep "grand1")
  # grand_line should be longer (more indentation) than child_line's prefix
  [ "${#grand_line}" -gt "${#child_line}" ]
}

@test "cmd_list --tree returns 0 with no output when pool is empty" {
  echo '{"version":1}' > "$POOL_DIR/pool.json"
  run cmd_list --tree
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "cmd_list --tree shows all jobs regardless of caller session" {
  echo '{"version":1}' > "$POOL_DIR/pool.json"

  # Jobs spawned from different sessions
  _create_job "job-from-a" "processing" "session-A" "" "task A"
  _create_job "job-from-b" "completed" "session-B" "" "task B"
  _create_job "job-from-c" "processing" "session-C" "" "task C"

  run cmd_list --tree
  [ "$status" -eq 0 ]

  # All jobs appear regardless of which session we're calling from
  [[ "$output" == *"job-from-a"* ]]
  [[ "$output" == *"job-from-b"* ]]
  [[ "$output" == *"job-from-c"* ]]
}

@test "cmd_list (flat, no flags) only shows direct children" {
  echo '{"version":1}' > "$POOL_DIR/pool.json"

  # Override get_parent_session_id to return a known value
  get_parent_session_id() { echo "my-session"; }

  _create_job "mine" "processing" "my-session" "" "my task"
  _create_job "other" "completed" "other-session" "" "other task"

  run cmd_list
  [ "$status" -eq 0 ]
  [[ "$output" == *"mine"* ]]
  [[ "$output" != *"other"* ]]
}
