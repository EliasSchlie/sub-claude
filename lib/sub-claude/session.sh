# shellcheck shell=bash
# =============================================================================
# sub-claude: session.sh — Session-level CLI commands
# =============================================================================
# Sourced after core.sh, tmux.sh, offload.sh, queue.sh, and pool.sh.
# Do NOT add a shebang — this file is sourced, never executed directly.
#
# Provides all cmd_* functions invoked by the dispatcher:
#   cmd_start, cmd_followup, cmd_input, cmd_key, cmd_capture, cmd_result,
#   cmd_wait, cmd_status, cmd_list, cmd_stop, cmd_cancel, cmd_clean,
#   cmd_pin, cmd_unpin, cmd_attach, cmd_uuid

# ---------------------------------------------------------------------------
# Helpers (session-local)
# ---------------------------------------------------------------------------

# _queue_hint — one-shot hint suggesting pool resize when a job stays queued.
# Usage: _queue_hint <start_epoch> <threshold_seconds>
# Returns 0 (and prints hint) only the first time threshold is exceeded.
# Relies on caller setting _queue_hint_shown=false before the polling loop.
_queue_hint() {
  ${_queue_hint_shown:-true} && return 1
  local _qh_elapsed=$(( $(date +%s) - $1 ))
  [ "$_qh_elapsed" -ge "${2:-10}" ] || return 1
  _queue_hint_shown=true
  warn "job queued for ${_qh_elapsed}s — all pool slots are busy"
  warn "hint: expand the pool with 'sub-claude pool resize N'"
}

# _emit_pane <slot> — capture pane output, filtered by SUB_CLAUDE_VERBOSITY.
_emit_pane() {
  local slot="$1"
  if type claude_output_parse &>/dev/null && [ "${SUB_CLAUDE_VERBOSITY:-raw}" != "raw" ]; then
    capture_pane "$slot" | claude_output_parse -v "$SUB_CLAUDE_VERBOSITY"
  else
    capture_pane "$slot"
  fi
}

# _emit_pane_full <slot> <job_id> — capture full pane output using raw.log.
#
# TUI apps (like Claude Code) use the alternate screen buffer, which does NOT
# accumulate scrollback. Content that scrolls past the visible pane area is
# lost to capture-pane. This function reads the slot's raw.log (populated by
# pipe-pane) and strips ANSI escape sequences to recover the full output.
#
# Falls back to capture_pane if raw.log is unavailable.
_emit_pane_full() {
  local slot="$1" job_id="$2"

  # Read the byte offset saved at dispatch time
  local offset=0
  local offset_file="$POOL_DIR/jobs/$job_id/raw_offset"
  if [ -f "$offset_file" ]; then
    offset=$(cat "$offset_file")
  fi

  # Try raw.log first (captures full TUI output including scrolled-off content).
  # Fall back to capture_pane if raw.log is unavailable or empty.
  local output
  if output=$(capture_raw_log "$slot" "$offset") && [ -n "$output" ]; then
    : # got offset-based output
  elif output=$(capture_pane "$slot") && [ -n "$output" ]; then
    : # got capture_pane output
  elif [ "$offset" -gt 0 ] && output=$(capture_raw_log "$slot" 0) && [ -n "$output" ]; then
    # Last resort: raw.log exists but hasn't grown past the dispatch offset yet.
    # Show full content (including pre-dispatch TUI chrome) rather than nothing.
    :
  fi

  if [ -n "${output:-}" ]; then
    if type claude_output_parse &>/dev/null && [ "${SUB_CLAUDE_VERBOSITY:-raw}" != "raw" ]; then
      printf '%s\n' "$output" | claude_output_parse -v "$SUB_CLAUDE_VERBOSITY"
    else
      printf '%s\n' "$output"
    fi
  fi
}

# _emit_file <path> — emit file contents, filtered by SUB_CLAUDE_VERBOSITY.
_emit_file() {
  if type claude_output_parse &>/dev/null && [ "${SUB_CLAUDE_VERBOSITY:-raw}" != "raw" ]; then
    claude_output_parse -v "$SUB_CLAUDE_VERBOSITY" < "$1"
  else
    cat "$1"
  fi
}

# _emit_response <job_id> — extract last response text from JSONL transcript.
# Returns 0 and prints text on success, or returns 1 on any failure.
_emit_response() {
  local job_id="$1"
  type claude_jsonl_find &>/dev/null || return 1
  type claude_jsonl_last_response &>/dev/null || return 1

  local meta="$POOL_DIR/jobs/$job_id/meta.json"
  [ -f "$meta" ] || return 1

  local uuid
  uuid=$(jq -r '.claude_session_id // empty' "$meta")
  [ -n "$uuid" ] || return 1

  # Use pool's project_dir for JSONL lookup — it matches the directory Claude
  # Code actually uses (resolving symlinks like /tmp → /private/tmp on macOS).
  # Falls back to cwd from meta.json if pool.json is unavailable.
  local project_dir
  project_dir=$(jq -r '.project_dir // empty' "$POOL_DIR/pool.json" 2>/dev/null)
  [ -n "$project_dir" ] || project_dir=$(jq -r '.cwd // empty' "$meta")

  local jsonl_path
  jsonl_path=$(claude_jsonl_find "$uuid" "$project_dir") || return 1

  claude_jsonl_last_response "$jsonl_path"
}

# _emit_output <job_id> <slot_or_empty> [--terminal] — unified output dispatcher.
# Default: try JSONL response extraction, fall back to terminal capture.
# With --terminal: use terminal capture directly (old behavior).
_emit_output() {
  local job_id="$1" slot="${2:-}" terminal="${3:-${SUB_CLAUDE_TERMINAL:-}}"

  if [ "$terminal" = "--terminal" ]; then
    # Old behavior: terminal capture (with raw.log scrollback recovery).
    if [ -n "$slot" ]; then
      _emit_pane_full "$slot" "$job_id"
    else
      _emit_file "$POOL_DIR/jobs/$job_id/snapshot.log" 2>/dev/null || true
    fi
    return
  fi

  # JSONL provides last-response only. For other verbosity modes (conversation,
  # full), fall through to terminal capture which supports all levels.
  local v="${SUB_CLAUDE_VERBOSITY:-raw}"
  if [ "$v" = "raw" ] || [ "$v" = "response" ]; then
    if _emit_response "$job_id"; then
      return 0
    fi
  fi

  # Fallback: terminal capture (with raw.log scrollback recovery).
  if [ -n "$slot" ]; then
    _emit_pane_full "$slot" "$job_id"
  elif [ -f "$POOL_DIR/jobs/$job_id/snapshot.log" ]; then
    _emit_file "$POOL_DIR/jobs/$job_id/snapshot.log"
  else
    warn "no output available for $job_id (JSONL not found, no snapshot)"
    return 1
  fi
}

# _derive_parent_job_id <parent_session> — find the active job that spawned us.
# If parent_session is not 'standalone', looks for a processing job whose
# parent_session matches. Returns the job ID on stdout, or empty string.
_derive_parent_job_id() {
  local parent_session="$1"

  # Fast path: inside a pool slot, the slot's current job IS our parent.
  if [ -n "${SUB_CLAUDE_SLOT:-}" ] && [ -f "$POOL_DIR/pool.json" ]; then
    local slot_job
    slot_job=$(jq -r --argjson idx "${SUB_CLAUDE_SLOT}" \
      '.slots[] | select(.index == $idx) | .job_id // empty' \
      "$POOL_DIR/pool.json" 2>/dev/null)
    if [ -n "$slot_job" ]; then
      printf '%s' "$slot_job"
      return 0
    fi
  fi

  # Fallback: process tree walk (for non-pool callers)
  [ "$parent_session" != 'standalone' ] || return 0

  local jobs_dir="$POOL_DIR/jobs"
  [ -d "$jobs_dir" ] || return 0

  local d ps st
  for d in "$jobs_dir"/*/; do
    [ -f "$d/meta.json" ] || continue
    ps=$(jq -r '.parent_session // empty' "$d/meta.json" 2>/dev/null)
    [ "$ps" = "$parent_session" ] || continue
    st=$(jq -r '.status // empty' "$d/meta.json" 2>/dev/null)
    if [ "$st" = "processing" ]; then
      basename "$d"
      return 0
    fi
  done
}

# _require_pool — ensure pool exists, or auto-init and return 1.
# Returns 0 if pool is ready. Returns 1 if auto-init was triggered (caller
# should queue the job and return immediately).
_require_pool() {
  if [ -f "$POOL_DIR/pool.json" ]; then
    return 0
  fi
  return 1
}

# _auto_init_pool <job_id> <prompt> — queue the job and launch pool init
# in the background. Prints job ID to stdout and returns.
_auto_init_pool() {
  local job_id="$1" prompt="$2"

  printf 'no pool found — initializing (%d slots)...\n' "$SUB_CLAUDE_DEFAULT_POOL_SIZE" >&2

  # Create minimal directory structure for the queue.
  mkdir -p "$POOL_DIR/queue" "$POOL_DIR/jobs/$job_id"

  # Write meta.json so the job exists.
  local now parent_session parent_job_id depth cwd
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  parent_session=$(get_parent_session_id)
  parent_job_id=$(_derive_parent_job_id "$parent_session")
  depth=0
  cwd=$(pwd)

  jq -n \
    --arg id "$job_id" \
    --arg prompt "$prompt" \
    --arg parent_session "$parent_session" \
    --arg parent_job_id "$parent_job_id" \
    --arg cwd "$cwd" \
    --arg created_at "$now" \
    --argjson depth "$depth" \
    '{
      id: $id,
      prompt: $prompt,
      parent_session: $parent_session,
      parent_job_id: (if $parent_job_id == "" then null else $parent_job_id end),
      cwd: $cwd,
      created_at: $created_at,
      status: "queued",
      slot: null,
      claude_session_id: null,
      offloaded: false,
      depth: $depth
    }' > "$POOL_DIR/jobs/$job_id/meta.json"

  # Write queue entry directly (no pool.json yet, so no lock / seq counter).
  jq -n \
    --arg job_id "$job_id" \
    --arg prompt "$prompt" \
    --arg cwd "$cwd" \
    --arg queued_at "$now" \
    '{job_id: $job_id, type: "new", prompt: $prompt, claude_uuid: null, cwd: $cwd, queued_at: $queued_at}' \
    > "$POOL_DIR/queue/000000-${job_id}.json"

  # Print ID immediately.
  printf '%s\n' "$job_id"

  # Launch pool init as detached background (survives parent death).
  # exec </dev/null prevents stdin inheritance; output goes to /dev/null
  # so the claude binary launch doesn't disrupt current Bash tool output.
  ( exec </dev/null >/dev/null 2>&1; sub-claude pool init --size "$SUB_CLAUDE_DEFAULT_POOL_SIZE" ) & disown

  return 0
}

# _slot_done_file <slot> — print the done sentinel path for a slot.
_slot_done_file() {
  printf '%s/slots/%s/done' "$POOL_DIR" "$1"
}

# _slot_raw_log <slot> — print the raw.log path for a slot.
_slot_raw_log() {
  printf '%s/slots/%s/raw.log' "$POOL_DIR" "$1"
}

# _get_children [--tree] [--all] — print job IDs that match the scope.
# Default: direct children of the current parent session.
# --tree: all descendants of current parent session (recursive).
# --all: every job in the pool.
_get_children() {
  local mode="direct"
  while [ $# -gt 0 ]; do
    case "$1" in
      --tree) mode="tree"; shift ;;
      --all)  mode="all";  shift ;;
      *)      shift ;;
    esac
  done

  local parent_session
  parent_session=$(get_parent_session_id)

  local jobs_dir="$POOL_DIR/jobs"
  [ -d "$jobs_dir" ] || return 0

  case "$mode" in
    all)
      # Every job.
      for d in "$jobs_dir"/*/; do
        [ -f "$d/meta.json" ] || continue
        basename "$d"
      done
      ;;
    direct)
      # Direct children: parent_session matches.
      for d in "$jobs_dir"/*/; do
        [ -f "$d/meta.json" ] || continue
        local ps
        ps=$(jq -r '.parent_session // empty' "$d/meta.json" 2>/dev/null)
        if [ "$ps" = "$parent_session" ]; then
          basename "$d"
        fi
      done
      ;;
    tree)
      # All descendants: walk recursively from direct children.
      _get_descendants "$parent_session"
      ;;
  esac
}

# _get_descendants <parent_session> — recursively find all descendants.
_get_descendants() {
  local target_session="$1"
  local jobs_dir="$POOL_DIR/jobs"

  for d in "$jobs_dir"/*/; do
    [ -f "$d/meta.json" ] || continue
    local ps
    ps=$(jq -r '.parent_session // empty' "$d/meta.json" 2>/dev/null)
    if [ "$ps" = "$target_session" ]; then
      local child_id
      child_id=$(basename "$d")
      printf '%s\n' "$child_id"
      # Look for grandchildren by finding jobs whose parent_job_id is this child.
      _get_descendants_by_job "$child_id"
    fi
  done
}

# _get_descendants_by_job <job_id> — find children of a specific job (by
# looking for jobs whose parent_job_id matches).
_get_descendants_by_job() {
  local parent_job_id="$1"
  local jobs_dir="$POOL_DIR/jobs"

  for d in "$jobs_dir"/*/; do
    [ -f "$d/meta.json" ] || continue
    local pjid
    pjid=$(jq -r '.parent_job_id // empty' "$d/meta.json" 2>/dev/null)
    if [ "$pjid" = "$parent_job_id" ]; then
      local child_id
      child_id=$(basename "$d")
      printf '%s\n' "$child_id"
      _get_descendants_by_job "$child_id"
    fi
  done
}

# _get_job_children <job_id> — find direct children of a specific job.
_get_job_children() {
  local parent_job_id="$1"
  local jobs_dir="$POOL_DIR/jobs"

  for d in "$jobs_dir"/*/; do
    [ -f "$d/meta.json" ] || continue
    local pjid
    pjid=$(jq -r '.parent_job_id // empty' "$d/meta.json" 2>/dev/null)
    if [ "$pjid" = "$parent_job_id" ]; then
      basename "$d"
    fi
  done
}

# _get_all_descendants <job_id> — recursively get all descendants of a job.
_get_all_descendants() {
  local job_id="$1"
  local children
  children=$(_get_job_children "$job_id")

  local child
  for child in $children; do
    printf '%s\n' "$child"
    _get_all_descendants "$child"
  done
}

# _truncate_prompt <max_len> — read prompt from stdin, truncate to max_len.
_truncate_prompt() {
  local max="${1:-60}"
  local text
  text=$(cat)
  if [ "${#text}" -gt "$max" ]; then
    printf '%s...' "${text:0:$((max - 3))}"
  else
    printf '%s' "$text"
  fi
}

# _dispatch_to_slot <job_id> <slot> <prompt> [new] — common flow for sending
# a prompt to an allocated slot. Atomically verifies the slot is still
# available, claims it, marks the job as processing, and sends the prompt.
# If the 4th argument is non-empty (conventionally "new"), the agent identity
# prefix is prepended to the prompt (first message of a new conversation).
# Returns 1 if the slot was stolen by another process (caller should
# fall back to enqueue).
_dispatch_to_slot() {
  local job_id="$1" slot="$2" prompt="$3" is_new="${4:-}"

  # Prepend agent identity for new conversations.
  if [ -n "$is_new" ]; then
    prompt="$SUB_CLAUDE_AGENT_PREFIX
$prompt"
  fi

  # Root pool: prepend cwd instruction so the agent works in the right directory.
  if [ -n "$is_new" ]; then
    local cwd cwd_pfx
    cwd=$(jq -r '.cwd // empty' "$POOL_DIR/jobs/$job_id/meta.json" 2>/dev/null)
    cwd_pfx=$(_cwd_prefix "$cwd")
    if [ -n "$cwd_pfx" ]; then
      prompt="$cwd_pfx
$prompt"
    fi
  fi

  # Atomically verify slot is still free + claim it + mark job processing.
  # This prevents the race where two callers both allocate_slot() the same
  # slot and then both try to dispatch to it.
  if ! with_pool_lock _locked_claim_and_dispatch "$slot" "$job_id"; then
    pool_log "session" "$job_id: slot-$slot stolen, dispatch failed"
    return 1
  fi

  # Done sentinel is now cleared inside _locked_claim_and_dispatch (under
  # the lock) to prevent the watcher from seeing a stale done file.

  # Record the raw.log byte offset so capture_raw_log can isolate this
  # job's output from previous jobs on the same slot.
  local raw_log
  raw_log=$(_slot_raw_log "$slot")
  local raw_log_offset=0
  if [ -f "$raw_log" ]; then
    raw_log_offset=$(wc -c < "$raw_log" | tr -d ' ')
  fi
  mkdir -p "$POOL_DIR/jobs/$job_id"
  printf '%s' "$raw_log_offset" > "$POOL_DIR/jobs/$job_id/raw_offset"

  # Send the prompt (outside the lock — tmux ops can take seconds).
  send_prompt "$slot" "$prompt"

  pool_log "session" "$job_id dispatched to slot-$slot"
}

# ---------------------------------------------------------------------------
# cmd_start "$@"
# ---------------------------------------------------------------------------
cmd_start() {
  local prompt="" block=false terminal="${SUB_CLAUDE_TERMINAL:-}" timeout=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --block) block=true; shift ;;
      --terminal) terminal="--terminal"; shift ;;
      --timeout) timeout="$2"; shift 2 ;;
      *)
        if [ -z "$prompt" ]; then
          prompt="$1"
        else
          prompt="$prompt $1"
        fi
        shift
        ;;
    esac
  done

  [ -n "$prompt" ] || die "start: prompt required"

  # Validate timeout
  case "$timeout" in
    ''|*[!0-9]*) die "start: --timeout must be a non-negative integer (got '$timeout')" ;;
  esac

  # Generate job ID early so auto-init can use it.
  local id
  id=$(gen_id)

  # Auto-init if no pool exists.
  if ! _require_pool; then
    _auto_init_pool "$id" "$prompt"
    if $block; then
      warn "auto-init in progress — --block degraded to non-blocking. Use 'sub-claude wait $id' after pool is ready."
    fi
    return 0
  fi

  # Normal path: pool exists.
  local parent_session parent_job_id depth
  parent_session=$(get_parent_session_id)
  parent_job_id=$(_derive_parent_job_id "$parent_session")
  depth=$(derive_depth)

  # Create job directory and metadata.
  local job_dir="$POOL_DIR/jobs/$id"
  mkdir -p "$job_dir"

  local now cwd
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  cwd=$(pwd)

  jq -n \
    --arg id "$id" \
    --arg prompt "$prompt" \
    --arg parent_session "$parent_session" \
    --arg parent_job_id "$parent_job_id" \
    --arg cwd "$cwd" \
    --arg created_at "$now" \
    --argjson depth "$depth" \
    '{
      id: $id,
      prompt: $prompt,
      parent_session: $parent_session,
      parent_job_id: (if $parent_job_id == "" then null else $parent_job_id end),
      cwd: $cwd,
      created_at: $created_at,
      status: "queued",
      slot: null,
      claude_session_id: null,
      offloaded: false,
      depth: $depth
    }' > "$job_dir/meta.json"

  # Try immediate allocation.
  local slot
  if slot=$(allocate_slot); then
    prepare_slot_for_new "$slot"

    if _dispatch_to_slot "$id" "$slot" "$prompt" new; then
      # Capture the UUID that this slot now has.
      local uuid
      uuid=$(read_pool_json | jq -r --argjson idx "$slot" \
        '.slots[] | select(.index == $idx) | .claude_session_id // empty')
      if [ -n "$uuid" ]; then
        with_pool_lock _locked_set_job_uuid "$id" "$uuid"
      fi
    else
      # Slot was stolen between allocate and dispatch — fall back to queue.
      pool_log "session" "$id: slot-$slot stolen during start, falling back to queue"
      enqueue "$id" "new" "$prompt" >/dev/null
    fi
  else
    # Queue the job.
    enqueue "$id" "new" "$prompt" >/dev/null
  fi

  # Output behavior.
  if $block; then
    local status
    status=$(get_job_status "$id")

    if [ "$status" = "queued" ] && queue_pressure; then
      # Under queue pressure: don't block, return ID + warning.
      printf '%s\n' "$id"
      return 0
    fi

    # Print ID to stderr, block for result on stdout.
    printf '%s\n' "$id" >&2

    local _block_start
    _block_start=$(date +%s)

    # Wait for completion.
    local cur_slot
    cur_slot=$(get_slot_for_job "$id")
    if [ -n "$cur_slot" ]; then
      local _wfd_timeout=""
      if [ "$timeout" -gt 0 ] 2>/dev/null; then
        _wfd_timeout=$(( timeout - ($(date +%s) - _block_start) ))
        [ "$_wfd_timeout" -gt 0 ] || die "start --block: timed out (limit: ${timeout}s) — job $id may still be running"
      fi
      wait_for_done "$(_slot_done_file "$cur_slot")" "$(_slot_raw_log "$cur_slot")" "$_wfd_timeout" "$id"
      _emit_output "$id" "$cur_slot" "$terminal"
    else
      # Job is queued — poll until it gets a slot, then wait.
      local _queue_hint_shown=false
      while true; do
        if [ "$timeout" -gt 0 ] 2>/dev/null; then
          local _elapsed=$(( $(date +%s) - _block_start ))
          if [ "$_elapsed" -ge "$timeout" ]; then
            warn "hint: all pool slots were busy — consider 'sub-claude pool resize N'"
            die "start --block: timed out after ${_elapsed}s (limit: ${timeout}s) — job $id still queued"
          fi
        fi
        sleep 2
        status=$(get_job_status "$id")
        case "$status" in
          processing)
            cur_slot=$(get_slot_for_job "$id")
            [ -n "$cur_slot" ] || continue
            local _wfd_timeout=""
            if [ "$timeout" -gt 0 ] 2>/dev/null; then
              _wfd_timeout=$(( timeout - ($(date +%s) - _block_start) ))
              [ "$_wfd_timeout" -gt 0 ] || die "start --block: timed out (limit: ${timeout}s) — job $id may still be running"
            fi
            wait_for_done "$(_slot_done_file "$cur_slot")" "$(_slot_raw_log "$cur_slot")" "$_wfd_timeout" "$id"
            _emit_output "$id" "$cur_slot" "$terminal"
            break
            ;;
          finished*)
            cur_slot=$(get_slot_for_job "$id")
            _emit_output "$id" "$cur_slot" "$terminal"
            break
            ;;
          error)
            die "session $id crashed during processing"
            ;;
          queued)
            # Still waiting for a slot — check watcher is alive.
            if ! is_pool_running; then
              warn "hint: consider 'sub-claude pool resize N' to add capacity"
              die "pool watcher stopped — job $id stuck in queue"
            fi
            _queue_hint "$_block_start" 10
            continue
            ;;
        esac
      done
    fi
  else
    # Non-blocking: print ID to stdout.
    printf '%s\n' "$id"
  fi
}

# ---------------------------------------------------------------------------
# cmd_followup "$@"
# ---------------------------------------------------------------------------
cmd_followup() {
  local id="" prompt="" block=false terminal="${SUB_CLAUDE_TERMINAL:-}" timeout=0

  # First positional = id, second positional = prompt.
  local positionals=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --block) block=true; shift ;;
      --terminal) terminal="--terminal"; shift ;;
      --timeout) timeout="$2"; shift 2 ;;
      *)
        positionals=$((positionals + 1))
        case "$positionals" in
          1) id="$1" ;;
          2) prompt="$1" ;;
          *) prompt="$prompt $1" ;;
        esac
        shift
        ;;
    esac
  done

  [ -n "$id" ] || die "followup: job ID required"
  [ -n "$prompt" ] || die "followup: prompt required"

  # Validate timeout
  case "$timeout" in
    ''|*[!0-9]*) die "followup: --timeout must be a non-negative integer (got '$timeout')" ;;
  esac

  validate_id "$id"
  ensure_pool_exists

  local status
  status=$(get_job_status "$id")

  case "$status" in
    queued)
      die "session $id is queued — not yet running"
      ;;
    processing)
      die "session $id is still processing — wait for it to finish first"
      ;;
    error)
      die "session $id crashed — clean it first with 'sub-claude clean $id'"
      ;;
    "finished(idle)")
      # Direct send — slot is available.
      local slot
      slot=$(get_slot_for_job "$id")
      [ -n "$slot" ] || die "session $id: slot not found (internal error)"
      if ! _dispatch_to_slot "$id" "$slot" "$prompt"; then
        # Slot was reclaimed — fall back to queue as resume.
        local claude_uuid
        claude_uuid=$(jq -r '.claude_session_id // empty' "$POOL_DIR/jobs/$id/meta.json")
        enqueue "$id" "resume" "$prompt" "$claude_uuid" >/dev/null
      fi
      ;;
    "finished(offloaded)")
      # Need a slot to resume.
      local claude_uuid
      claude_uuid=$(jq -r '.claude_session_id // empty' "$POOL_DIR/jobs/$id/meta.json")

      if [ -z "$claude_uuid" ]; then
        # UUID extraction failed at init — cannot /resume. Fall back to a
        # fresh slot (new conversation). Warn because conversation history
        # from the original session will be lost.
        warn "session $id: no UUID (extraction failed at init) — starting fresh conversation instead of resuming"
        local slot
        if slot=$(allocate_slot); then
          prepare_slot_for_new "$slot"
          with_pool_lock _locked_mark_job_not_offloaded "$id"
          if ! _dispatch_to_slot "$id" "$slot" "$prompt" new; then
            pool_log "session" "$id: slot-$slot stolen during followup, falling back to queue"
            enqueue "$id" "new" "$prompt" >/dev/null
          fi
        else
          enqueue "$id" "new" "$prompt" >/dev/null
        fi
      else
        local slot
        if slot=$(allocate_slot); then
          prepare_slot_for_resume "$slot" "$claude_uuid" "$id"
          # Mark job as no longer offloaded.
          with_pool_lock _locked_mark_job_not_offloaded "$id"
          if ! _dispatch_to_slot "$id" "$slot" "$prompt"; then
            pool_log "session" "$id: slot-$slot stolen during followup, falling back to queue"
            enqueue "$id" "resume" "$prompt" "$claude_uuid" >/dev/null
          fi
        else
          # Enqueue as resume type.
          enqueue "$id" "resume" "$prompt" "$claude_uuid" >/dev/null
        fi
      fi
      ;;
    *)
      die "session $id: unknown status '$status'"
      ;;
  esac

  # Output behavior (same as cmd_start).
  if $block; then
    status=$(get_job_status "$id")

    if [ "$status" = "queued" ] && queue_pressure; then
      printf '%s\n' "$id"
      return 0
    fi

    printf '%s\n' "$id" >&2

    local _block_start
    _block_start=$(date +%s)

    local cur_slot
    local _queue_hint_shown=false
    while true; do
      if [ "$timeout" -gt 0 ] 2>/dev/null; then
        local _elapsed=$(( $(date +%s) - _block_start ))
        if [ "$_elapsed" -ge "$timeout" ]; then
          die "followup --block: timed out after ${_elapsed}s (limit: ${timeout}s) — job $id may still be running"
        fi
      fi
      status=$(get_job_status "$id")
      case "$status" in
        processing)
          cur_slot=$(get_slot_for_job "$id")
          [ -n "$cur_slot" ] || { sleep 2; continue; }
          local _wfd_timeout=""
          if [ "$timeout" -gt 0 ] 2>/dev/null; then
            _wfd_timeout=$(( timeout - ($(date +%s) - _block_start) ))
            [ "$_wfd_timeout" -gt 0 ] || die "followup --block: timed out (limit: ${timeout}s) — job $id may still be running"
          fi
          wait_for_done "$(_slot_done_file "$cur_slot")" "$(_slot_raw_log "$cur_slot")" "$_wfd_timeout" "$id"
          _emit_output "$id" "$cur_slot" "$terminal"
          break
          ;;
        finished*)
          cur_slot=$(get_slot_for_job "$id")
          _emit_output "$id" "$cur_slot" "$terminal"
          break
          ;;
        error)
          die "session $id crashed during processing"
          ;;
        queued)
          if ! is_pool_running; then
            warn "hint: consider 'sub-claude pool resize N' to add capacity"
            die "pool watcher stopped — job $id stuck in queue"
          fi
          _queue_hint "$_block_start" 10
          sleep 2
          continue
          ;;
      esac
    done
  else
    printf '%s\n' "$id"
  fi
}

# ---------------------------------------------------------------------------
# cmd_input "$@"
# ---------------------------------------------------------------------------
cmd_input() {
  local id="${1:-}" text="${2:-}"
  [ -n "$id" ] || die "input: job ID required"
  [ -n "$text" ] || die "input: text required"
  validate_id "$id"
  ensure_pool_exists

  local status
  status=$(get_job_status "$id")

  case "$status" in
    queued)
      die "session $id is queued — not yet running"
      ;;
    processing)
      local slot
      slot=$(get_slot_for_job "$id")
      [ -n "$slot" ] || die "session $id: slot not found (internal error)"
      send_keys "$slot" "$text"
      send_special_key "$slot" Enter
      ;;
    "finished(idle)")
      local slot
      slot=$(get_slot_for_job "$id")
      [ -n "$slot" ] || die "session $id: slot not found (internal error)"
      warn "session $id is idle — input won't be tracked as a job. Use 'followup' for new prompts."
      send_keys "$slot" "$text"
      send_special_key "$slot" Enter
      ;;
    "finished(offloaded)")
      die "session $id is offloaded — pin it first to load into a slot"
      ;;
    error)
      die "session $id crashed"
      ;;
    *)
      die "session $id: unknown status '$status'"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# cmd_key "$@"
# ---------------------------------------------------------------------------
cmd_key() {
  local id="${1:-}" key="${2:-}"
  [ -n "$id" ] || die "key: job ID required"
  [ -n "$key" ] || die "key: key name required (e.g. Escape, Enter, Up)"
  validate_id "$id"
  ensure_pool_exists

  local status
  status=$(get_job_status "$id")

  case "$status" in
    queued)
      die "session $id is queued — not yet running"
      ;;
    processing|"finished(idle)")
      local slot
      slot=$(get_slot_for_job "$id")
      [ -n "$slot" ] || die "session $id: slot not found (internal error)"
      send_special_key "$slot" "$key"
      ;;
    "finished(offloaded)")
      die "session $id is offloaded — pin it first to load into a slot"
      ;;
    error)
      die "session $id crashed"
      ;;
    *)
      die "session $id: unknown status '$status'"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# cmd_capture "$@"
# ---------------------------------------------------------------------------
cmd_capture() {
  local id="${1:-}"
  [ -n "$id" ] || die "capture: job ID required"
  validate_id "$id"
  ensure_pool_exists

  local status
  status=$(get_job_status "$id")

  case "$status" in
    queued)
      die "session $id is queued — not yet running"
      ;;
    processing)
      local slot
      slot=$(get_slot_for_job "$id")
      [ -n "$slot" ] || die "session $id: slot not found (internal error)"
      _emit_pane_full "$slot" "$id"
      ;;
    "finished(idle)")
      local slot
      slot=$(get_slot_for_job "$id")
      [ -n "$slot" ] || die "session $id: slot not found (internal error)"
      _emit_output "$id" "$slot"
      ;;
    "finished(offloaded)")
      local snap="$POOL_DIR/jobs/$id/snapshot.log"
      if [ -f "$snap" ]; then
        _emit_file "$snap"
        printf '\n[note: session was offloaded — interactive menus were closed automatically]\n'
      else
        die "session $id is offloaded but no snapshot available"
      fi
      ;;
    error)
      local snap="$POOL_DIR/jobs/$id/snapshot.log"
      if [ -f "$snap" ]; then
        _emit_file "$snap"
      else
        die "session $id crashed — no snapshot available"
      fi
      ;;
    *)
      die "session $id: unknown status '$status'"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# cmd_result "$@"
# ---------------------------------------------------------------------------
cmd_result() {
  local id="" terminal="${SUB_CLAUDE_TERMINAL:-}"

  while [ $# -gt 0 ]; do
    case "$1" in
      --terminal) terminal="--terminal"; shift ;;
      *)
        if [ -z "$id" ]; then
          id="$1"
        fi
        shift
        ;;
    esac
  done

  [ -n "$id" ] || die "result: job ID required"
  validate_id "$id"
  ensure_pool_exists

  local status
  status=$(get_job_status "$id")

  case "$status" in
    queued)
      die "session $id is queued — not yet running"
      ;;
    processing)
      die "session $id is still processing — use 'wait' or 'capture'"
      ;;
    "finished(idle)")
      local slot
      slot=$(get_slot_for_job "$id")
      [ -n "$slot" ] || die "session $id: slot not found (internal error)"
      _emit_output "$id" "$slot" "$terminal"
      ;;
    "finished(offloaded)")
      _emit_output "$id" "" "$terminal"
      ;;
    error)
      local snap="$POOL_DIR/jobs/$id/snapshot.log"
      if [ -f "$snap" ]; then
        _emit_file "$snap"
      else
        die "session $id crashed — no snapshot available"
      fi
      ;;
    *)
      die "session $id: unknown status '$status'"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# cmd_wait "$@"
# ---------------------------------------------------------------------------
cmd_wait() {
  local id="" quiet=false terminal="${SUB_CLAUDE_TERMINAL:-}" timeout=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --quiet) quiet=true; shift ;;
      --terminal) terminal="--terminal"; shift ;;
      --timeout) timeout="$2"; shift 2 ;;
      *)
        if [ -z "$id" ]; then
          id="$1"
        fi
        shift
        ;;
    esac
  done

  # Validate timeout
  case "$timeout" in
    ''|*[!0-9]*) die "wait: --timeout must be a non-negative integer (got '$timeout')" ;;
  esac

  # Export terminal flag so delegated cmd_result inherits it.
  SUB_CLAUDE_TERMINAL="$terminal"

  # Tolerate the auto-init race: pool init with 5 slots can take 30-60s.
  ensure_pool_exists_or_wait 60

  local _wait_start
  _wait_start=$(date +%s)

  if [ -n "$id" ]; then
    # Wait for a specific job.
    validate_id "$id"

    # Print queue pressure warning unless --quiet.
    if ! $quiet; then
      queue_pressure 2>/dev/null || true
    fi

    # Poll until done.
    local _queue_hint_shown=false
    while true; do
      if [ "$timeout" -gt 0 ] 2>/dev/null; then
        local _elapsed=$(( $(date +%s) - _wait_start ))
        [ "$_elapsed" -lt "$timeout" ] || die "wait: timed out after ${_elapsed}s (limit: ${timeout}s)"
      fi
      local status
      status=$(get_job_status "$id")
      case "$status" in
        processing)
          local slot
          slot=$(get_slot_for_job "$id")
          if [ -n "$slot" ]; then
            local _wfd_timeout=""
            if [ "$timeout" -gt 0 ] 2>/dev/null; then
              _wfd_timeout=$(( timeout - ($(date +%s) - _wait_start) ))
              [ "$_wfd_timeout" -gt 0 ] || die "wait: timed out (limit: ${timeout}s)"
            fi
            wait_for_done "$(_slot_done_file "$slot")" "$(_slot_raw_log "$slot")" "$_wfd_timeout" "$id"
            _emit_output "$id" "$slot" "$terminal"
            return 0
          fi
          sleep 2
          ;;
        "finished(idle)")
          local slot
          slot=$(get_slot_for_job "$id")
          _emit_output "$id" "$slot" "$terminal"
          return 0
          ;;
        "finished(offloaded)")
          _emit_output "$id" "" "$terminal"
          return 0
          ;;
        error)
          die "session $id crashed during processing"
          ;;
        queued)
          _queue_hint "$_wait_start" 10
          sleep 2
          ;;
        *)
          die "session $id: unexpected status '$status'"
          ;;
      esac
    done
  else
    # Wait for any direct child to finish.
    if ! $quiet; then
      queue_pressure 2>/dev/null || true
    fi

    # Snapshot children already finished so we skip stale results (#40).
    local _already_done=" "
    local _snap_children
    _snap_children=$(_get_children)
    if [ -n "$_snap_children" ]; then
      local _sc
      for _sc in $_snap_children; do
        local _ss
        _ss=$(get_job_status "$_sc" 2>/dev/null) || continue
        case "$_ss" in
          "finished(idle)"|"finished(offloaded)")
            _already_done="${_already_done}${_sc} "
            ;;
        esac
      done
    fi

    while true; do
      if [ "$timeout" -gt 0 ] 2>/dev/null; then
        local _elapsed=$(( $(date +%s) - _wait_start ))
        [ "$_elapsed" -lt "$timeout" ] || die "wait: timed out after ${_elapsed}s (limit: ${timeout}s)"
      fi
      local children
      children=$(_get_children)
      [ -n "$children" ] || die "no child sessions to wait for"

      local child
      for child in $children; do
        # Skip children that were already finished when wait started.
        case "$_already_done" in *" $child "*) continue ;; esac
        local status
        status=$(get_job_status "$child" 2>/dev/null) || continue
        case "$status" in
          "finished(idle)"|"finished(offloaded)")
            # Found one that's done.
            printf -- '--- %s ---\n' "$child" >&2
            cmd_result "$child"
            return 0
            ;;
        esac
      done

      # None finished yet — check if any are still active.
      local any_active=false
      for child in $children; do
        local status
        status=$(get_job_status "$child" 2>/dev/null) || continue
        case "$status" in
          queued|processing)
            any_active=true
            break
            ;;
        esac
      done

      if ! $any_active; then
        die "no active child sessions to wait for"
      fi

      sleep 2
    done
  fi
}

# ---------------------------------------------------------------------------
# cmd_status "$@"
# ---------------------------------------------------------------------------
cmd_status() {
  local id="${1:-}"
  [ -n "$id" ] || die "status: job ID required"
  validate_id "$id"
  ensure_pool_exists

  local status prompt
  status=$(get_job_status "$id")
  prompt=$(jq -r '.prompt // ""' "$POOL_DIR/jobs/$id/meta.json" 2>/dev/null \
    | _truncate_prompt 60)

  printf '%s   %s   %s\n' "$id" "$status" "$prompt"
}

# ---------------------------------------------------------------------------
# cmd_list "$@"
# ---------------------------------------------------------------------------
cmd_list() {
  local tree=false all=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --tree) tree=true; shift ;;
      --all)  all=true;  shift ;;
      *)      shift ;;
    esac
  done

  ensure_pool_exists

  if $tree; then
    # Tree view: show ALL jobs organized by parent_job_id hierarchy.
    local all_jobs
    all_jobs=$(_get_children --all)
    [ -n "$all_jobs" ] || return 0

    # Print root-level jobs (no parent_job_id), then recurse into children.
    local job pjid
    local roots=()
    for job in $all_jobs; do
      pjid=$(jq -r '.parent_job_id // empty' "$POOL_DIR/jobs/$job/meta.json" 2>/dev/null)
      if [ -z "$pjid" ]; then
        roots+=("$job")
      fi
    done

    local i
    for i in "${!roots[@]}"; do
      local is_last=$(( i == ${#roots[@]} - 1 ))
      _list_tree_node "${roots[$i]}" "" "$is_last"
    done
  else
    # Flat list.
    local children
    if $all; then
      children=$(_get_children --all)
    else
      children=$(_get_children)
    fi
    [ -n "$children" ] || return 0

    local child
    for child in $children; do
      local status prompt
      status=$(get_job_status "$child" 2>/dev/null) || continue
      prompt=$(jq -r '.prompt // ""' "$POOL_DIR/jobs/$child/meta.json" 2>/dev/null \
        | _truncate_prompt 60)
      printf '%s   %s   %s\n' "$child" "$status" "$prompt"
    done
  fi
}

# _list_tree_node <job_id> <prefix> <is_last>
# Print a single tree node with tree-drawing characters, then recurse.
_list_tree_node() {
  local job_id="$1" prefix="$2" is_last="$3" depth="${4:-0}"
  local jobs_dir="$POOL_DIR/jobs"

  # Guard against circular parent_job_id references.
  if [ "$depth" -gt 20 ]; then
    printf '%s[max depth exceeded]\n' "$prefix"
    return 0
  fi

  local status prompt
  status=$(get_job_status "$job_id" 2>/dev/null) || return 0
  prompt=$(jq -r '.prompt // ""' "$jobs_dir/$job_id/meta.json" 2>/dev/null \
    | _truncate_prompt 60)

  # Draw connector: └─ for last sibling, ├─ for others. No connector at root.
  local connector=""
  if [ -n "$prefix" ]; then
    if [ "$is_last" = "1" ]; then
      connector="└─ "
    else
      connector="├─ "
    fi
  fi
  printf '%s%s%s   %s   %s\n' "$prefix" "$connector" "$job_id" "$status" "$prompt"

  # Find children of this job (by parent_job_id).
  local child_prefix
  if [ -z "$prefix" ] && [ "$is_last" = "1" ]; then
    child_prefix="   "
  elif [ -z "$prefix" ]; then
    child_prefix="│  "
  elif [ "$is_last" = "1" ]; then
    child_prefix="${prefix}   "
  else
    child_prefix="${prefix}│  "
  fi

  local children=()
  local d pjid
  for d in "$jobs_dir"/*/; do
    [ -f "$d/meta.json" ] || continue
    pjid=$(jq -r '.parent_job_id // empty' "$d/meta.json" 2>/dev/null)
    if [ "$pjid" = "$job_id" ]; then
      children+=("$(basename "$d")")
    fi
  done

  local ci
  for ci in "${!children[@]}"; do
    local child_is_last=$(( ci == ${#children[@]} - 1 ))
    _list_tree_node "${children[$ci]}" "$child_prefix" "$child_is_last" "$(( depth + 1 ))"
  done
}

# _stop_single_job <job_id> — interrupt a processing job and immediately
# mark it as completed/idle. Sends Escape to interrupt Claude, then writes
# the done sentinel and updates metadata so the session transitions to
# finished(idle) without waiting for the Stop hook (which won't fire after
# an interrupt).
_stop_single_job() {
  local job_id="$1"

  # Guard: skip if already stopped (prevents slot corruption on double-call).
  local cur_status
  cur_status=$(get_job_status "$job_id" 2>/dev/null) || return 1
  [ "$cur_status" = "processing" ] || return 0

  local slot
  slot=$(get_slot_for_job "$job_id")
  [ -n "$slot" ] || { pool_log "session" "stop: slot not found for $job_id"; return 1; }

  # Re-verify slot ownership before sending Escape — the watcher may have
  # recycled the slot between our status check and now.
  local current_jid
  current_jid=$(read_pool_json | jq -r --argjson idx "$slot" \
    '.slots[] | select(.index == $idx) | .job_id // empty')
  [ "$current_jid" = "$job_id" ] || { pool_log "session" "stop: slot-$slot recycled away from $job_id"; return 0; }

  send_special_key "$slot" Escape
  sleep 0.5
  pool_log "session" "stop: sent Escape to $job_id (slot-$slot)"

  # Write done sentinel AND update metadata atomically under one lock.
  # This prevents the watcher from seeing the done file and recycling
  # the slot before we mark it idle ourselves.
  with_pool_lock _locked_stop_and_complete "$job_id" "$slot"
}

# ---------------------------------------------------------------------------
# cmd_stop "$@"
# ---------------------------------------------------------------------------
cmd_stop() {
  local id="" tree=false all=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --tree) tree=true; shift ;;
      --all)  all=true;  shift ;;
      *)
        if [ -z "$id" ]; then
          id="$1"
        fi
        shift
        ;;
    esac
  done

  ensure_pool_exists

  if [ -n "$id" ]; then
    # Stop a single session.
    validate_id "$id"
    local status
    status=$(get_job_status "$id")

    if [ "$status" != "processing" ]; then
      die "session $id is not busy (status: $status)"
    fi

    _stop_single_job "$id"
  else
    # Stop multiple sessions.
    local targets
    if $all; then
      targets=$(_get_children --all)
    elif $tree; then
      targets=$(_get_children --tree)
    else
      targets=$(_get_children)
    fi

    local target
    for target in $targets; do
      local status
      status=$(get_job_status "$target" 2>/dev/null) || continue
      if [ "$status" = "processing" ]; then
        _stop_single_job "$target"
      fi
    done
  fi
}

# ---------------------------------------------------------------------------
# cmd_cancel "$@"
# ---------------------------------------------------------------------------
cmd_cancel() {
  local id="${1:-}"
  [ -n "$id" ] || die "cancel: job ID required"
  validate_id "$id"
  ensure_pool_exists
  get_job_status "$id" >/dev/null

  cancel_job "$id"
}

# ---------------------------------------------------------------------------
# cmd_clean "$@"
# ---------------------------------------------------------------------------
cmd_clean() {
  local id="" completed=false tree=false all=false
  local force=false force_all=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --completed) completed=true; shift ;;
      --tree)      tree=true;      shift ;;
      --all)       all=true;       shift ;;
      --force)     force=true;     shift ;;
      --force-all) force_all=true; shift ;;
      *)
        if [ -z "$id" ]; then
          id="$1"
        fi
        shift
        ;;
    esac
  done

  ensure_pool_exists

  # Determine targets.
  local targets=""

  if [ -n "$id" ]; then
    validate_id "$id"
    get_job_status "$id" >/dev/null
    # Target this job + all its descendants.
    targets="$id"
    local descendants
    descendants=$(_get_all_descendants "$id")
    if [ -n "$descendants" ]; then
      targets="$descendants
$targets"
    fi
  elif $completed; then
    # All completed direct children + their descendants.
    local children
    children=$(_get_children)
    local child
    for child in $children; do
      local status
      status=$(get_job_status "$child" 2>/dev/null) || continue
      case "$status" in
        "finished(idle)"|"finished(offloaded)")
          local desc
          desc=$(_get_all_descendants "$child")
          if [ -n "$desc" ]; then
            targets="$targets
$desc"
          fi
          targets="$targets
$child"
          ;;
      esac
    done
  elif $tree; then
    local children
    children=$(_get_children --tree)
    targets="$children"
  elif $all; then
    local children
    children=$(_get_children --all)
    targets="$children"
  else
    die "clean: specify a job ID, --completed, --tree, or --all"
  fi

  targets=$(printf '%s' "$targets" | sed '/^$/d')
  [ -n "$targets" ] || return 0

  # Ensure depth-first ordering: reverse so children come before parents.
  # (descendants were listed before their parent in our collection)

  # Check for busy sessions.
  local target
  for target in $targets; do
    local status
    status=$(get_job_status "$target" 2>/dev/null) || continue
    if [ "$status" = "processing" ]; then
      if $force_all; then
        _stop_single_job "$target"
      elif $force && [ "$target" = "$id" ]; then
        _stop_single_job "$target"
      else
        die "cannot clean $id — session $target is still processing
hint: stop it first with 'sub-claude stop $target', or use --force"
      fi
    fi
  done

  # Clean each target.
  for target in $targets; do
    _clean_single_job "$target"
  done
}

# _clean_single_job <job_id> — clean a single job.
_clean_single_job() {
  local job_id="$1"
  local status
  status=$(get_job_status "$job_id" 2>/dev/null) || {
    # Job metadata may already be gone.
    rm -rf "$POOL_DIR/jobs/$job_id"
    return 0
  }

  case "$status" in
    queued)
      # Remove from queue.
      local queue_dir="$POOL_DIR/queue"
      rm -f "$queue_dir"/[0-9]*-"${job_id}".json
      rm -rf "$POOL_DIR/jobs/$job_id"
      pool_log "session" "clean: removed queued job $job_id"
      ;;
    "finished(idle)")
      # Offload the slot (Escape + snapshot), then /clear to make it fresh.
      local slot
      slot=$(get_slot_for_job "$job_id")
      if [ -n "$slot" ]; then
        offload_to_new "$slot"
      fi
      rm -rf "$POOL_DIR/jobs/$job_id"
      pool_log "session" "clean: offloaded + cleared $job_id"
      ;;
    "finished(offloaded)")
      # Already offloaded — just remove metadata.
      rm -rf "$POOL_DIR/jobs/$job_id"
      pool_log "session" "clean: removed offloaded $job_id"
      ;;
    error)
      # Remove metadata.
      rm -rf "$POOL_DIR/jobs/$job_id"
      pool_log "session" "clean: removed errored $job_id"
      ;;
    processing)
      # Should have been stopped by force check above.
      # If we reach here, treat as idle after a brief wait.
      local slot
      slot=$(get_slot_for_job "$job_id")
      if [ -n "$slot" ]; then
        offload_to_new "$slot"
      fi
      rm -rf "$POOL_DIR/jobs/$job_id"
      pool_log "session" "clean: force-cleaned processing $job_id"
      ;;
    *)
      rm -rf "$POOL_DIR/jobs/$job_id"
      pool_log "session" "clean: removed $job_id (status: $status)"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# cmd_pin "$@"
# ---------------------------------------------------------------------------
cmd_pin() {
  local id="${1:-}" duration="${2:-120}"
  [ -n "$id" ] || die "pin: job ID required"
  validate_id "$id"

  # Validate duration is a positive integer
  case "$duration" in
    ''|*[!0-9]*|0) die "pin: duration must be a positive integer (got '$duration')" ;;
  esac

  ensure_pool_exists

  local status
  status=$(get_job_status "$id")

  case "$status" in
    queued)
      die "session $id is queued — nothing to pin"
      ;;
    error)
      die "session $id crashed"
      ;;
    processing|"finished(idle)")
      # Pin the slot.
      _pin_job "$id" "$duration"
      ;;
    "finished(offloaded)")
      # Auto-load: find a slot, resume, then pin.
      local claude_uuid
      claude_uuid=$(jq -r '.claude_session_id // empty' "$POOL_DIR/jobs/$id/meta.json")

      local slot
      slot=$(allocate_slot) || die "session $id: no slots available to load offloaded session — try freeing slots first"

      if [ -z "$claude_uuid" ]; then
        # UUID extraction failed at init — cannot /resume. Load a fresh
        # slot instead. Conversation history will be lost.
        warn "session $id: no UUID (extraction failed at init) — loading fresh slot instead of resuming"
        prepare_slot_for_new "$slot"
      else
        prepare_slot_for_resume "$slot" "$claude_uuid" "$id"
      fi

      # Mark job as no longer offloaded.
      with_pool_lock _locked_mark_job_not_offloaded "$id"

      # Update slot to idle with this job.
      with_pool_lock _locked_update_slot_idle "$slot" "$id"

      _pin_job "$id" "$duration"
      ;;
    *)
      die "session $id: unknown status '$status'"
      ;;
  esac
}

# _pin_job <job_id> <duration_seconds> — add pin entry to pool.json.
_pin_job() {
  local job_id="$1" duration="$2"

  # Compute expiry timestamp.
  local now_epoch expiry_epoch expiry
  now_epoch=$(date +%s)
  expiry_epoch=$((now_epoch + duration))

  # Cross-platform date formatting.
  if date -r "$expiry_epoch" +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
    # macOS BSD date.
    expiry=$(date -r "$expiry_epoch" -u +%Y-%m-%dT%H:%M:%SZ)
  else
    # GNU date.
    expiry=$(date -d "@$expiry_epoch" -u +%Y-%m-%dT%H:%M:%SZ)
  fi

  with_pool_lock _locked_set_pin "$job_id" "$expiry"

  pool_log "session" "pinned $job_id for ${duration}s (expires $expiry)"
  printf 'pinned %s for %ds\n' "$job_id" "$duration"
  warn "pin is for heavy interactive workflows (menus, shortcuts) — not for basic messaging"
}

# ---------------------------------------------------------------------------
# cmd_unpin "$@"
# ---------------------------------------------------------------------------
cmd_unpin() {
  local id="${1:-}"
  [ -n "$id" ] || die "unpin: job ID required"
  validate_id "$id"
  ensure_pool_exists
  get_job_status "$id" >/dev/null

  with_pool_lock _locked_remove_pin "$id"

  pool_log "session" "unpinned $id"
  printf 'unpinned %s\n' "$id"
}

# ---------------------------------------------------------------------------
# cmd_attach "$@"
# ---------------------------------------------------------------------------
cmd_attach() {
  local id="${1:-}"
  [ -n "$id" ] || die "attach: job ID required"
  validate_id "$id"
  ensure_pool_exists

  local status
  status=$(get_job_status "$id")

  case "$status" in
    queued)
      die "session $id is queued — not yet running"
      ;;
    processing|"finished(idle)")
      local slot
      slot=$(get_slot_for_job "$id")
      [ -n "$slot" ] || die "session $id: slot not found (internal error)"
      TMUX='' tmux_cmd attach-session -t "$(slot_target "$slot")"
      ;;
    "finished(offloaded)")
      die "session $id is offloaded — pin it first to load into a slot"
      ;;
    error)
      die "session $id crashed"
      ;;
    *)
      die "session $id: unknown status '$status'"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# cmd_uuid "$@"
# ---------------------------------------------------------------------------
cmd_uuid() {
  local id="${1:-}"
  [ -n "$id" ] || die "uuid: job ID required"
  validate_id "$id"
  ensure_pool_exists

  local meta_file="$POOL_DIR/jobs/$id/meta.json"
  [ -f "$meta_file" ] || die "unknown job ID '$id'"

  local claude_uuid status slot_info
  claude_uuid=$(jq -r '.claude_session_id // "none"' "$meta_file")
  status=$(get_job_status "$id")

  local slot
  slot=$(get_slot_for_job "$id")
  if [ -n "$slot" ]; then
    slot_info="$slot"
  else
    slot_info="none"
  fi

  printf 'claude-uuid: %s | slot: %s | status: %s\n' "$claude_uuid" "$slot_info" "$status"
}

# ---------------------------------------------------------------------------
# cmd_run "$@" — run a custom command script
# ---------------------------------------------------------------------------
# Looks up command scripts in two locations (project-local first):
#   1. .sub-claude/commands/<name>.sh  (project-local, git root or $PWD)
#   2. ~/.sub-claude/commands/<name>.sh (global)
#
# Special flags:
#   --list    List all available commands
#   --help    Show usage for cmd_run

_run_commands_dirs() {
  local project_dir
  project_dir=$(get_project_dir)
  # Project-local first (higher priority)
  printf '%s/.sub-claude/commands\n' "$project_dir"
  # Global fallback
  printf '%s/.sub-claude/commands\n' "$HOME"
}

_run_find_command() {
  local name="$1"
  local dir
  while IFS= read -r dir; do
    local script="$dir/${name}.sh"
    if [[ -f "$script" && -x "$script" ]]; then
      printf '%s\n' "$script"
      return 0
    fi
  done < <(_run_commands_dirs)
  return 1
}

_run_list_commands() {
  # Two-pass: collect entries first to calculate column width, then print
  local entries=()
  local max_name_len=0
  local dir
  while IFS= read -r dir; do
    if [[ -d "$dir" ]]; then
      local label
      if [[ "$dir" == "$HOME/.sub-claude/commands" ]]; then
        label="global"
      else
        label="project"
      fi
      local script
      for script in "$dir"/*.sh; do
        [[ -f "$script" && -x "$script" ]] || continue
        local name desc
        name=$(basename "$script" .sh)
        desc=$(sed -n 's/^# *[Dd]escription: *//p' "$script" | head -1)
        entries+=("${name}	${label}	${desc}")
        (( ${#name} > max_name_len )) && max_name_len=${#name}
      done
    fi
  done < <(_run_commands_dirs)

  if [[ ${#entries[@]} -eq 0 ]]; then
    printf 'No commands found.\n' >&2
    printf 'Create scripts in ~/.sub-claude/commands/ or .sub-claude/commands/\n' >&2
    printf 'See: sub-claude help run\n' >&2
    return 1
  fi

  local width=$(( max_name_len + 2 ))
  (( width < 20 )) && width=20
  local entry
  for entry in "${entries[@]}"; do
    local name label desc
    IFS=$'\t' read -r name label desc <<< "$entry"
    if [[ -n "$desc" ]]; then
      printf "  %-${width}s (%s) %s\n" "$name" "$label" "$desc"
    else
      printf "  %-${width}s (%s)\n" "$name" "$label"
    fi
  done
}

cmd_run() {
  # Handle -- to stop flag parsing
  local _stop_flags=0
  if [[ "${1:-}" == "--" ]]; then
    _stop_flags=1
    shift
  fi

  local name="${1:-}"

  if [[ "$_stop_flags" -eq 0 ]]; then
    case "$name" in
      --list|-l)
        _run_list_commands
        return
        ;;
      --help|-h|'')
        cat <<'USAGE'
Usage: sub-claude run <command> [args...]

Run a custom command script.

Commands are looked up in order:
  1. .sub-claude/commands/<name>.sh  (project-local)
  2. ~/.sub-claude/commands/<name>.sh (global)

Options:
  --list, -l    List available commands
  --help, -h    Show this help

Creating commands:
  See docs/custom-commands.md or run a command like:

    #!/usr/bin/env bash
    # Description: Review staged git changes
    diff=$(git diff --cached)
    sub-claude -v response start "Review this diff:\n$diff" --block
USAGE
      return
      ;;
    esac
  fi

  shift

  # Validate command name: must start with letter/digit (no leading hyphens that
  # could collide with flags), followed by letters, digits, hyphens, underscores.
  if [[ -z "$name" ]]; then
    die "missing command name — run 'sub-claude run --help' for usage"
  fi
  if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
    die "invalid command name '$name' — must start with a letter or digit, then letters, digits, hyphens, underscores"
  fi

  local script
  if ! script=$(_run_find_command "$name"); then
    die "unknown command '$name' — run 'sub-claude run --list' to see available commands"
  fi

  exec "$script" "$@"
}
