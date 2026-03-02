# shellcheck shell=bash
# shellcheck disable=SC2153
# pool.sh — pool lifecycle management and background watcher
#
# Sourced after core.sh and tmux.sh. Relies on:
#   POOL_DIR, TMUX_SOCKET, resolve_pool_dir, gen_id, pool_log,
#   with_pool_lock, read_pool_json, update_pool_json,
#   tmux_cmd, slot_target, write_slot_wrapper, init_tmux_server,
#   create_slot_pane, accept_trust_prompt, extract_uuid,
#   setup_pipe_pane, send_slash_clear, is_pane_alive,
#   capture_pane, die, warn

# ---------------------------------------------------------------------------
# pool_init
# ---------------------------------------------------------------------------

pool_init() {
  # Check for old claude-pool artifacts (#11)
  _check_old_claude_pool

  local pool_size=5

  while [ $# -gt 0 ]; do
    case "$1" in
      --size)
        pool_size="$2"
        shift 2
        ;;
      *)
        die "pool init: unknown argument '$1'"
        ;;
    esac
  done

  # Validate pool size
  case "$pool_size" in
    ''|*[!0-9]*|0) die "pool init: size must be a positive integer (got '$pool_size')" ;;
  esac

  # Check for existing pool
  if [ -f "$POOL_DIR/pool.json" ]; then
    die "pool already initialized"
  fi

  # Create directory structure
  mkdir -p "$POOL_DIR/slots" "$POOL_DIR/jobs" "$POOL_DIR/queue"

  local project_dir
  project_dir=$(get_project_dir)

  # Build initial slots JSON array
  local slots_json="["
  local i=0
  while [ "$i" -lt "$pool_size" ]; do
    [ "$i" -gt 0 ] && slots_json="$slots_json,"
    slots_json="$slots_json
    {\"index\": $i, \"status\": \"starting\", \"job_id\": null, \"claude_session_id\": null, \"last_used_at\": null}"
    i=$(( i + 1 ))
  done
  slots_json="$slots_json
  ]"

  # Write initial pool.json
  jq -n \
    --arg project_dir "$project_dir" \
    --arg tmux_socket "$TMUX_SOCKET" \
    --argjson pool_size "$pool_size" \
    --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson slots "$slots_json" \
    '{
      version: 1,
      project_dir: $project_dir,
      tmux_socket: $tmux_socket,
      pool_size: $pool_size,
      created_at: $created_at,
      queue_seq: 0,
      slots: $slots,
      pins: {}
    }' > "$POOL_DIR/pool.json"

  # Write slot wrappers
  i=0
  while [ "$i" -lt "$pool_size" ]; do
    write_slot_wrapper "$i" "$POOL_DIR" "$project_dir"
    i=$(( i + 1 ))
  done

  # Start tmux server with slot 0
  init_tmux_server "$POOL_DIR/slots/0/run.sh"

  # Create remaining slot panes
  i=1
  while [ "$i" -lt "$pool_size" ]; do
    create_slot_pane "$i" "$POOL_DIR/slots/$i/run.sh"
    i=$(( i + 1 ))
  done

  # Setup pipe-pane for all slots
  i=0
  while [ "$i" -lt "$pool_size" ]; do
    setup_pipe_pane "$i"
    i=$(( i + 1 ))
  done

  # Initialize each slot in parallel: accept trust prompt, extract uuid, mark fresh
  i=0
  while [ "$i" -lt "$pool_size" ]; do
    (
      set +e  # don't die on trust prompt timeout (may be auto-accepted)
      local slot="$i"
      accept_trust_prompt "$slot" || true
      local uuid
      uuid=$(extract_uuid "$slot")
      if [ -n "$uuid" ]; then
        with_pool_lock _locked_update_slot_fresh "$slot" "$uuid"
        pool_log "init" "slot-$slot: initialized, uuid=$uuid"
      else
        # Mark fresh with empty UUID rather than leaving slot stuck in "starting".
        # The slot is usable — UUID is only needed for /resume after offload.
        with_pool_lock _locked_update_slot_fresh "$slot" ""
        pool_log "init" "slot-$slot: WARNING — initialized without UUID (extract failed)"
      fi
    ) &
    i=$(( i + 1 ))
  done
  wait

  # Mark any slots still in "starting" as error (init failed — watcher will recover them)
  i=0
  while [ "$i" -lt "$pool_size" ]; do
    local s
    s=$(read_pool_json | jq -r --argjson idx "$i" '.slots[] | select(.index == $idx) | .status')
    if [ "$s" = "starting" ]; then
      with_pool_lock _pool_set_slot_status "$i" "error"
      pool_log "init" "slot-$i: still starting after init, marking error for recovery"
    fi
    i=$((i + 1))
  done

  # Start watcher
  watcher_start

  pool_log "init" "pool initialized ($pool_size slots)"
  printf 'pool initialized (%d slots)\n' "$pool_size"
}

# _pool_mark_slot_fresh — alias for _locked_update_slot_fresh (defined in core.sh)
# Kept as a comment for documentation; actual implementation is in core.sh.

# ---------------------------------------------------------------------------
# pool_stop
# ---------------------------------------------------------------------------

pool_stop() {
  ensure_pool_exists

  # Kill watcher
  local watcher_pid_file="$POOL_DIR/watcher.pid"
  if [ -f "$watcher_pid_file" ]; then
    local watcher_pid
    watcher_pid=$(cat "$watcher_pid_file" 2>/dev/null || true)
    if [ -n "$watcher_pid" ] && kill -0 "$watcher_pid" 2>/dev/null; then
      kill "$watcher_pid" 2>/dev/null || true
    fi
    rm -f "$watcher_pid_file"
  fi

  # Kill tmux server
  tmux_cmd kill-server 2>/dev/null || true

  # Remove state directory so pool init works again.
  # Safety: refuse to rm -rf anything that isn't a non-empty absolute path
  # with at least 3 components (e.g. /a/b/c).
  case "$POOL_DIR" in
    /*/*/?*) ;;
    *) die "refusing to remove unexpected POOL_DIR: $POOL_DIR" ;;
  esac
  rm -rf "$POOL_DIR"

  printf 'pool stopped\n'
}

# ---------------------------------------------------------------------------
# pool_status
# ---------------------------------------------------------------------------

pool_status() {
  ensure_pool_exists

  local pool_json
  pool_json=$(read_pool_json)

  local socket pool_size
  socket=$(printf '%s' "$pool_json" | jq -r '.tmux_socket')
  pool_size=$(printf '%s' "$pool_json" | jq -r '.pool_size')

  # Watcher status
  local watcher_state="stopped"
  if is_pool_running; then
    watcher_state="running"
  fi

  printf 'Pool: %s (%d slots, watcher %s)\n\n' "$socket" "$pool_size" "$watcher_state"

  # Slots
  printf 'Slots:\n'
  local slot_count
  slot_count=$(printf '%s' "$pool_json" | jq '.slots | length')
  local i=0
  while [ "$i" -lt "$slot_count" ]; do
    local slot_json status job_id
    slot_json=$(printf '%s' "$pool_json" | jq --argjson idx "$i" '.slots[] | select(.index == $idx)')
    status=$(printf '%s' "$slot_json" | jq -r '.status')
    job_id=$(printf '%s' "$slot_json" | jq -r '.job_id // empty')

    if [ -n "$job_id" ] && [ -f "$POOL_DIR/jobs/$job_id/meta.json" ]; then
      local prompt
      prompt=$(jq -r '.prompt // ""' "$POOL_DIR/jobs/$job_id/meta.json" 2>/dev/null | head -c 50)
      printf '  %d  %-16s %-10s %s\n' "$i" "$status" "$job_id" "$prompt"
    else
      printf '  %d  %s\n' "$i" "$status"
    fi
    i=$(( i + 1 ))
  done

  # Queue
  printf '\n'
  # Use a glob-safe approach
  local queue_count=0
  local -a queue_entries=()
  if [ -d "$POOL_DIR/queue" ]; then
    for f in "$POOL_DIR/queue"/*.json; do
      [ -f "$f" ] || break
      queue_count=$(( queue_count + 1 ))
      queue_entries+=("$f")
    done
  fi

  printf 'Queue: %d pending\n' "$queue_count"
  if [ "$queue_count" -gt 0 ]; then
    for f in "${queue_entries[@]}"; do
      local qjob_id qprompt qseq
      qjob_id=$(jq -r '.job_id // ""' "$f" 2>/dev/null)
      qprompt=$(jq -r '.prompt // ""' "$f" 2>/dev/null | head -c 50)
      qseq=$(basename "$f" .json | cut -d'-' -f1)
      printf '  %s  %-10s %s\n' "$qseq" "$qjob_id" "$qprompt"
    done
  fi

  # Pins
  printf '\n'
  local now pin_count
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  pin_count=$(printf '%s' "$pool_json" | jq --arg now "$now" \
    '[.pins | to_entries[] | select(.value > $now)] | length')

  printf 'Pins: %d active\n' "$pin_count"
  if [ "$pin_count" -gt 0 ]; then
    printf '%s' "$pool_json" | jq -r --arg now "$now" \
      '.pins | to_entries[] | select(.value > $now) | [.key, .value] | @tsv' \
    | while IFS=$'\t' read -r pin_id deadline; do
        # Compute seconds remaining
        local deadline_epoch now_epoch remaining
        if date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$deadline" +%s >/dev/null 2>&1; then
          # macOS BSD date — must use -u since deadline is stored as UTC
          deadline_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$deadline" +%s 2>/dev/null)
        else
          # GNU date
          deadline_epoch=$(date -d "$deadline" +%s 2>/dev/null)
        fi
        now_epoch=$(date +%s)
        remaining=$(( deadline_epoch - now_epoch ))
        printf '  %-10s expires in %ds\n' "$pin_id" "$remaining"
      done
  fi
}

# ---------------------------------------------------------------------------
# pool_resize
# ---------------------------------------------------------------------------

pool_resize() {
  ensure_pool_exists
  local new_size="${1:-}"
  [ -z "$new_size" ] && die "pool resize: size argument required"
  case "$new_size" in
    *[!0-9]*|0) die "pool resize: size must be a positive integer (got '$new_size')" ;;
  esac

  local pool_json_snap current_size project_dir
  pool_json_snap=$(read_pool_json)
  current_size=$(printf '%s' "$pool_json_snap" | jq -r '.pool_size')
  project_dir=$(printf '%s' "$pool_json_snap" | jq -r '.project_dir')

  if [ "$new_size" -gt "$current_size" ]; then
    # Growing: add new slots
    local i="$current_size"
    while [ "$i" -lt "$new_size" ]; do
      # Add slot entry to pool.json as "starting"
      with_pool_lock _pool_add_slot_entry "$i"

      write_slot_wrapper "$i" "$POOL_DIR" "$project_dir"
      create_slot_pane "$i" "$POOL_DIR/slots/$i/run.sh"
      setup_pipe_pane "$i"

      (
        set +e  # don't die on trust prompt timeout (may be auto-accepted)
        local slot="$i"
        accept_trust_prompt "$slot" || true
        local uuid
        uuid=$(extract_uuid "$slot")
        if [ -z "$uuid" ]; then
          pool_log "resize" "slot-$slot: UUID extraction failed, retrying..."
          sleep 3
          uuid=$(extract_uuid "$slot")
        fi
        with_pool_lock _locked_update_slot_fresh "$slot" "$uuid"
        if [ -z "$uuid" ]; then
          pool_log "resize" "slot-$slot: WARNING — added without UUID (extract failed)"
        else
          pool_log "resize" "slot-$slot: added and initialized, uuid=$uuid"
        fi
      ) &

      i=$(( i + 1 ))
    done
    wait

    # Mark any slots still in "starting" as error (init failed — watcher will recover them)
    i="$current_size"
    while [ "$i" -lt "$new_size" ]; do
      local s
      s=$(read_pool_json | jq -r --argjson idx "$i" '.slots[] | select(.index == $idx) | .status')
      if [ "$s" = "starting" ]; then
        with_pool_lock _pool_set_slot_status "$i" "error"
        pool_log "resize" "slot-$i: still starting after init, marking error for recovery"
      fi
      i=$((i + 1))
    done

    with_pool_lock _pool_set_size "$new_size"
    pool_log "resize" "pool grown to $new_size slots"
    printf 'pool resized to %d slots\n' "$new_size"

  elif [ "$new_size" -lt "$current_size" ]; then
    # Shrinking: mark excess slots as decommissioning
    local i="$new_size"
    while [ "$i" -lt "$current_size" ]; do
      with_pool_lock _pool_set_slot_status "$i" "decommissioning"
      pool_log "resize" "slot-$i: marked decommissioning"
      i=$(( i + 1 ))
    done

    with_pool_lock _pool_set_size "$new_size"
    pool_log "resize" "pool shrinking to $new_size slots (excess slots decommissioning)"
    printf 'pool shrinking to %d slots (excess slots will be freed as they become idle)\n' "$new_size"
  else
    printf 'pool already at %d slots\n' "$new_size"
  fi
}

# _pool_add_slot_entry <slot>
# Appends a new slot entry. Must be called under with_pool_lock.
_pool_add_slot_entry() {
  local slot="$1"
  read_pool_json | jq \
    --argjson idx "$slot" \
    '.slots += [{"index": $idx, "status": "starting", "job_id": null, "claude_session_id": null, "last_used_at": null}]' \
    | update_pool_json
}

# _pool_set_size <n>
# Update pool_size. Must be called under with_pool_lock.
_pool_set_size() {
  local n="$1"
  read_pool_json | jq --argjson n "$n" '.pool_size = $n' | update_pool_json
}

# _pool_set_slot_status <slot> <status>
# Must be called under with_pool_lock.
_pool_set_slot_status() {
  local slot="$1" status="$2"
  read_pool_json | jq \
    --argjson idx "$slot" \
    --arg st "$status" \
    '.slots |= map(if .index == $idx then .status = $st else . end)' \
    | update_pool_json
}

# ---------------------------------------------------------------------------
# watcher_start
# ---------------------------------------------------------------------------

watcher_start() {
  # Launch watcher_loop as a detached background process.
  # set +e: watcher must not die on transient failures (jq errors, tmux hiccups).
  # exec </dev/null redirects stdin away from any terminal.
  (
    set +e
    exec </dev/null >>"$POOL_DIR/pool.log" 2>&1
    watcher_loop
  ) &
  echo $! > "$POOL_DIR/watcher.pid"
  disown
}

# ---------------------------------------------------------------------------
# watcher_loop
# ---------------------------------------------------------------------------

watcher_loop() {
  while true; do
    local do_recover=0

    # Phase 0: collect pane liveness OUTSIDE the lock (tmux I/O is slow)
    local pane_alive_map=""
    local slot_count
    slot_count=$(jq '.slots | length' "$POOL_DIR/pool.json" 2>/dev/null || echo 0)
    local _i=0
    while [ "$_i" -lt "$slot_count" ]; do
      if is_pane_alive "$_i" 2>/dev/null; then
        pane_alive_map="${pane_alive_map}${_i}:1 "
      else
        pane_alive_map="${pane_alive_map}${_i}:0 "
      fi
      _i=$((_i + 1))
    done

    # Phase 1: quick state updates under lock (no tmux I/O)
    do_recover=$(with_pool_lock _watcher_phase1 "$pane_alive_map")

    # Phase 2: queue dispatch (handles its own locking)
    dispatch_queue 2>>"$POOL_DIR/pool.log" || true

    # Phase 2b: crash recovery if needed (no lock for tmux ops)
    if [ "${do_recover:-0}" = "1" ]; then
      _watcher_recover_crashed_slots
    fi

    # Phase 2c: clean up decommissioning slots (no lock for tmux ops)
    _watcher_cleanup_decommissioning

    sleep 2
  done
}

# _watcher_cleanup_decommissioning — kill decommissioning slot panes and remove entries.
_watcher_cleanup_decommissioning() {
  local pool_json
  pool_json=$(read_pool_json)
  local decomm_slots
  decomm_slots=$(printf '%s' "$pool_json" | jq -r '.slots[] | select(.status == "decommissioning") | .index' 2>/dev/null)
  [ -n "$decomm_slots" ] || return 0

  for slot in $decomm_slots; do
    # If slot has an active job, skip — wait until it becomes idle
    local slot_job
    slot_job=$(printf '%s' "$pool_json" | jq -r --argjson idx "$slot" '.slots[] | select(.index == $idx) | .job_id // empty')
    if [ -n "$slot_job" ]; then
      local job_status
      job_status=$(jq -r '.status // empty' "$POOL_DIR/jobs/$slot_job/meta.json" 2>/dev/null)
      if [ "$job_status" = "processing" ]; then
        continue  # still busy, wait
      fi
    fi

    # Kill the tmux pane
    tmux_cmd kill-window -t "$(slot_target "$slot")" 2>/dev/null || true

    # Remove slot entry under lock
    with_pool_lock _locked_remove_slot "$slot"

    pool_log "watcher" "slot-$slot: decommissioned and removed"
  done
}

# _watcher_phase1
# Called under with_pool_lock. Reads pool state, updates it, and prints "1"
# to stdout if crash recovery should be triggered.
_watcher_phase1() {
  local pane_alive_map="${1:-}"

  local pool_json
  pool_json=$(read_pool_json)

  # Validate pool.json is readable and valid JSON before parsing
  if [ -z "$pool_json" ] || ! printf '%s' "$pool_json" | jq empty 2>/dev/null; then
    pool_log "watcher" "pool.json unreadable or invalid, skipping cycle"
    printf '0\n'
    return 0
  fi

  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local pool_size error_count slot_count
  pool_size=$(printf '%s' "$pool_json" | jq -r '.pool_size // 0')
  slot_count=$(printf '%s' "$pool_json" | jq '.slots | length')
  error_count=0

  # Helper: check pane liveness from pre-collected map (no tmux I/O under lock)
  # Uses space-delimited matching to avoid substring false positives
  # (e.g., slot 1 matching "11:1" in the map).
  _pane_alive() {
    local idx="$1"
    case " $pane_alive_map" in
      *" $idx:1 "*) return 0 ;;
      *" $idx:0 "*) return 1 ;;
      *) return 1 ;;  # unknown → treat as dead
    esac
  }

  local i=0
  while [ "$i" -lt "$slot_count" ]; do
    local slot_status slot_job_id
    slot_status=$(printf '%s' "$pool_json" | jq -r --argjson idx "$i" '.slots[] | select(.index == $idx) | .status')
    slot_job_id=$(printf '%s' "$pool_json" | jq -r --argjson idx "$i" '.slots[] | select(.index == $idx) | .job_id // empty')

    case "$slot_status" in
      busy)
        # Check for done file
        local done_file="$POOL_DIR/slots/$i/done"
        if [ -f "$done_file" ]; then
          # Safe to update unconditionally: this function runs under
          # with_pool_lock, so the snapshot IS the live state. If
          # _stop_single_job already ran, the slot won't be "busy" and
          # this case branch won't fire.
          pool_json=$(printf '%s' "$pool_json" | jq \
            --argjson idx "$i" \
            --arg ts "$now" \
            '.slots |= map(
              if .index == $idx then
                .status = "idle" | .last_used_at = $ts
              else . end
            )')
          # Update job status to completed
          if [ -n "$slot_job_id" ] && [ -f "$POOL_DIR/jobs/$slot_job_id/meta.json" ]; then
            local meta_tmp
            meta_tmp=$(jq '.status = "completed"' "$POOL_DIR/jobs/$slot_job_id/meta.json")
            printf '%s' "$meta_tmp" > "$POOL_DIR/jobs/$slot_job_id/meta.json.tmp"
            mv "$POOL_DIR/jobs/$slot_job_id/meta.json.tmp" "$POOL_DIR/jobs/$slot_job_id/meta.json"
          fi
          # NOTE: do NOT delete the done file here. wait_for_done (used by
          # --block and wait) also polls for it. Deleting it here creates a
          # race where the watcher consumes the signal before wait_for_done
          # sees it, forcing a 30s idle fallback. The done file is cleared
          # by _locked_claim_and_dispatch (under the lock) before each new prompt.
          pool_log "watcher" "slot-$i: done file detected, busy -> idle"

        # Check pane liveness from pre-collected map
        elif ! _pane_alive "$i"; then
          pool_json=$(printf '%s' "$pool_json" | jq \
            --argjson idx "$i" \
            '.slots |= map(if .index == $idx then .status = "error" else . end)')
          # Mark job as error
          if [ -n "$slot_job_id" ] && [ -f "$POOL_DIR/jobs/$slot_job_id/meta.json" ]; then
            local meta_tmp
            meta_tmp=$(jq '.status = "error"' "$POOL_DIR/jobs/$slot_job_id/meta.json")
            printf '%s' "$meta_tmp" > "$POOL_DIR/jobs/$slot_job_id/meta.json.tmp"
            mv "$POOL_DIR/jobs/$slot_job_id/meta.json.tmp" "$POOL_DIR/jobs/$slot_job_id/meta.json"
          fi
          pool_log "watcher" "slot-$i: pane dead, marking error"
          error_count=$(( error_count + 1 ))
        fi
        ;;

      fresh|idle)
        # Check pane liveness from pre-collected map
        if ! _pane_alive "$i"; then
          pool_json=$(printf '%s' "$pool_json" | jq \
            --argjson idx "$i" \
            '.slots |= map(if .index == $idx then .status = "error" else . end)')
          pool_log "watcher" "slot-$i: pane dead ($slot_status), marking error"
          error_count=$(( error_count + 1 ))
        fi
        ;;

      starting)
        # Detect stale "starting" slots — if run.sh exists and is older than
        # 90s, the init subshell likely failed without marking the slot.
        local run_sh="$POOL_DIR/slots/$i/run.sh"
        if [ -f "$run_sh" ]; then
          local now_epoch run_mtime age
          now_epoch=$(date +%s)
          run_mtime="$now_epoch"  # default: if stat fails (file deleted race), age=0 → skip
          if stat -f %m "$run_sh" >/dev/null 2>&1; then
            # macOS BSD stat
            run_mtime=$(stat -f %m "$run_sh")
          else
            # GNU stat
            run_mtime=$(stat -c %Y "$run_sh" 2>/dev/null || echo "$now_epoch")
          fi
          age=$(( now_epoch - run_mtime ))
          if [ "$age" -gt 90 ]; then
            pool_json=$(printf '%s' "$pool_json" | jq \
              --argjson idx "$i" \
              '.slots |= map(if .index == $idx then .status = "error" else . end)')
            pool_log "watcher" "slot-$i: stuck in starting for ${age}s, marking error for recovery"
            error_count=$(( error_count + 1 ))
          fi
        fi
        ;;

      decommissioning)
        # Slot marked for removal during resize — just track it. The tmux pane
        # will be killed outside the lock by the watcher after this phase.
        ;;

      error)
        error_count=$(( error_count + 1 ))
        ;;
    esac

    i=$(( i + 1 ))
  done

  # Expire pins past deadline
  pool_json=$(printf '%s' "$pool_json" | jq \
    --arg now "$now" \
    '.pins |= with_entries(select(.value > $now))')

  # Write updated state
  printf '%s' "$pool_json" | update_pool_json

  # Signal recovery if >= 1/4 slots are in error
  local threshold=$(( pool_size / 4 ))
  [ "$threshold" -lt 1 ] && threshold=1
  if [ "$error_count" -ge "$threshold" ]; then
    printf '1\n'
  else
    printf '0\n'
  fi
}

# _watcher_recover_crashed_slots
# Recover all slots currently in error state. No lock held (tmux ops are slow).
_watcher_recover_crashed_slots() {
  local pool_json
  pool_json=$(read_pool_json)

  local project_dir
  project_dir=$(printf '%s' "$pool_json" | jq -r '.project_dir')

  local error_slots
  error_slots=$(printf '%s' "$pool_json" | jq -r '.slots[] | select(.status == "error") | .index')

  local count=0
  for slot in $error_slots; do
    count=$(( count + 1 ))
    pool_log "watcher" "crash recovery: restarting slot-$slot"

    # Kill dead pane remnant
    tmux_cmd kill-window -t "$(slot_target "$slot")" 2>/dev/null || true

    # Write new wrapper and create fresh pane
    write_slot_wrapper "$slot" "$POOL_DIR" "$project_dir"
    create_slot_pane "$slot" "$POOL_DIR/slots/$slot/run.sh"
    setup_pipe_pane "$slot"

    # Mark as starting
    with_pool_lock _pool_set_slot_status "$slot" "starting"

    # Accept trust prompt, extract UUID, mark fresh
    set +e  # don't die on trust prompt timeout (may be auto-accepted)
    accept_trust_prompt "$slot" || true
    local uuid
    uuid=$(extract_uuid "$slot")
    if [ -z "$uuid" ]; then
      pool_log "watcher" "crash recovery: slot-$slot UUID extraction failed, retrying..."
      sleep 3
      uuid=$(extract_uuid "$slot")
    fi
    if [ -n "$uuid" ]; then
      with_pool_lock _locked_update_slot_fresh "$slot" "$uuid"
      pool_log "watcher" "crash recovery: slot-$slot restarted, uuid=$uuid"
    else
      with_pool_lock _pool_set_slot_status "$slot" "error"
      pool_log "watcher" "crash recovery: slot-$slot FAILED — could not extract UUID"
    fi
  done

  if [ "$count" -gt 0 ]; then
    pool_log "watcher" "crash recovery: restarted $count slots"
  fi
}

# ---------------------------------------------------------------------------
# pool_list (#10)
# ---------------------------------------------------------------------------

pool_list() {
  local found=0

  if [ ! -d "$SUB_CLAUDE_STATE_DIR" ]; then
    printf 'no pools found\n'
    return 0
  fi

  for pool_json_file in "$SUB_CLAUDE_STATE_DIR"/*/pool.json; do
    [ -f "$pool_json_file" ] || break

    local pool_path hash project_dir pool_size tmux_socket watcher_state
    pool_path="$(dirname "$pool_json_file")"
    hash="$(basename "$pool_path")"

    project_dir=$(jq -r '.project_dir // "unknown"' "$pool_json_file" 2>/dev/null)
    pool_size=$(jq -r '.pool_size // 0' "$pool_json_file" 2>/dev/null)
    tmux_socket=$(jq -r '.tmux_socket // ""' "$pool_json_file" 2>/dev/null)

    # Check watcher status
    watcher_state="stopped"
    local watcher_pid_file="$pool_path/watcher.pid"
    if [ -f "$watcher_pid_file" ]; then
      local watcher_pid
      watcher_pid=$(cat "$watcher_pid_file" 2>/dev/null)
      if [ -n "$watcher_pid" ] && kill -0 "$watcher_pid" 2>/dev/null; then
        watcher_state="running"
      fi
    fi

    if [ "$found" -eq 0 ]; then
      printf '%-10s  %-6s  %-8s  %s\n' "HASH" "SLOTS" "WATCHER" "PROJECT"
    fi
    printf '%-10s  %-6s  %-8s  %s\n' "$hash" "$pool_size" "$watcher_state" "$project_dir"
    found=$(( found + 1 ))
  done

  if [ "$found" -eq 0 ]; then
    printf 'no pools found\n'
  fi
}

# ---------------------------------------------------------------------------
# pool_destroy (#10)
# ---------------------------------------------------------------------------

pool_destroy() {
  local target="${1:-}"

  if [ -z "$target" ]; then
    die "usage: sub-claude pool destroy <hash> | --all"
  fi

  if [ "$target" = "--all" ]; then
    _pool_destroy_all
    return $?
  fi

  _pool_destroy_one "$target"
}

_pool_destroy_one() {
  local hash="$1"
  # Validate hash — only hex characters, no path separators
  case "$hash" in
    *[!0-9a-f]*|'') die "invalid pool hash: '$hash'" ;;
  esac
  local pool_path="$SUB_CLAUDE_STATE_DIR/$hash"

  if [ ! -d "$pool_path" ] || [ ! -f "$pool_path/pool.json" ]; then
    die "no pool found with hash '$hash'"
  fi

  local tmux_socket
  tmux_socket=$(jq -r '.tmux_socket // ""' "$pool_path/pool.json" 2>/dev/null)

  # Kill watcher
  local watcher_pid_file="$pool_path/watcher.pid"
  if [ -f "$watcher_pid_file" ]; then
    local watcher_pid
    watcher_pid=$(cat "$watcher_pid_file" 2>/dev/null || true)
    if [ -n "$watcher_pid" ] && kill -0 "$watcher_pid" 2>/dev/null; then
      kill "$watcher_pid" 2>/dev/null || true
    fi
  fi

  # Kill tmux server
  if [ -n "$tmux_socket" ]; then
    tmux -L "$tmux_socket" kill-server 2>/dev/null || true
  fi

  # Safety: refuse to rm -rf anything that isn't a non-empty absolute path
  # with at least 3 components (e.g. /a/b/c).
  case "$pool_path" in
    /*/*/?*) ;;
    *) die "refusing to remove unexpected pool path: $pool_path" ;;
  esac
  rm -rf "$pool_path"

  printf 'pool %s destroyed\n' "$hash"
}

_pool_destroy_all() {
  if [ ! -d "$SUB_CLAUDE_STATE_DIR" ]; then
    printf 'no pools to destroy\n'
    return 0
  fi

  local count=0
  for pool_json_file in "$SUB_CLAUDE_STATE_DIR"/*/pool.json; do
    [ -f "$pool_json_file" ] || break
    local pool_path hash
    pool_path="$(dirname "$pool_json_file")"
    hash="$(basename "$pool_path")"
    _pool_destroy_one "$hash"
    count=$(( count + 1 ))
  done

  if [ "$count" -eq 0 ]; then
    printf 'no pools to destroy\n'
  else
    printf '%d pool(s) destroyed\n' "$count"
  fi
}

# ---------------------------------------------------------------------------
# _check_old_claude_pool (#11 — migration warning)
# ---------------------------------------------------------------------------

_check_old_claude_pool() {
  if [ -d "$HOME/.claude-pool" ]; then
    warn "found old claude-pool data at ~/.claude-pool/ — run 'sub-claude pool migrate' to clean up"
  fi
}

# ---------------------------------------------------------------------------
# pool_migrate (#11)
# ---------------------------------------------------------------------------

pool_migrate() {
  local cleaned=0

  # Kill any running claude-pool tmux servers
  local old_sockets
  old_sockets=$(tmux list-servers -F '#{socket_path}' 2>/dev/null | grep 'claude-pool-' || true)
  if [ -n "$old_sockets" ]; then
    while IFS= read -r sock; do
      local sock_name
      sock_name=$(basename "$sock")
      tmux -L "$sock_name" kill-server 2>/dev/null || true
      cleaned=$(( cleaned + 1 ))
    done <<< "$old_sockets"
  fi

  # Kill old claude-pool watcher processes
  # Use [c] bracket trick to prevent pgrep from matching its own command line
  local old_pids
  old_pids=$(pgrep -f '[c]laude-pool' 2>/dev/null | grep -v "^$$\$" || true)
  if [ -n "$old_pids" ]; then
    while IFS= read -r pid; do
      kill "$pid" 2>/dev/null || true
      cleaned=$(( cleaned + 1 ))
    done <<< "$old_pids"
  fi

  # Remove old data directory
  local old_data="$HOME/.claude-pool"
  if [ -d "$old_data" ]; then
    case "$old_data" in
      /*/*/?*) ;;
      *) die "refusing to remove unexpected path: $old_data" ;;
    esac
    rm -rf "$old_data"
    printf 'removed %s\n' "$old_data"
    cleaned=$(( cleaned + 1 ))
  fi

  # Remove old binary
  if [ -f "$HOME/.local/bin/claude-pool" ]; then
    rm -f "$HOME/.local/bin/claude-pool"
    printf 'removed %s\n' "$HOME/.local/bin/claude-pool"
    cleaned=$(( cleaned + 1 ))
  fi

  if [ "$cleaned" -eq 0 ]; then
    printf 'nothing to clean up — already migrated\n'
  else
    printf 'migration complete: cleaned %d item(s)\n' "$cleaned"
  fi
}
