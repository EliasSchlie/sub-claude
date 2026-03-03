# shellcheck shell=bash
# =============================================================================
# sub-claude: core.sh — Foundational helpers library
# =============================================================================
# Sourced by all other sub-claude modules and the main dispatcher.
# Do NOT add a shebang — this file is sourced, never executed directly.
#
# Provides:
#   - Constants (version, max depth, state dir)
#   - Path/hash helpers (project_hash, get_project_dir, resolve_pool_dir)
#   - ID helpers (gen_id, validate_id)
#   - Session identity (get_parent_session_id)
#   - Logging (pool_log, die, warn)
#   - Locking (with_pool_lock)
#   - Pool state I/O (read_pool_json, update_pool_json, get/update_job_meta)
#   - Job status derivation (get_job_status, get_slot_for_job)
#   - Depth tracking (derive_depth)
#   - Pool health checks (ensure_pool_exists, is_pool_running)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# shellcheck disable=SC2034  # used by other modules that source this file
SUB_CLAUDE_VERSION=1
SUB_CLAUDE_MAX_DEPTH=5
SUB_CLAUDE_DEFAULT_POOL_SIZE=5
SUB_CLAUDE_AGENT_PREFIX="You are a sub-Claude agent."
SUB_CLAUDE_STATE_DIR="${SUB_CLAUDE_STATE_DIR:-$HOME/.sub-claude/pools}"
case "$SUB_CLAUDE_STATE_DIR" in
  /*) ;;
  *)  printf 'error: SUB_CLAUDE_STATE_DIR must be an absolute path (got %s)\n' "$SUB_CLAUDE_STATE_DIR" >&2; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# Path / hash helpers
# ---------------------------------------------------------------------------

# project_hash() — hash a path to 8-char hex.
# Uses md5 on macOS (md5 -q), md5sum on Linux. Returns first 8 hex chars.
project_hash() {
  local h
  h=$(printf '%s' "$1" | (md5 -q 2>/dev/null || md5sum | cut -d' ' -f1) | head -c8)
  if [ -z "$h" ]; then
    printf 'error: no md5 tool found (need md5 or md5sum)\n' >&2
    return 1
  fi
  printf '%s' "$h"
}

# get_project_dir() — return git root if inside a repo, otherwise $PWD.
get_project_dir() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

# resolve_pool_dir() — set POOL_DIR and TMUX_SOCKET globals.
#
# Resolution order:
#   1. Project-local pool: $SUB_CLAUDE_STATE_DIR/<hash> (if pool.json exists)
#   2. Root pool: $SUB_CLAUDE_STATE_DIR/_root (shared default)
#
# The -C <dir> flag (handled before this is called) overrides get_project_dir,
# so -C naturally targets a different project-local pool.
#
# Call once at startup; all other functions rely on POOL_DIR being set.
resolve_pool_dir() {
  local project_dir hash
  project_dir=$(get_project_dir)
  hash=$(project_hash "$project_dir")

  # Check for project-local pool first
  if [ -f "$SUB_CLAUDE_STATE_DIR/$hash/pool.json" ]; then
    POOL_DIR="$SUB_CLAUDE_STATE_DIR/$hash"
    TMUX_SOCKET="sub-claude-$hash"
    return
  fi

  # Fall back to root pool
  POOL_DIR="$SUB_CLAUDE_STATE_DIR/_root"
  TMUX_SOCKET="sub-claude-root"
}

# is_root_pool() — return 0 if current POOL_DIR is the root pool.
is_root_pool() {
  [ "$POOL_DIR" = "$SUB_CLAUDE_STATE_DIR/_root" ]
}

# _cwd_prefix <cwd>
# For root pool: print the cwd instruction prefix to prepend to a prompt.
# Prints nothing for project-local pools or empty cwd.
_cwd_prefix() {
  local _cwd="$1"
  if is_root_pool && [ -n "$_cwd" ]; then
    printf 'IMPORTANT: First run: cd %s\n' "$(printf '%q' "$_cwd")"
  fi
}

# ---------------------------------------------------------------------------
# ID helpers
# ---------------------------------------------------------------------------

# gen_id() — generate a random 8-char hex ID.
gen_id() {
  xxd -l 4 -p /dev/urandom
}

# validate_id() — assert that $1 is exactly 8 lowercase hex characters.
# Prints an error and exits 1 if the format is wrong.
validate_id() {
  local id="$1"
  case "$id" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
      return 0
      ;;
    *)
      die "invalid job ID '${id}' — expected 8 hex characters (e.g. a1b2c3d4)"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Session identity (process-tree walk)
# ---------------------------------------------------------------------------

# get_parent_session_id() — find the nearest ancestor `claude` process.
#
# Walks the ppid chain from $$ upward. When a process named "claude" is found,
# returns "<pid>-<lstart>" for stable identity even across PID reuse.
# Returns "standalone" if no parent claude process is found.
#
# Uses POSIX ps flags; lstart is BSD/macOS — on Linux it may be blank, which
# is fine: the PID alone is still a useful disambiguator within one boot.
get_parent_session_id() {
  local pid=$$
  while [ "$pid" != "1" ] && [ -n "$pid" ]; do
    local cmd
    cmd=$(ps -o comm= -p "$pid" 2>/dev/null) || break

    if [ "$cmd" = "claude" ]; then
      local lstart
      # lstart is macOS/BSD; strip spaces so we get a compact token
      lstart=$(ps -o lstart= -p "$pid" 2>/dev/null | tr -d ' ') || true
      printf '%s-%s\n' "$pid" "$lstart"
      return 0
    fi

    local ppid
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') || break
    # Guard against infinite loop if ppid == pid (shouldn't happen, but be safe)
    [ "$ppid" = "$pid" ] && break
    pid="$ppid"
  done

  printf 'standalone\n'
}

# ---------------------------------------------------------------------------
# Logging / error helpers
# ---------------------------------------------------------------------------

# die() — print "error: <msg>" to stderr and exit 1.
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# warn() — print "warning: <msg>" to stderr (non-fatal).
warn() {
  printf 'warning: %s\n' "$*" >&2
}

# pool_log() — append a timestamped log line to $POOL_DIR/pool.log.
# Usage: pool_log <component> <message...>
# Format: [ISO-timestamp] [component] message
pool_log() {
  local component="$1"; shift
  # POOL_DIR must be set before calling this function.
  printf '[%s] [%s] %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$component" \
    "$*" \
    >> "$POOL_DIR/pool.log"
}

# ---------------------------------------------------------------------------
# Locking
# ---------------------------------------------------------------------------

# with_pool_lock() — run a command under an exclusive file lock on pool.lock.
#
# The lock file is $POOL_DIR/pool.lock. The lock is held only for the
# duration of the command (subshell releases it automatically on exit).
#
# Prefers flock (Linux, Homebrew util-linux on macOS). Falls back to perl
# Fcntl for stock macOS which ships without flock.
#
# Usage: with_pool_lock <cmd> [args...]
with_pool_lock() {
  (
    # Open fd 9 on the lock file inside the subshell so it auto-closes on exit.
    exec 9>"$POOL_DIR/pool.lock"

    if command -v flock >/dev/null 2>&1; then
      flock 9
    else
      # macOS fallback: perl acquires the lock on the SAME open file description
      # as fd 9 (via ">&=" which wraps the fd without duping). The lock is tied
      # to the open file description, which is shared with the subshell. When perl
      # exits, fd 9 remains open in the subshell, so the lock persists until the
      # subshell closes fd 9 (on exit).
      perl -e '
        use Fcntl qw(:flock);
        open(my $fh, ">&=", 9) or die "open fd 9: $!";
        flock($fh, LOCK_EX) or die "flock: $!";
      '
    fi

    "$@"
  )
}

# ---------------------------------------------------------------------------
# Pool state I/O
# ---------------------------------------------------------------------------

# read_pool_json() — print pool.json to stdout.
# Safe for read-only use without the lock; for mutations, hold the lock.
read_pool_json() {
  cat "$POOL_DIR/pool.json"
}

# update_pool_json() — atomically replace pool.json from stdin.
# Write to a temp file then rename to avoid torn reads.
# MUST be called under with_pool_lock.
update_pool_json() {
  local tmp="$POOL_DIR/pool.json.tmp"
  cat > "$tmp"
  mv "$tmp" "$POOL_DIR/pool.json"
}

# get_job_meta() — print a job's meta.json to stdout.
# Usage: get_job_meta <job-id>
get_job_meta() {
  cat "$POOL_DIR/jobs/$1/meta.json"
}

# update_job_meta() — atomically replace a job's meta.json from stdin.
# Usage: update_job_meta <job-id>
# MUST be called under with_pool_lock.
update_job_meta() {
  local id="$1" tmp
  tmp="$POOL_DIR/jobs/$id/meta.json.tmp"
  cat > "$tmp"
  mv "$tmp" "$POOL_DIR/jobs/$id/meta.json"
}

# ---------------------------------------------------------------------------
# Job status derivation
# ---------------------------------------------------------------------------

# get_slot_for_job() — find which slot currently has this job loaded.
# Prints the slot index, or nothing if the job is not loaded in any slot.
# Usage: get_slot_for_job <job-id>
get_slot_for_job() {
  local job_id="$1"
  # Walk slot directories looking for a slot whose current job_id matches.
  jq -r --arg jid "$job_id" \
    '.slots[] | select(.job_id == $jid) | .index' \
    "$POOL_DIR/pool.json" 2>/dev/null
}

# get_job_status() — return the caller-visible status of a job.
#
# Possible return values:
#   queued
#   processing
#   finished(idle)
#   finished(offloaded)
#   error
#
# Reads meta.json and cross-references the slot state in pool.json.
# Usage: get_job_status <job-id>
get_job_status() {
  local job_id="$1"
  local meta_file="$POOL_DIR/jobs/$job_id/meta.json"

  [ -f "$meta_file" ] || die "unknown job ID '$job_id'"

  local meta_status offloaded
  meta_status=$(jq -r '.status // empty' "$meta_file" 2>/dev/null)
  offloaded=$(jq -r '.offloaded // false' "$meta_file" 2>/dev/null)

  case "$meta_status" in
    queued)
      printf 'queued\n'
      ;;
    processing)
      # Double-check slot state; if the slot crashed the job may be in error.
      local slot_index slot_status
      slot_index=$(get_slot_for_job "$job_id")
      if [ -n "$slot_index" ]; then
        slot_status=$(jq -r --argjson idx "$slot_index" \
          '.slots[] | select(.index == $idx) | .status' \
          "$POOL_DIR/pool.json" 2>/dev/null)
        if [ "$slot_status" = "error" ]; then
          printf 'error\n'
          return 0
        fi
      fi
      printf 'processing\n'
      ;;
    completed)
      if [ "$offloaded" = "true" ]; then
        printf 'finished(offloaded)\n'
      else
        printf 'finished(idle)\n'
      fi
      ;;
    error)
      printf 'error\n'
      ;;
    *)
      # Unrecognised or missing status — treat as error
      printf 'error\n'
      ;;
  esac
}


# ---------------------------------------------------------------------------
# Depth tracking
# ---------------------------------------------------------------------------

# derive_depth() — determine the recursion depth for a new job about to be started.
#
# Algorithm:
#   1. get_parent_session_id → identify the caller
#   2. Search pool metadata for an active job owned by that session
#   3. New job depth = parent job depth + 1
#   4. Standalone callers (no parent claude) → depth 0
#   5. depth >= SUB_CLAUDE_MAX_DEPTH → die with an error
#
# Prints the depth integer to stdout on success.
derive_depth() {
  local caller_session
  caller_session=$(get_parent_session_id)

  local parent_depth=0
  local found_in_pool=false

  if [ "$caller_session" != "standalone" ]; then
    # Find any currently active (processing) job whose parent_session matches.
    local found_depth
    found_depth=$(jq -s -r --arg sess "$caller_session" \
      '[ .[] | select(.parent_session == $sess and .status == "processing") | .depth ]
       | if length > 0 then .[0] else empty end' \
      "$POOL_DIR/jobs"/*/meta.json 2>/dev/null | head -1)

    if [ -n "$found_depth" ] && [ "$found_depth" != "null" ]; then
      parent_depth="$found_depth"
      found_in_pool=true
    fi
  fi

  local new_depth=$(( parent_depth + 1 ))

  # Callers that don't occupy a pool slot start at depth 0:
  # - "standalone": no claude ancestor in the process tree
  # - Regular Claude sessions: claude ancestor found but no active job in this
  #   pool — the parent isn't holding a slot, so no deadlock risk.
  if [ "$caller_session" = "standalone" ] || [ "$found_in_pool" = "false" ]; then
    new_depth=0
  fi

  # Effective max depth: the lesser of the hard limit and pool_size - 1.
  # pool_size - 1 ensures at least one slot stays free, preventing deadlock
  # when a recursive chain consumes slots.
  local effective_max="$SUB_CLAUDE_MAX_DEPTH"
  local pool_size
  pool_size=$(read_pool_json | jq -r '.pool_size // 0' 2>/dev/null)
  if [ "$pool_size" -gt 0 ] && [ $(( pool_size - 1 )) -lt "$effective_max" ]; then
    effective_max=$(( pool_size - 1 ))
  fi
  # Always allow at least depth 0 (standalone callers)
  [ "$effective_max" -lt 1 ] && effective_max=1

  if [ "$new_depth" -ge "$effective_max" ]; then
    if [ "$effective_max" -lt "$SUB_CLAUDE_MAX_DEPTH" ]; then
      die "maximum recursion depth ($effective_max) reached — pool size is $pool_size, at most $effective_max levels of nesting allowed to prevent deadlock. Grow the pool with 'sub-claude pool resize N' to allow deeper nesting"
    else
      die "maximum recursion depth ($SUB_CLAUDE_MAX_DEPTH) reached"
    fi
  fi

  printf '%d\n' "$new_depth"
}

# ---------------------------------------------------------------------------
# Locked mutation helpers
# ---------------------------------------------------------------------------
# These functions are designed to be called via with_pool_lock. Because
# with_pool_lock uses a subshell (not bash -c), the subshell inherits all
# function definitions from the parent process.
#
# NEVER use: with_pool_lock bash -c "..."   (loses function definitions!)
# Instead:   with_pool_lock _locked_helper "$arg1" "$arg2"

_locked_mark_job_offloaded() {
  local jid="$1"
  get_job_meta "$jid" | jq '.offloaded = true' | update_job_meta "$jid"
}

_locked_mark_job_not_offloaded() {
  local jid="$1"
  get_job_meta "$jid" | jq '.offloaded = false' | update_job_meta "$jid"
}

_locked_mark_job_queued() {
  local jid="$1"
  get_job_meta "$jid" | jq '.status = "queued"' | update_job_meta "$jid"
}

_locked_mark_job_processing() {
  local jid="$1" slot="$2"
  get_job_meta "$jid" | jq --argjson slot "$slot" \
    '.status = "processing" | .slot = $slot' | update_job_meta "$jid"
}

_locked_mark_job_cancelled() {
  local jid="$1"
  get_job_meta "$jid" | jq '.status = "cancelled"' | update_job_meta "$jid"
}

_locked_set_job_uuid() {
  local jid="$1" uuid="$2"
  get_job_meta "$jid" | jq --arg uuid "$uuid" \
    '.claude_session_id = $uuid' | update_job_meta "$jid"
}

_locked_mark_slot_busy() {
  local slot="$1" jid="$2"
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  read_pool_json | jq \
    --arg jid "$jid" \
    --argjson idx "$slot" \
    --arg now "$now" \
    '.slots |= map(
      if .index == $idx then .status = "busy" | .job_id = $jid | .last_used_at = $now
      else . end
    )' | update_pool_json
}

# _locked_claim_and_dispatch — atomically verify a slot is still free, claim it
# as busy, and mark the job as processing. Prevents race conditions where two
# callers both allocate the same slot via allocate_slot().
# Returns 1 if the slot was stolen by another process.
_locked_claim_and_dispatch() {
  local slot="$1" job_id="$2"
  local pool_json slot_status
  pool_json=$(read_pool_json)
  slot_status=$(printf '%s' "$pool_json" | jq -r --argjson idx "$slot" \
    '.slots[] | select(.index == $idx) | .status')

  case "$slot_status" in
    fresh|idle) ;;
    *) return 1 ;;  # slot was claimed by another process
  esac

  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '%s' "$pool_json" | jq \
    --arg jid "$job_id" \
    --argjson idx "$slot" \
    --arg now "$now" \
    '.slots |= map(
      if .index == $idx then .status = "busy" | .job_id = $jid | .last_used_at = $now
      else . end
    )' | update_pool_json

  # Also mark the job as processing (meta.json, not pool.json)
  get_job_meta "$job_id" | jq \
    --arg s "processing" --argjson slot "$slot" \
    '.status = $s | .slot = $slot' | update_job_meta "$job_id"

  # Clear any leftover done sentinel from the previous job on this slot.
  # Must happen inside the lock: if done outside, the watcher can see the
  # slot as "busy" (new job) + stale done file and incorrectly mark the
  # new job as completed (issue #4).
  rm -f "$POOL_DIR/slots/$slot/done"
}

_locked_update_slot_fresh() {
  local slot="$1" uuid="$2"
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  read_pool_json | jq \
    --argjson idx "$slot" \
    --arg uuid "$uuid" \
    --arg now "$now" \
    '.slots |= map(
      if .index == $idx then
        .status = "fresh" | .job_id = null | .claude_session_id = $uuid | .last_used_at = $now
      else . end
    )' | update_pool_json
}

_locked_update_slot_idle_resume() {
  local slot="$1" jid="$2" uuid="$3"
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  read_pool_json | jq \
    --argjson idx "$slot" \
    --arg jid "$jid" \
    --arg uuid "$uuid" \
    --arg now "$now" \
    '.slots |= map(
      if .index == $idx then
        .status = "idle" | .job_id = $jid | .claude_session_id = $uuid | .last_used_at = $now
      else . end
    )' | update_pool_json
}

_locked_update_slot_idle() {
  local slot="$1" jid="$2"
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  read_pool_json | jq \
    --arg jid "$jid" \
    --argjson idx "$slot" \
    --arg now "$now" \
    '.slots |= map(
      if .index == $idx then .status = "idle" | .job_id = $jid | .last_used_at = $now
      else . end
    )' | update_pool_json
}

_locked_mark_job_completed_and_slot_idle() {
  local jid="$1" slot="$2"

  # Guard: if the slot was already recycled to a different job, only update
  # the job metadata — don't overwrite the slot.
  local current_jid
  current_jid=$(read_pool_json | jq -r --argjson idx "$slot" \
    '.slots[] | select(.index == $idx) | .job_id // empty')

  get_job_meta "$jid" | jq '.status = "completed"' | update_job_meta "$jid"

  if [ "$current_jid" = "$jid" ]; then
    _locked_update_slot_idle "$slot" "$jid"
  else
    pool_log "core" "slot-$slot recycled (now $current_jid), skipping idle update for $jid"
  fi
}

# _locked_stop_and_complete — write the done sentinel and mark job/slot
# atomically. Must be called under with_pool_lock.
_locked_stop_and_complete() {
  local jid="$1" slot="$2"
  touch "$POOL_DIR/slots/$slot/done"
  _locked_mark_job_completed_and_slot_idle "$jid" "$slot"
}

_locked_increment_queue_seq() {
  local pool_json new_seq
  pool_json=$(read_pool_json | jq '.queue_seq = ((.queue_seq // 0) + 1)')
  new_seq=$(printf '%s' "$pool_json" | jq -r '.queue_seq')
  printf '%s' "$pool_json" | update_pool_json
  printf '%d\n' "$new_seq"
}

_locked_set_pin() {
  local jid="$1" expiry="$2"
  read_pool_json | jq --arg jid "$jid" --arg exp "$expiry" \
    '.pins[$jid] = $exp' | update_pool_json
}

_locked_remove_pin() {
  local jid="$1"
  read_pool_json | jq --arg jid "$jid" \
    'del(.pins[$jid])' | update_pool_json
}

_locked_remove_slot() {
  local slot="$1"
  read_pool_json | jq --argjson idx "$slot" \
    '.slots |= map(select(.index != $idx))' | update_pool_json
}

# _iso_to_epoch <ISO-8601-timestamp>
# Convert an ISO 8601 UTC timestamp to epoch seconds.
# Falls back to current epoch on parse failure and logs a warning.
_iso_to_epoch() {
  local ts="$1"
  if date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null; then
    return
  fi
  if date -d "$ts" +%s 2>/dev/null; then
    return
  fi
  pool_log "core" "WARNING: failed to parse timestamp '$ts', using current time"
  date +%s
}

_locked_update_last_activity_at() {
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  read_pool_json | jq --arg now "$now" '.last_activity_at = $now' | update_pool_json
}

# ---------------------------------------------------------------------------
# Pool health checks
# ---------------------------------------------------------------------------

# ensure_pool_exists() — die with a helpful hint if the pool has not been
# initialised.
ensure_pool_exists() {
  if [ ! -f "$POOL_DIR/pool.json" ]; then
    if is_root_pool; then
      die "no pool found — run 'sub-claude pool init' to create the root pool"
    else
      die "no pool found for this project — run 'sub-claude pool init' (root) or 'sub-claude pool init --local' (project-local)"
    fi
  fi
}

# ensure_pool_exists_or_wait <timeout_secs> — spin-wait for pool.json to appear.
# Used by commands (like cmd_wait) that may be called right after auto-init,
# before pool init has created pool.json. Dies if timeout elapses.
ensure_pool_exists_or_wait() {
  local timeout="${1:-30}"
  if [ -f "$POOL_DIR/pool.json" ]; then
    return 0
  fi
  # Only spin-wait if there's evidence of an auto-init in progress
  # (queue dir exists but pool.json doesn't).
  if [ ! -d "$POOL_DIR/queue" ]; then
    die "no pool found for this project — run 'sub-claude pool init' first"
  fi
  warn "pool initializing — waiting up to ${timeout}s..."
  local elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    if [ -f "$POOL_DIR/pool.json" ]; then
      return 0
    fi
    sleep 1
    elapsed=$(( elapsed + 1 ))
  done
  die "timed out waiting for pool init (${timeout}s)"
}

# is_pool_running() — return 0 if the watcher is alive AND the tmux server is up.
# Returns 1 otherwise (does not die — callers decide how to handle).
is_pool_running() {
  # Check watcher PID file
  local watcher_pid_file="$POOL_DIR/watcher.pid"
  if [ ! -f "$watcher_pid_file" ]; then
    return 1
  fi

  local watcher_pid
  watcher_pid=$(cat "$watcher_pid_file" 2>/dev/null)
  if [ -z "$watcher_pid" ]; then
    return 1
  fi

  # Check that the watcher process is still alive
  if ! kill -0 "$watcher_pid" 2>/dev/null; then
    return 1
  fi

  # Check that the tmux server for this pool is running
  if ! tmux -L "$TMUX_SOCKET" has-session 2>/dev/null; then
    return 1
  fi

  return 0
}
