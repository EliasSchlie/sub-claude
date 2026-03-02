#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031
# Unit tests for config/lib/claude-pool/queue.sh

load '../helpers/setup'
load '../helpers/mocks'

# Write a minimal pool.json needed for all queue operations.
setup() {
  _common_setup
  echo '{"version":1,"pool_size":5,"queue_seq":0,"slots":[],"pins":{}}' | update_pool_json
}

teardown() { _common_teardown; }

# ---------------------------------------------------------------------------
# enqueue
# ---------------------------------------------------------------------------

@test "enqueue creates a queue file" {
  mkdir -p "$POOL_DIR/jobs/aabbccdd"
  echo '{"id":"aabbccdd","status":"pending"}' > "$POOL_DIR/jobs/aabbccdd/meta.json"
  result=$(enqueue "aabbccdd" "new" "test prompt")
  [ "$result" = "1" ]
  ls "$POOL_DIR/queue/"*aabbccdd*.json
}

@test "enqueue queue file contains valid JSON with job_id" {
  mkdir -p "$POOL_DIR/jobs/aabbccdd"
  echo '{"id":"aabbccdd","status":"pending"}' > "$POOL_DIR/jobs/aabbccdd/meta.json"
  enqueue "aabbccdd" "new" "test prompt"
  local qf
  qf=$(ls "$POOL_DIR/queue/"*aabbccdd*.json)
  jq -e '.job_id' "$qf"
}

@test "enqueue stores the prompt in queue file" {
  mkdir -p "$POOL_DIR/jobs/aabbccdd"
  echo '{"id":"aabbccdd","status":"pending"}' > "$POOL_DIR/jobs/aabbccdd/meta.json"
  enqueue "aabbccdd" "new" "my prompt text"
  local qf
  qf=$(ls "$POOL_DIR/queue/"*aabbccdd*.json)
  stored=$(jq -r '.prompt' "$qf")
  [ "$stored" = "my prompt text" ]
}

@test "enqueue sets job meta status to queued" {
  mkdir -p "$POOL_DIR/jobs/aabbccdd"
  echo '{"id":"aabbccdd","status":"pending"}' > "$POOL_DIR/jobs/aabbccdd/meta.json"
  enqueue "aabbccdd" "new" "test"
  status=$(jq -r '.status' "$POOL_DIR/jobs/aabbccdd/meta.json")
  [ "$status" = "queued" ]
}

@test "enqueue increments queue_seq for each call" {
  mkdir -p "$POOL_DIR/jobs/aabbccdd" "$POOL_DIR/jobs/11223344"
  echo '{"id":"aabbccdd","status":"pending"}' > "$POOL_DIR/jobs/aabbccdd/meta.json"
  echo '{"id":"11223344","status":"pending"}' > "$POOL_DIR/jobs/11223344/meta.json"
  enqueue "aabbccdd" "new" "first"
  result=$(enqueue "11223344" "new" "second")
  [ "$result" = "2" ]
  ls "$POOL_DIR/queue/"*11223344*.json
}

@test "enqueue for resume type stores claude_uuid" {
  mkdir -p "$POOL_DIR/jobs/aabbccdd"
  echo '{"id":"aabbccdd","status":"pending"}' > "$POOL_DIR/jobs/aabbccdd/meta.json"
  enqueue "aabbccdd" "resume" "follow-up" "my-uuid-here"
  local qf
  qf=$(ls "$POOL_DIR/queue/"*aabbccdd*.json)
  stored=$(jq -r '.claude_uuid' "$qf")
  [ "$stored" = "my-uuid-here" ]
}

@test "enqueue for new type stores null claude_uuid" {
  mkdir -p "$POOL_DIR/jobs/aabbccdd"
  echo '{"id":"aabbccdd","status":"pending"}' > "$POOL_DIR/jobs/aabbccdd/meta.json"
  enqueue "aabbccdd" "new" "prompt"
  local qf
  qf=$(ls "$POOL_DIR/queue/"*aabbccdd*.json)
  stored=$(jq -r '.claude_uuid' "$qf")
  [ "$stored" = "null" ]
}

# ---------------------------------------------------------------------------
# dequeue
# ---------------------------------------------------------------------------

@test "dequeue returns the first queue entry" {
  mkdir -p "$POOL_DIR/jobs/aabbccdd"
  echo '{"id":"aabbccdd","status":"pending"}' > "$POOL_DIR/jobs/aabbccdd/meta.json"
  enqueue "aabbccdd" "new" "first"
  entry=$(dequeue)
  job_id=$(printf '%s' "$entry" | jq -r '.job_id')
  [ "$job_id" = "aabbccdd" ]
}

@test "dequeue removes the file from queue" {
  mkdir -p "$POOL_DIR/jobs/aabbccdd"
  echo '{"id":"aabbccdd","status":"pending"}' > "$POOL_DIR/jobs/aabbccdd/meta.json"
  enqueue "aabbccdd" "new" "test"
  dequeue
  [ ! -f "$POOL_DIR/queue/001-aabbccdd.json" ]
}

@test "dequeue returns FIFO order" {
  mkdir -p "$POOL_DIR/jobs/aabbccdd" "$POOL_DIR/jobs/11223344"
  echo '{"id":"aabbccdd","status":"pending"}' > "$POOL_DIR/jobs/aabbccdd/meta.json"
  echo '{"id":"11223344","status":"pending"}' > "$POOL_DIR/jobs/11223344/meta.json"
  enqueue "aabbccdd" "new" "first"
  enqueue "11223344" "new" "second"

  first=$(dequeue)
  first_id=$(printf '%s' "$first" | jq -r '.job_id')
  [ "$first_id" = "aabbccdd" ]

  second=$(dequeue)
  second_id=$(printf '%s' "$second" | jq -r '.job_id')
  [ "$second_id" = "11223344" ]
}

@test "dequeue returns 1 on empty queue" {
  run dequeue
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# queue_length
# ---------------------------------------------------------------------------

@test "queue_length returns 0 for empty queue" {
  count=$(queue_length)
  [ "$count" -eq 0 ]
}

@test "queue_length counts one entry" {
  mkdir -p "$POOL_DIR/jobs/aabbccdd"
  echo '{"id":"aabbccdd","status":"pending"}' > "$POOL_DIR/jobs/aabbccdd/meta.json"
  enqueue "aabbccdd" "new" "test"
  count=$(queue_length)
  [ "$count" -eq 1 ]
}

@test "queue_length counts multiple entries" {
  mkdir -p "$POOL_DIR/jobs/aabbcc01" "$POOL_DIR/jobs/aabbcc02"
  echo '{"id":"aabbcc01","status":"p"}' > "$POOL_DIR/jobs/aabbcc01/meta.json"
  echo '{"id":"aabbcc02","status":"p"}' > "$POOL_DIR/jobs/aabbcc02/meta.json"
  enqueue "aabbcc01" "new" "a"
  enqueue "aabbcc02" "new" "b"
  count=$(queue_length)
  [ "$count" -eq 2 ]
}

@test "queue_length decreases after dequeue" {
  mkdir -p "$POOL_DIR/jobs/aabbccdd"
  echo '{"id":"aabbccdd","status":"pending"}' > "$POOL_DIR/jobs/aabbccdd/meta.json"
  enqueue "aabbccdd" "new" "test"
  dequeue
  count=$(queue_length)
  [ "$count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# queue_pressure
# ---------------------------------------------------------------------------

@test "queue_pressure detects high pressure (>= pool_size/2 rounded up)" {
  # pool_size=5, threshold=(5+1)/2=3
  mkdir -p "$POOL_DIR/jobs/aabbcc01" "$POOL_DIR/jobs/aabbcc02" "$POOL_DIR/jobs/aabbcc03"
  echo '{"id":"aabbcc01","status":"p"}' > "$POOL_DIR/jobs/aabbcc01/meta.json"
  echo '{"id":"aabbcc02","status":"p"}' > "$POOL_DIR/jobs/aabbcc02/meta.json"
  echo '{"id":"aabbcc03","status":"p"}' > "$POOL_DIR/jobs/aabbcc03/meta.json"
  enqueue "aabbcc01" "new" "a"
  enqueue "aabbcc02" "new" "b"
  enqueue "aabbcc03" "new" "c"
  run queue_pressure
  [ "$status" -eq 0 ]
  [[ "$output" == *"high queue pressure"* ]]
}

@test "queue_pressure reports no pressure below threshold" {
  mkdir -p "$POOL_DIR/jobs/aabbcc01"
  echo '{"id":"aabbcc01","status":"p"}' > "$POOL_DIR/jobs/aabbcc01/meta.json"
  enqueue "aabbcc01" "new" "a"
  run queue_pressure
  [ "$status" -eq 1 ]
}

@test "queue_pressure reports no pressure for empty queue" {
  run queue_pressure
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# cancel_job
# ---------------------------------------------------------------------------

@test "cancel_job removes the queue file" {
  mkdir -p "$POOL_DIR/jobs/aabbccdd"
  echo '{"id":"aabbccdd","status":"pending"}' > "$POOL_DIR/jobs/aabbccdd/meta.json"
  enqueue "aabbccdd" "new" "test"
  # Queue file created (6-digit padding)
  ls "$POOL_DIR/queue/"*aabbccdd*.json
  cancel_job "aabbccdd"
  # Queue file removed
  run ls "$POOL_DIR/queue/"*aabbccdd*.json 2>/dev/null
  [ "$status" -ne 0 ]
}

@test "cancel_job sets job status to cancelled" {
  mkdir -p "$POOL_DIR/jobs/aabbccdd"
  echo '{"id":"aabbccdd","status":"pending"}' > "$POOL_DIR/jobs/aabbccdd/meta.json"
  enqueue "aabbccdd" "new" "test"
  cancel_job "aabbccdd"
  status=$(jq -r '.status' "$POOL_DIR/jobs/aabbccdd/meta.json")
  [ "$status" = "cancelled" ]
}

@test "cancel_job fails for job not in queue" {
  run cancel_job "aabbccdd"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not in the queue"* ]]
}

# ---------------------------------------------------------------------------
# dispatch_queue — resume-type jobs
# ---------------------------------------------------------------------------

@test "dispatch_queue processes resume-type job into processing state" {
  # Pool with 1 fresh slot
  jq -n '{
    version: 1,
    pool_size: 1,
    queue_seq: 0,
    slots: [
      {"index":0,"status":"fresh","job_id":null,"claude_session_id":"uuid-orig","last_used_at":null}
    ],
    pins: {}
  }' | update_pool_json

  # An offloaded job that needs to be resumed
  mkdir -p "$POOL_DIR/jobs/aabbccdd"
  jq -n '{
    id: "aabbccdd",
    status: "queued",
    offloaded: true,
    slot: null,
    claude_session_id: "target-uuid-123",
    depth: 0,
    prompt: "resume me",
    parent_session: "standalone",
    parent_job_id: null,
    cwd: "/tmp",
    created_at: "2026-01-01T00:00:00Z"
  }' > "$POOL_DIR/jobs/aabbccdd/meta.json"

  # Enqueue as resume type
  enqueue "aabbccdd" "resume" "resume me" "target-uuid-123"

  # Dispatch should pick it up and mark it processing
  dispatch_queue

  # Job should be processing, NOT still queued
  local job_status
  job_status=$(jq -r '.status' "$POOL_DIR/jobs/aabbccdd/meta.json")
  [ "$job_status" = "processing" ]
}

@test "dispatch_queue empties queue after resume dispatch" {
  jq -n '{
    version: 1,
    pool_size: 1,
    queue_seq: 0,
    slots: [
      {"index":0,"status":"fresh","job_id":null,"claude_session_id":"uuid-orig","last_used_at":null}
    ],
    pins: {}
  }' | update_pool_json

  mkdir -p "$POOL_DIR/jobs/aabbccdd"
  jq -n '{
    id: "aabbccdd",
    status: "queued",
    offloaded: true,
    slot: null,
    claude_session_id: "target-uuid-123",
    depth: 0,
    prompt: "resume me",
    parent_session: "standalone",
    parent_job_id: null,
    cwd: "/tmp",
    created_at: "2026-01-01T00:00:00Z"
  }' > "$POOL_DIR/jobs/aabbccdd/meta.json"

  enqueue "aabbccdd" "resume" "resume me" "target-uuid-123"

  dispatch_queue

  # Queue should be empty after successful dispatch
  local remaining
  remaining=$(queue_length)
  [ "$remaining" -eq 0 ]
}

@test "dispatch_queue sets slot to busy with resumed job" {
  jq -n '{
    version: 1,
    pool_size: 1,
    queue_seq: 0,
    slots: [
      {"index":0,"status":"fresh","job_id":null,"claude_session_id":"uuid-orig","last_used_at":null}
    ],
    pins: {}
  }' | update_pool_json

  mkdir -p "$POOL_DIR/jobs/aabbccdd"
  jq -n '{
    id: "aabbccdd",
    status: "queued",
    offloaded: true,
    slot: null,
    claude_session_id: "target-uuid-123",
    depth: 0,
    prompt: "resume me",
    parent_session: "standalone",
    parent_job_id: null,
    cwd: "/tmp",
    created_at: "2026-01-01T00:00:00Z"
  }' > "$POOL_DIR/jobs/aabbccdd/meta.json"

  enqueue "aabbccdd" "resume" "resume me" "target-uuid-123"

  dispatch_queue

  # Slot should be busy with the resumed job
  local slot_status slot_jid
  slot_status=$(read_pool_json | jq -r '.slots[0].status')
  slot_jid=$(read_pool_json | jq -r '.slots[0].job_id')
  [ "$slot_status" = "busy" ]
  [ "$slot_jid" = "aabbccdd" ]
}

