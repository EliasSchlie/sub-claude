# shellcheck shell=bash
# offload.sh — offloading and resume logic for sub-claude
#
# Sourced by the sub-claude dispatcher after core.sh and tmux.sh.
# Assumes POOL_DIR and TMUX_SOCKET are set, and all helpers from core.sh
# and tmux.sh are available.
#
# Provides:
#   - take_snapshot      <job_id> <slot>
#   - offload_to_new     <slot>
#   - offload_to_resume  <slot> <target_uuid> <target_job_id>
#   - allocate_slot      [--for-resume]
#   - prepare_slot_for_new     <slot>
#   - prepare_slot_for_resume  <slot> <target_uuid> <target_job_id>

# ---------------------------------------------------------------------------
# Snapshot
# ---------------------------------------------------------------------------

# take_snapshot <job_id> <slot>
# Capture the current terminal state and persist it to snapshot.log.
# Prefers capture_raw_log (full TUI output) over capture_pane (visible only).
take_snapshot() {
  local job_id="$1" slot="$2"
  local snap_dir="$POOL_DIR/jobs/$job_id"
  mkdir -p "$snap_dir"

  # Read the byte offset saved at dispatch time for job isolation
  local offset=0
  local offset_file="$snap_dir/raw_offset"
  if [ -f "$offset_file" ]; then
    offset=$(cat "$offset_file")
  fi

  # Prefer raw.log (full TUI output); fall back to capture_pane
  if ! capture_raw_log "$slot" "$offset" > "$snap_dir/snapshot.log" \
       || [ ! -s "$snap_dir/snapshot.log" ]; then
    capture_pane "$slot" > "$snap_dir/snapshot.log"
  fi

  pool_log offload "snapshot taken for $job_id from slot-$slot"
}

# ---------------------------------------------------------------------------
# Offload helpers
# ---------------------------------------------------------------------------

# offload_to_new <slot>
# Offload the current session on a slot and leave the slot in a fresh state
# ready for a new conversation.
offload_to_new() {
  local slot="$1"

  # Identify the job and UUID currently loaded in this slot.
  local pool_json job_id old_uuid
  pool_json=$(read_pool_json)
  job_id=$(printf '%s' "$pool_json" | jq -r --argjson idx "$slot" \
    '.slots[] | select(.index == $idx) | .job_id // empty')
  old_uuid=$(printf '%s' "$pool_json" | jq -r --argjson idx "$slot" \
    '.slots[] | select(.index == $idx) | .claude_session_id // empty')

  # Send Escape — harmless no-op at the prompt, exits any open menus.
  send_special_key "$slot" Escape
  sleep 0.5

  if [ -n "$job_id" ]; then
    take_snapshot "$job_id" "$slot"

    # Mark the old job as offloaded under the lock.
    with_pool_lock _locked_mark_job_offloaded "$job_id"
  fi

  # Invalidate the PID→UUID file before /clear so extract_uuid waits for
  # the new session's UUID instead of returning the stale one.
  invalidate_session_pidfile "$slot"

  # Start a new conversation in this slot.
  # Guard: send_slash_clear returns 1 on exhausted retries; don't crash under
  # set -e — proceeding with a stale session is better than dying.
  send_slash_clear "$slot" || pool_log offload "slot-$slot: /clear failed after retries, session may not be isolated"
  clear_scrollback "$slot"

  # Capture the new session UUID that /clear just created.
  # Skip warmup — session has already been used, no skill autocomplete issue.
  local new_uuid
  new_uuid=$(extract_uuid "$slot" --skip-warmup)

  # Safety check: if the UUID didn't change, /clear likely failed silently.
  # The slot is not truly fresh — log a warning but proceed. The old session
  # is still loaded, so subsequent dispatches will append to it rather than
  # starting a clean conversation. This is better than dying.
  if [ -n "$old_uuid" ] && [ "$new_uuid" = "$old_uuid" ]; then
    pool_log offload "slot-$slot: WARNING — UUID unchanged after /clear ($old_uuid), session may not be isolated"
  fi

  # Update pool.json: slot becomes fresh with the new UUID.
  with_pool_lock _locked_update_slot_fresh "$slot" "$new_uuid"

  pool_log offload "slot-$slot: offloaded ${job_id:-<none>}, now fresh (uuid=$new_uuid)"
}

# offload_to_resume <slot> <target_uuid> <target_job_id>
# Offload the current session on a slot, then /resume a different session.
offload_to_resume() {
  local slot="$1" target_uuid="$2" target_job_id="$3"

  # Identify the job currently loaded in this slot.
  local old_job_id
  old_job_id=$(read_pool_json | jq -r --argjson idx "$slot" \
    '.slots[] | select(.index == $idx) | .job_id // empty')

  # Send Escape — harmless no-op at the prompt, exits any open menus.
  send_special_key "$slot" Escape
  sleep 0.5

  if [ -n "$old_job_id" ]; then
    take_snapshot "$old_job_id" "$slot"

    # Mark the old job as offloaded under the lock.
    with_pool_lock _locked_mark_job_offloaded "$old_job_id"
  fi

  # Resume the target session.
  # Guard: send_slash_resume returns 1 on exhausted retries; don't crash under
  # set -e — proceeding in the wrong session is bad but crashing is worse.
  send_slash_resume "$slot" "$target_uuid" >/dev/null || pool_log offload "slot-$slot: /resume failed after retries"
  clear_scrollback "$slot"

  # Trust the target UUID — extract_uuid sends /status which pollutes the
  # resumed session's conversation (the autocomplete delay is often
  # insufficient, causing /status to be submitted as a user prompt).
  local slot_uuid="$target_uuid"

  # Update pool.json: slot is idle with the resumed session loaded.
  # The caller (dispatch or followup) transitions it to busy via
  # _locked_claim_and_dispatch when the prompt is actually sent.
  with_pool_lock _locked_update_slot_idle_resume "$slot" "$target_job_id" "$slot_uuid"

  pool_log offload "slot-$slot: offloaded ${old_job_id:-<none>}, resumed $target_job_id"
}

# ---------------------------------------------------------------------------
# Slot allocation
# ---------------------------------------------------------------------------

# allocate_slot [--for-resume]
# Find the best available slot. Prints the slot index to stdout.
# Returns 1 (no output) if no slot is available.
#
# Selection order:
#   1. Any fresh slot (no offload needed).
#   2. LRU idle slot (excluding currently pinned jobs).
allocate_slot() {
  # --for-resume is accepted but does not alter the selection logic.
  # It exists so callers can document their intent clearly.

  local pool_json
  pool_json=$(read_pool_json)

  # 1. Prefer a fresh slot.
  local fresh
  fresh=$(printf '%s' "$pool_json" | jq -r \
    '[.slots[] | select(.status=="fresh")] | .[0].index // empty')
  if [ -n "$fresh" ]; then
    echo "$fresh"
    return 0
  fi

  # 2. Least-recently-used idle slot, skipping pinned jobs.
  local idle
  idle=$(printf '%s' "$pool_json" | jq -r \
    --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
      .pins as $pins |
      [.slots[] | select(.status == "idle")] |
      [.[] | select(
        ($pins[.job_id // ""] // "1970-01-01T00:00:00Z") < $now
      )] |
      sort_by(.last_used_at) | .[0].index // empty
    ')
  if [ -n "$idle" ]; then
    echo "$idle"
    return 0
  fi

  return 1  # no slot available
}

# ---------------------------------------------------------------------------
# Slot preparation
# ---------------------------------------------------------------------------

# prepare_slot_for_new <slot>
# Ensure a slot is ready for a new conversation.
# - fresh: already ready, no-op.
# - idle:  offload the current session first.
# - other: die.
prepare_slot_for_new() {
  local slot="$1"
  local status
  status=$(printf '%s' "$(read_pool_json)" | \
    jq -r --argjson idx "$slot" '.slots[] | select(.index == $idx) | .status')

  case "$status" in
    fresh) return 0 ;;
    idle)  offload_to_new "$slot" ;;
    *)     die "slot $slot is $status — cannot prepare" ;;
  esac
}

# prepare_slot_for_resume <slot> <target_uuid> <target_job_id>
# Ensure a slot is ready to resume a specific Claude session.
# - fresh or idle: offload (if any) then /resume.
# - other: die.
prepare_slot_for_resume() {
  local slot="$1" target_uuid="$2" target_job_id="$3"
  local status
  status=$(printf '%s' "$(read_pool_json)" | \
    jq -r --argjson idx "$slot" '.slots[] | select(.index == $idx) | .status')

  case "$status" in
    fresh|idle) offload_to_resume "$slot" "$target_uuid" "$target_job_id" ;;
    *)          die "slot $slot is $status — cannot prepare for resume" ;;
  esac
}
