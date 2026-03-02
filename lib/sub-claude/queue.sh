# shellcheck shell=bash
# =============================================================================
# sub-claude: queue.sh — FIFO queue management
# =============================================================================
# Sourced after core.sh, tmux.sh, and offload.sh.
# Do NOT add a shebang — this file is sourced, never executed directly.
#
# Queue entries live in $POOL_DIR/queue/ as JSON files named NNNNNN-<job_id>.json
# where NNNNNN is a zero-padded 6-digit counter from pool.json's queue_seq field.
# FIFO ordering is guaranteed by lexicographic sort of the filenames.
#
# Provides:
#   - enqueue          — add a job to the queue
#   - dequeue          — pop and return the next queue entry
#   - queue_length     — count pending entries
#   - queue_pressure   — detect high queue pressure
#   - dispatch_queue   — called by watcher loop to drain queue into slots
#   - cancel_job       — remove a queued job by job_id

# ---------------------------------------------------------------------------
# enqueue <job_id> <type> <prompt> [<claude_uuid>]
# ---------------------------------------------------------------------------
# Add a job to the FIFO queue.
#
# Steps:
#   1. Under lock: increment queue_seq in pool.json, capture the new value.
#   2. Write the queue entry JSON file: $POOL_DIR/queue/<NNN>-<job_id>.json
#   3. Update job meta.json status to "queued".
#   4. Log the enqueue event.
#   5. Print the queue position (the sequence number) to stdout.
#
# The claude_uuid argument is only meaningful for type="resume" jobs; for
# type="new" it should be omitted or left blank.
enqueue() {
  local job_id="$1"
  local type="$2"
  local prompt="$3"
  local claude_uuid="${4:-}"

  # Step 1: Increment queue_seq under lock and capture the new value.
  local seq
  seq=$(with_pool_lock _locked_increment_queue_seq)

  # Zero-pad to 6 digits for correct lexicographic ordering.
  local seq_padded
  seq_padded=$(printf '%06d' "$seq")

  local queue_file="$POOL_DIR/queue/${seq_padded}-${job_id}.json"
  local queued_at
  queued_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Step 2: Write the queue entry file.
  # Include claude_uuid only for resume-type jobs (null otherwise).
  if [ "$type" = "resume" ] && [ -n "$claude_uuid" ]; then
    jq -n \
      --arg job_id    "$job_id" \
      --arg type      "$type" \
      --arg prompt    "$prompt" \
      --arg uuid      "$claude_uuid" \
      --arg queued_at "$queued_at" \
      '{job_id: $job_id, type: $type, prompt: $prompt, claude_uuid: $uuid, queued_at: $queued_at}' \
      > "$queue_file"
  else
    jq -n \
      --arg job_id    "$job_id" \
      --arg type      "$type" \
      --arg prompt    "$prompt" \
      --arg queued_at "$queued_at" \
      '{job_id: $job_id, type: $type, prompt: $prompt, claude_uuid: null, queued_at: $queued_at}' \
      > "$queue_file"
  fi

  # Step 3: Update job metadata status to "queued".
  with_pool_lock _locked_mark_job_queued "$job_id"

  # Step 4: Log.
  pool_log "queue" "enqueued $job_id (type=$type)"

  # Step 5: Return the queue position (sequence number).
  printf '%d\n' "$seq"
}

# ---------------------------------------------------------------------------
# dequeue
# ---------------------------------------------------------------------------
# Remove and return the next queue entry (FIFO).
#
# Prints the full JSON of the first queue entry to stdout.
# Returns 1 if the queue is empty (prints nothing).
dequeue() {
  local queue_dir="$POOL_DIR/queue"

  # Find the lexicographically first file in the queue directory.
  local first_file=""
  for f in "$queue_dir"/[0-9]*-*.json; do
    [ -f "$f" ] || break
    first_file="$f"
    break
  done

  [ -z "$first_file" ] && return 1

  # Atomic claim via rename — prevents double-dispatch if two callers race.
  local claim="$first_file.claimed.$$"
  mv "$first_file" "$claim" 2>/dev/null || return 1

  local entry
  entry=$(cat "$claim")
  rm -f "$claim"

  printf '%s\n' "$entry"
}

# ---------------------------------------------------------------------------
# queue_length
# ---------------------------------------------------------------------------
# Count files currently in the queue directory.
# Prints the count to stdout.
queue_length() {
  local queue_dir="$POOL_DIR/queue"
  local count=0

  for f in "$queue_dir"/[0-9]*-*.json; do
    [ -f "$f" ] || break
    count=$((count + 1))
  done

  printf '%d\n' "$count"
}

# ---------------------------------------------------------------------------
# queue_pressure
# ---------------------------------------------------------------------------
# Returns 0 (pressure detected) if queue length >= threshold.
# Returns 1 if pressure is not detected.
# Prints a warning message to stderr when under pressure.
#
# Threshold is configurable via pool.json's pressure_threshold field
# (set at pool init with --pressure-threshold N). 0 = auto: (pool_size+1)/2.
queue_pressure() {
  local count
  count=$(queue_length)

  local pool_json pool_size configured_threshold
  pool_json=$(read_pool_json)
  pool_size=$(printf '%s' "$pool_json" | jq -r '.pool_size // 1')
  configured_threshold=$(printf '%s' "$pool_json" | jq -r '.pressure_threshold // 0')

  local threshold
  if [ "$configured_threshold" -gt 0 ] 2>/dev/null; then
    threshold="$configured_threshold"
  else
    # Default: (pool_size + 1) / 2 rounds up for odd pool sizes
    # (e.g. pool=5 → pressure at 3).
    threshold=$(( (pool_size + 1) / 2 ))
  fi

  if [ "$count" -ge "$threshold" ]; then
    warn "high queue pressure ($count queued, threshold $threshold, pool size $pool_size) — not blocking"
    warn "hint: expand pool with 'sub-claude pool resize N' or wait explicitly with 'sub-claude wait <id> --quiet'"
    return 0
  fi

  return 1
}

# ---------------------------------------------------------------------------
# dispatch_queue
# ---------------------------------------------------------------------------
# Called by the watcher loop. Drains the queue into available slots.
#
# For each entry dequeued:
#   - Allocate a free slot (fresh preferred over LRU idle).
#   - Prepare the slot (offload → /clear → /status for new, or /resume for resume).
#   - Remove the done sentinel so the next job starts clean.
#   - Update slot and job state under lock.
#   - Send the prompt (outside lock — tmux ops take time).
#
# Stops when either no slots are available or the queue is empty.
dispatch_queue() {
  # Early exit if queue is empty.
  local count
  count=$(queue_length)
  [ "$count" -gt 0 ] || return 0

  # Try to dispatch entries one at a time.
  while true; do
    # Try to allocate a slot. allocate_slot prints the slot index or fails.
    local slot
    slot=$(allocate_slot) || break  # no slots available

    # Dequeue next entry.
    local entry
    entry=$(dequeue) || break  # queue empty

    local job_id type prompt claude_uuid
    job_id=$(printf '%s' "$entry" | jq -r '.job_id')
    type=$(printf '%s' "$entry" | jq -r '.type')
    prompt=$(printf '%s' "$entry" | jq -r '.prompt')
    claude_uuid=$(printf '%s' "$entry" | jq -r '.claude_uuid // empty')

    # Guard: skip jobs that were cancelled between enqueue and dispatch
    local meta_status
    meta_status=$(jq -r '.status // empty' "$POOL_DIR/jobs/$job_id/meta.json" 2>/dev/null)
    if [ "$meta_status" = "cancelled" ]; then
      pool_log "watcher" "queue: skipping cancelled job $job_id"
      continue
    fi

    pool_log "watcher" "queue: dispatching $job_id to slot-$slot (type=$type)"

    # Prepare the slot depending on job type.
    if [ "$type" = "resume" ] && [ -n "$claude_uuid" ]; then
      # Resume an existing offloaded session.
      prepare_slot_for_resume "$slot" "$claude_uuid" "$job_id"
    else
      # New conversation — offload any existing session and /clear.
      prepare_slot_for_new "$slot"
    fi

    # Atomically verify slot + claim + mark job processing.
    # If the slot was stolen (e.g., by a concurrent cmd_start), re-enqueue.
    if ! with_pool_lock _locked_claim_and_dispatch "$slot" "$job_id"; then
      pool_log "watcher" "queue: slot-$slot stolen, re-enqueueing $job_id"
      enqueue "$job_id" "$type" "$prompt" "$claude_uuid"
      continue
    fi

    # Done sentinel is now cleared inside _locked_claim_and_dispatch (under
    # the lock) to prevent the watcher from seeing a stale done file.

    # Record the raw.log byte offset so capture_raw_log can isolate this
    # job's output from previous jobs on the same slot.
    local raw_log_offset=0
    local raw_log
    raw_log=$(_slot_raw_log "$slot")
    if [ -f "$raw_log" ]; then
      raw_log_offset=$(wc -c < "$raw_log" | tr -d ' ')
    fi
    mkdir -p "$POOL_DIR/jobs/$job_id"
    printf '%s' "$raw_log_offset" > "$POOL_DIR/jobs/$job_id/raw_offset"

    # Send the prompt outside the lock — tmux ops can take seconds.
    send_prompt "$slot" "$prompt"

    # Propagate the slot's UUID to meta.json so JSONL lookup works.
    local slot_uuid
    slot_uuid=$(read_pool_json | jq -r --argjson idx "$slot" \
      '.slots[] | select(.index == $idx) | .claude_session_id // empty')
    if [ -n "$slot_uuid" ]; then
      with_pool_lock _locked_set_job_uuid "$job_id" "$slot_uuid"
    fi

    # Update last_activity_at for TTL tracking
    with_pool_lock _locked_update_last_activity_at

    pool_log "watcher" "queue: $job_id dispatched to slot-$slot, prompt sent"
  done
}

# ---------------------------------------------------------------------------
# cancel_job <job_id>
# ---------------------------------------------------------------------------
# Remove a queued job from the queue before it starts processing.
# Errors if the job is not found in the queue (i.e. already running).
#
# Steps:
#   1. Search queue files for one whose name contains the job_id.
#   2. If found: remove the file, update job meta status to "cancelled".
#   3. If not found: die with an error (job is already running — use stop).
cancel_job() {
  local job_id="$1"
  local queue_dir="$POOL_DIR/queue"

  # Find the queue file for this job_id.
  # Queue filenames are NNN-<job_id>.json, so we match on the job_id suffix.
  local queue_file=""
  for f in "$queue_dir"/[0-9]*-"${job_id}".json; do
    [ -f "$f" ] || continue
    queue_file="$f"
    break
  done

  if [ -z "$queue_file" ]; then
    die "job $job_id is not in the queue — it may already be running (use 'sub-claude stop $job_id' instead)"
  fi

  # Remove the queue entry.
  rm -f "$queue_file"

  # Update job metadata status to cancelled.
  with_pool_lock _locked_mark_job_cancelled "$job_id"

  pool_log "queue" "cancelled $job_id"
}
