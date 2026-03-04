# shellcheck shell=bash
# tmux.sh — tmux operations layer for sub-claude
#
# Sourced by the sub-claude dispatcher after core.sh.
# Assumes POOL_DIR and TMUX_SOCKET are set by core.sh.
#
# All tmux interactions go through this file. No other layer
# should call tmux directly.

# ---------------------------------------------------------------------------
# Socket wrapper
# ---------------------------------------------------------------------------

# tmux_cmd — run tmux with the pool's named socket.
# All tmux commands go through this to target the correct server.
tmux_cmd() {
  tmux -L "$TMUX_SOCKET" "$@"
}

# ---------------------------------------------------------------------------
# Target addressing
# ---------------------------------------------------------------------------

# slot_target — return the tmux target string for a slot index.
# Format: "pool:slot-N" (session "pool", window named "slot-N").
slot_target() {
  echo "pool:slot-$1"
}

# ---------------------------------------------------------------------------
# Key / text sending
# ---------------------------------------------------------------------------

# send_keys — send literal text to a slot's pane.
# Uses -l (literal mode) so tmux does not interpret key names.
# Additional arguments after the slot index are forwarded to send-keys.
send_keys() {
  local slot="$1"; shift
  tmux_cmd send-keys -t "$(slot_target "$slot")" -l "$@"
}

# send_special_key — send a named special key (Enter, Escape, Up, Down, …).
# Unlike send_keys, this does NOT use -l, so tmux interprets the key name.
send_special_key() {
  local slot="$1" key="$2"
  tmux_cmd send-keys -t "$(slot_target "$slot")" "$key"
}

# send_prompt — send a prompt string to a slot and press Enter.
#
# Two strategies based on prompt length:
#   Short (≤400 chars): send-keys -l + separate Enter keystroke.
#   Long (>400 chars):  write to a tmpfile, load-buffer, paste-buffer, Enter.
#
# The length split avoids tmux's internal buffer limits for very long inputs.
send_prompt() {
  local slot="$1" text="$2"
  local target
  target=$(slot_target "$slot")

  if [ "${#text}" -le 400 ]; then
    tmux_cmd send-keys -t "$target" -l "$text"
    tmux_cmd send-keys -t "$target" Enter
  else
    local tmpfile buf_name
    tmpfile=$(mktemp)
    buf_name="pool-$$-${slot}"
    printf '%s' "$text" > "$tmpfile"

    # Snapshot pane before paste so we can detect when the TUI renders it.
    local before_hash
    before_hash=$(tmux_cmd capture-pane -t "$target" -p 2>/dev/null \
      | (md5 -q 2>/dev/null || md5sum | cut -d' ' -f1))

    tmux_cmd load-buffer -b "$buf_name" "$tmpfile"
    tmux_cmd paste-buffer -b "$buf_name" -t "$target" -d

    # Poll until the pane content changes (paste rendered) instead of a
    # fixed sleep. Prevents Enter from arriving before the TUI processes
    # the paste event (issue #42). Timeout: 3s.
    local poll_n=0
    while [ "$poll_n" -lt 30 ]; do
      sleep 0.1
      poll_n=$((poll_n + 1))
      local after_hash
      after_hash=$(tmux_cmd capture-pane -t "$target" -p 2>/dev/null \
        | (md5 -q 2>/dev/null || md5sum | cut -d' ' -f1))
      [ "$before_hash" != "$after_hash" ] && break
    done

    if [ "$poll_n" -ge 30 ]; then
      pool_log "send_prompt" "slot-$slot: WARNING — paste not confirmed after 3s, sending Enter anyway"
    fi

    tmux_cmd send-keys -t "$target" Enter
    rm -f "$tmpfile"
  fi
}

# ---------------------------------------------------------------------------
# Pane capture
# ---------------------------------------------------------------------------

# capture_pane — capture the full pane contents including scrollback.
# Uses -S -100000 for effectively unlimited history.
# Prints captured text to stdout.
capture_pane() {
  local slot="$1"
  tmux_cmd capture-pane -t "$(slot_target "$slot")" -p -S -100000
}

# _strip_ansi — strip ANSI escape sequences from stdin, print clean text.
#
# Handles the common terminal sequences emitted by TUI apps:
#   - CSI sequences:  \e[...X  (colors, cursor movement, erasing)
#   - OSC (BEL):      \e]...BEL  (title changes, hyperlinks)
#   - OSC (ST):       \e]...\e\\  (same, alternate terminator)
#   - Alternate screen: \e[?Nh / \e[?Nl
#   - Charset switches: \e(X, \e)X
#   - Mode sets:       \e=, \e>
#
# Does NOT handle: 8-bit CSI (0x9b), APC/PM/SOS sequences. These are rare
# in practice and omitted to keep the sed expressions maintainable.
_strip_ansi() {
  LC_ALL=C sed $'s/\033\\[[0-9;]*[A-Za-z]//g
        s/\033\\][^\007]*\007//g
        s/\033\\][^\033]*\033\\\\//g
        s/\033[()][A-Z0-9]//g
        s/\033[=>]//g
        s/\033\\[?[0-9]*[hl]//g
        s/\r//g' 2>/dev/null \
  | sed '/^$/d'
}

# _strip_spinner — remove TUI spinner animation noise from stripped output.
#
# After _strip_ansi removes escape codes, spinner frames remain as plain text
# because the TUI overwrites them via cursor movement (cursor-back + rewrite).
# This function removes:
#   - Lines that are only spinner Unicode chars (✢✳✶✻✽✸✹✺) or middle-dot (·)
#   - Spinner char + known label combos (e.g. "✻Frosting…", "✶(thinking)")
#   - Standalone known progress labels (e.g. "Frosting…", "Forging…")
#   - "(thinking)" and "(running stop hooks…)" standalone lines
#
# Known Claude Code spinner labels (add new ones to _sc_labels as observed):
#   Frosting, Forging, Generating, Thinking, Reasoning, Processing,
#   Analyzing, Crafting, Building, Creating, Preparing, Computing,
#   Evaluating, Considering, Synthesizing, Formulating
#
# Designed to be piped after _strip_ansi:
#   ... | _strip_ansi | _strip_spinner
_strip_spinner() {
  local _sc_labels='(Frosting|Forging|Generating|Thinking|Reasoning|Processing|Analyzing|Crafting|Building|Creating|Preparing|Computing|Evaluating|Considering|Synthesizing|Formulating)'
  LC_ALL=C sed -E \
    -e '/^[[:space:]]*[✢✳✶✻✽✸✹✺]+[[:space:]]*$/d' \
    -e "/^[[:space:]]*[✢✳✶✻✽✸✹✺]+[[:space:]]*${_sc_labels}…[[:space:]]*\$/d" \
    -e '/^[[:space:]]*[✢✳✶✻✽✸✹✺]+\(thinking\)[[:space:]]*$/d' \
    -e "/^[[:space:]]*${_sc_labels}…[[:space:]]*\$/d" \
    -e '/^[[:space:]]*\(thinking\)[[:space:]]*$/d' \
    -e '/^[[:space:]]*\(running stop hooks[^)]*\)[[:space:]]*$/d' \
    -e '/^[[:space:]]*·+[[:space:]]*$/d' \
    -e "/^[[:space:]]*·[[:space:]]*${_sc_labels}…[[:space:]]*\$/d" \
    2>/dev/null
}

# capture_raw_log — capture full output from a slot's pipe-pane log.
#
# TUI apps (like Claude Code / Ink) use the alternate screen buffer, which
# does NOT accumulate scrollback. Content that scrolls past the visible area
# is lost to capture-pane. The pipe-pane raw.log captures the full byte
# stream including scrolled-off content.
#
# This function reads the raw.log for a slot, strips ANSI escape sequences,
# and prints clean text to stdout. If a byte offset is provided (from the
# job's raw_offset file), only content from that offset is included.
#
# Arguments:
#   slot       — slot index
#   byte_offset — (optional) start reading from this byte offset in raw.log
#
# Returns 1 if raw.log is unavailable or empty (caller should fall back).
capture_raw_log() {
  local slot="$1" byte_offset="${2:-0}"
  # POOL_DIR is set by core.sh before this file is sourced
  # shellcheck disable=SC2153
  local raw_log="$POOL_DIR/slots/$slot/raw.log"

  if [ ! -f "$raw_log" ] || [ ! -s "$raw_log" ]; then
    return 1
  fi

  tail -c +"$((byte_offset + 1))" "$raw_log" | _strip_ansi | _strip_spinner
}

# capture_pane_recent — capture the last N lines of a pane (default: 50).
# Lighter than capture_pane; used for UUID extraction and quick state checks.
capture_pane_recent() {
  local slot="$1" lines="${2:-50}"
  tmux_cmd capture-pane -t "$(slot_target "$slot")" -p -S -"$lines"
}

# ---------------------------------------------------------------------------
# Pane liveness
# ---------------------------------------------------------------------------

# is_pane_alive — return 0 if the slot's tmux pane exists, 1 otherwise.
# Used by the background watcher for crash detection.
is_pane_alive() {
  local slot="$1"
  tmux_cmd list-panes -t "$(slot_target "$slot")" &>/dev/null
}

# ---------------------------------------------------------------------------
# Claude session UUID extraction
# ---------------------------------------------------------------------------

# SESSION_PID_DIR — directory where the SessionStart hook writes PID→UUID maps.
SESSION_PID_DIR="$HOME/.claude/session-pids"

# _get_pane_pid — get the PID of the process running in a slot's tmux pane.
# After `exec claude` in run.sh, this is the Claude process PID.
_get_pane_pid() {
  local slot="$1"
  tmux_cmd list-panes -t "$(slot_target "$slot")" -F '#{pane_pid}' 2>/dev/null | head -1
}

# invalidate_session_pidfile — remove the PID→UUID mapping for a slot.
# Call before /clear so extract_uuid waits for the new session's UUID
# instead of reading the stale one.
invalidate_session_pidfile() {
  local slot="$1"
  local pid
  pid=$(_get_pane_pid "$slot")
  [ -n "$pid" ] && rm -f "$SESSION_PID_DIR/$pid"
}

# _extract_uuid_via_pidfile — read session UUID from the SessionStart hook's
# PID mapping file. Polls for up to $2 seconds (default: 5).
#
# The SessionStart hook (in hooks.json) writes the session_id to
# ~/.claude/session-pids/$PPID on every session start (/clear, /resume,
# initial launch). Since run.sh uses `exec claude`, the tmux pane_pid
# equals the Claude process PID equals $PPID from the hook's perspective.
#
# Returns 0 and prints UUID on success, 1 on timeout.
_extract_uuid_via_pidfile() {
  local slot="$1" max_wait="${2:-5}"
  local pid pid_file uuid start_s=$SECONDS

  pid=$(_get_pane_pid "$slot")
  if [ -z "$pid" ]; then
    pool_log "extract_uuid" "slot-$slot: could not get pane PID"
    return 1
  fi

  pid_file="$SESSION_PID_DIR/$pid"

  while [ $((SECONDS - start_s)) -lt "$max_wait" ]; do
    # Read directly — avoids TOCTOU and useless cat fork
    uuid=$(tr -d '[:space:]' < "$pid_file" 2>/dev/null) || true
    if [ -n "$uuid" ]; then
      printf '%s' "$uuid"
      return 0
    fi

    # Bail early if the Claude process died
    kill -0 "$pid" 2>/dev/null || {
      pool_log "extract_uuid" "slot-$slot: pane PID $pid is dead, aborting pidfile wait"
      return 1
    }

    sleep 0.5
  done

  return 1
}

# --- Fallback: /status-based extraction (used when PID file unavailable) ---

# _send_status_cmd — type /status, wait for autocomplete, press Enter.
_send_status_cmd() {
  local target="$1" delay="${2:-1}"
  _clear_input "$target"
  tmux_cmd send-keys -t "$target" -l "/status"
  sleep "$delay"
  tmux_cmd send-keys -t "$target" Enter
}

# _poll_for_uuid — poll pane content until a UUID appears or timeout.
_poll_for_uuid() {
  local slot="$1" max_wait="${2:-8}"
  local start_s=$SECONDS pane uuid
  while [ $((SECONDS - start_s)) -lt "$max_wait" ]; do
    pane=$(capture_pane_recent "$slot" 50)
    uuid=$(printf '%s' "$pane" | grep -i 'Session ID:' | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | tail -1)
    if [ -z "$uuid" ]; then
      uuid=$(printf '%s' "$pane" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | tail -1)
    fi
    if [ -n "$uuid" ]; then
      printf '%s' "$uuid"
      return 0
    fi
    sleep 0.5
  done
}

# _extract_uuid_via_status — legacy /status-based UUID extraction.
# Sends /status to the TUI, polls pane output for a UUID regex match.
# Slow (~10-30s) and fragile — used only as fallback when PID file is unavailable.
_extract_uuid_via_status() {
  local slot="$1" skip_warmup="${2:-false}"
  local target
  target=$(slot_target "$slot")

  if [ "$skip_warmup" != "true" ]; then
    _send_status_cmd "$target" 2
    sleep 2
    tmux_cmd send-keys -t "$target" Escape
    sleep 0.5
  fi

  local attempt uuid
  for attempt in 1 2 3; do
    _send_status_cmd "$target" $((attempt + 1))
    uuid=$(_poll_for_uuid "$slot" 8)
    tmux_cmd send-keys -t "$target" Escape
    sleep 0.5

    if [ -n "$uuid" ]; then
      pool_log "extract_uuid" "slot-$slot: uuid=$uuid (via /status, attempt $attempt)"
      echo "$uuid"
      return 0
    fi
    pool_log "extract_uuid" "slot-$slot: /status attempt $attempt failed, retrying..."
    sleep 2
  done

  pool_log "extract_uuid" "slot-$slot: FAILED after 3 /status attempts"
  return 1
}

# extract_uuid — get the Claude session UUID for a slot.
#
# Fast path: read from ~/.claude/session-pids/<pane_pid> (written by the
#   SessionStart hook). Instant after session start, ~0.5s polling otherwise.
# Fallback:  send /status to the TUI and parse the output (~10-30s).
#
# Accepts --skip-warmup for backward compat (ignored on the fast path,
# passed through to the /status fallback).
extract_uuid() {
  local slot="$1" skip_warmup=false
  [ "${2:-}" = "--skip-warmup" ] && skip_warmup=true

  # Fast path: PID file
  local uuid
  if uuid=$(_extract_uuid_via_pidfile "$slot"); then
    pool_log "extract_uuid" "slot-$slot: uuid=$uuid (via pid-map)"
    echo "$uuid"
    return 0
  fi

  # Fallback: /status method
  pool_log "extract_uuid" "slot-$slot: pid-map unavailable, falling back to /status"
  uuid=$(_extract_uuid_via_status "$slot" "$skip_warmup") || true
  echo "$uuid"
}

# ---------------------------------------------------------------------------
# Trust prompt handling
# ---------------------------------------------------------------------------

# accept_trust_prompt — watch for and accept Claude's workspace trust prompt.
#
# Polls up to 8 times (2s apart = 16s total). Looks for the string
# "Enter to confirm" in the pane output, then presses Enter to accept.
#
# Returns 0 if the prompt was accepted, 1 if it was never seen.
accept_trust_prompt() {
  local slot="$1"
  local target
  target=$(slot_target "$slot")

  local _
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    local pane
    pane=$(tmux_cmd capture-pane -t "$target" -p 2>/dev/null || true)

    # Trust prompt present — accept it
    if printf '%s' "$pane" | grep -q "Enter to confirm"; then
      tmux_cmd send-keys -t "$target" Enter
      return 0
    fi

    # Already past the trust prompt (skipDangerousModePermissionPrompt=true
    # or prompt was auto-accepted). Claude shows a "❯" prompt when ready.
    if printf '%s' "$pane" | grep -qE '(^|\s)(❯|>)\s*$'; then
      return 0
    fi

    sleep 2
  done
  return 1
}

# ---------------------------------------------------------------------------
# Slot / pane lifecycle
# ---------------------------------------------------------------------------

# create_slot_pane — create a new tmux window for a slot, running its wrapper.
# The window is named "slot-N" inside the "pool" session.
create_slot_pane() {
  local slot="$1" run_script="$2"
  tmux_cmd new-window -t pool -n "slot-$slot" "bash '$run_script'"
}

# write_slot_wrapper — generate the run.sh launcher for a slot.
#
# The wrapper:
#   - Exports pool-specific env vars (checked by hooks and scripts).
#   - Changes to the project directory.
#   - Launches claude --dangerously-skip-permissions.
#
# Arguments:
#   slot        — slot index (integer)
#   pool_dir    — pool state root (e.g. ~/.sub-claude/pools/<hash>)
#   project_dir — project working directory to cd into
write_slot_wrapper() {
  local slot="$1" pool_dir="$2" project_dir="$3"
  local slot_dir="$pool_dir/slots/$slot"
  mkdir -p "$slot_dir"

  # printf %q safely quotes the project_dir for the cd command
  local plugin_flag=""
  if [[ -n "${SUB_CLAUDE_PLUGIN_DIR:-}" ]]; then
    plugin_flag=" --plugin-dir $(printf '%q' "$SUB_CLAUDE_PLUGIN_DIR")"
  fi

  cat > "$slot_dir/run.sh" <<RUNEOF
#!/usr/bin/env bash
unset CLAUDECODE
export SUB_CLAUDE=1
export SUB_CLAUDE_SLOT=$slot
export SUB_CLAUDE_DONE_FILE="$slot_dir/done"
export CLAUDE_BELL_OFF=1
cd $(printf '%q' "$project_dir")
exec claude --dangerously-skip-permissions${plugin_flag}
RUNEOF
  chmod +x "$slot_dir/run.sh"
}

# init_tmux_server — create the tmux server with a pool session and first slot.
#
# Uses a temporary config to set high scrollback (100 000 lines) and hide
# the status bar (irrelevant in a headless pool).
#
# TMUX must be unset to allow nesting; this is handled by the TMUX='' prefix.
init_tmux_server() {
  local first_slot_script="$1"

  local conf
  conf=$(mktemp)
  cat > "$conf" <<'CONF'
set -g history-limit 100000
set -g status off
CONF

  TMUX='' tmux_cmd -f "$conf" new-session -d -s pool -n "slot-0" \
    -x 220 -y 50 "bash '$first_slot_script'"
  rm -f "$conf"
}

# ---------------------------------------------------------------------------
# High-level slot conversation commands
# ---------------------------------------------------------------------------

# _clear_input — helper to clear any stale input or overlay before sending a slash command.
_clear_input() {
  local target="$1"
  tmux_cmd send-keys -t "$target" Escape
  sleep 0.3
  tmux_cmd send-keys -t "$target" C-u
  sleep 0.2
}

# _send_slash_cmd — type a slash command, wait for autocomplete, then press Enter.
_send_slash_cmd() {
  local target="$1" cmd="$2"
  _clear_input "$target"
  tmux_cmd send-keys -t "$target" -l "$cmd"
  sleep 1
  tmux_cmd send-keys -t "$target" Enter
}

# send_slash_clear — send /clear to start a new conversation in a slot.
#
# /clear is critical for session isolation. This function retries up to 3 times
# with increasing delays to work around autocomplete timing issues in the TUI.
# Verifies success by checking the pane for the "(no content)" marker that
# /clear produces.
send_slash_clear() {
  local slot="$1"
  local target attempt
  target=$(slot_target "$slot")

  for attempt in 1 2 3; do
    # C-u only — no Escape here. Callers (offload_to_new) already sent Escape
    # before calling us. A second Escape on an empty input opens the quit menu
    # in Claude Code, which swallows the subsequent /clear keystrokes.
    tmux_cmd send-keys -t "$target" C-u
    sleep 0.2
    tmux_cmd send-keys -t "$target" -l "/clear"
    sleep $((attempt + 1))
    tmux_cmd send-keys -t "$target" Enter
    sleep 3

    # Verify /clear executed by checking for its "(no content)" output.
    local pane
    pane=$(tmux_cmd capture-pane -t "$target" -p -S -20 2>/dev/null || true)
    if printf '%s' "$pane" | grep -q '(no content)'; then
      pool_log "slash_clear" "slot-$slot: /clear confirmed (attempt $attempt)"
      return 0
    fi

    pool_log "slash_clear" "slot-$slot: /clear not confirmed (attempt $attempt), pane tail: $(printf '%s' "$pane" | tail -5 | tr '\n' '|')"
    # Escape to dismiss any lingering autocomplete or overlay before retrying.
    tmux_cmd send-keys -t "$target" Escape
    sleep 1
  done

  pool_log "slash_clear" "slot-$slot: WARNING — /clear not confirmed after 3 attempts"
  return 1
}

# send_slash_resume — send /resume <uuid> to switch a slot to an existing session.
#
# Like send_slash_clear, this retries up to 3 times with increasing delays
# to work around autocomplete timing issues. Verifies success by checking
# that the pane content changed (the TUI redraws with the resumed conversation).
send_slash_resume() {
  local slot="$1" uuid="$2"
  local target attempt
  target=$(slot_target "$slot")

  for attempt in 1 2 3; do
    local before_hash
    before_hash=$(tmux_cmd capture-pane -t "$target" -p 2>/dev/null | (md5 -q 2>/dev/null || md5sum | cut -d' ' -f1))

    # C-u only — no Escape. Callers (offload_to_resume) already sent Escape.
    # A second Escape on an empty input opens the quit menu in Claude Code.
    tmux_cmd send-keys -t "$target" C-u
    sleep 0.2
    tmux_cmd send-keys -t "$target" -l "/resume $uuid"
    sleep $((attempt + 1))
    tmux_cmd send-keys -t "$target" Enter
    sleep 3

    local after_hash
    after_hash=$(tmux_cmd capture-pane -t "$target" -p 2>/dev/null | (md5 -q 2>/dev/null || md5sum | cut -d' ' -f1))

    if [ "$before_hash" != "$after_hash" ]; then
      pool_log "slash_resume" "slot-$slot: /resume confirmed (attempt $attempt)"
      echo "$attempt"  # stdout: callers can skip heavy verification on attempt 1
      return 0
    fi

    pool_log "slash_resume" "slot-$slot: /resume not confirmed (attempt $attempt), retrying..."
    tmux_cmd send-keys -t "$target" Escape
    sleep 1
  done

  pool_log "slash_resume" "slot-$slot: WARNING — /resume not confirmed after 3 attempts"
  return 1
}

# clear_scrollback — clear the tmux scrollback history for a slot.
# Used when reusing a slot to prevent capture_pane from returning old output.
# Must be called AFTER send_slash_clear/send_slash_resume (which settle the
# TUI) and BEFORE extract_uuid or any capture (which generate fresh output).
clear_scrollback() {
  local slot="$1"
  tmux_cmd clear-history -t "$(slot_target "$slot")"
}

# ---------------------------------------------------------------------------
# Completion detection
# ---------------------------------------------------------------------------

# IDLE_FALLBACK — seconds of output silence before triggering idle fallback.
IDLE_FALLBACK=30

# _stop_hook_blocked — check raw.log for evidence that a Stop hook blocked.
#
# Claude Code renders "Stop hook error: <reason>" when a Stop hook returns
# {"decision":"block",...}. We scan raw.log for this pattern in recent output.
#
# Pattern verified against Claude Code ~1.0.x (March 2026). If Claude Code
# changes this rendering, the grep will stop matching and wait_for_done will
# accept all Stop signals immediately — equivalent to pre-plugin behavior
# (no regression, just no block detection). If you notice premature done
# signals after a Claude Code update, check the rendered text and update the
# pattern below.
#
# Two-pass check: immediate first, then after 0.5s. The second pass tolerates
# TUI flush latency — the block message may not be in raw.log immediately
# after the done file is written. This adds ~0.5s to every Stop-triggered
# completion.
#
# Arguments:
#   raw_log — path to pipe-pane output log
#   offset  — byte offset to start checking from (0 = check last 2000 bytes)
#
# Returns: 0 if block detected, 1 if no block
_stop_hook_blocked() {
  local raw_log="$1" offset="${2:-0}"
  local check_region pass

  for pass in 1 2; do
    # Pass 1: immediate. Pass 2: wait for TUI flush.
    [ "$pass" -eq 2 ] && sleep 0.5

    if [ "$offset" -gt 0 ]; then
      check_region=$(tail -c "+$((offset + 1))" "$raw_log" 2>/dev/null)
    else
      check_region=$(tail -c 2000 "$raw_log" 2>/dev/null)
    fi

    if printf '%s\n' "$check_region" | _strip_ansi | grep -qi 'stop hook error:'; then
      return 0  # block detected
    fi
  done

  return 1  # no block
}

# wait_for_done — block until a job completes or times out.
#
# Primary path:   polls for the done sentinel file (written by the Stop hook).
#                 When the done file contains "stop", validate against the raw
#                 log for Stop hook blocking patterns before accepting. This
#                 prevents premature done signals when another Stop hook
#                 (e.g. check-improvements.sh) blocks the response.
# Secondary path: if a job_id is provided, checks meta.json for status
#                 "completed" (set by the watcher). Catches cases where the
#                 watcher processed the done file before we started polling.
# Fallback path:  if neither signal appears, 30s of no output growth
#                 is treated as completion. Always warns on stderr when the
#                 fallback fires, as it indicates a misconfigured hook.
#                 Guard (issue #26): the fallback only fires when the log
#                 actually grew since we started waiting — no growth means the
#                 prompt was never submitted, so we return timeout instead.
#
# Arguments:
#   done_file — path to the sentinel file ($slot_dir/done)
#   raw_log   — path to the pipe-pane output log ($slot_dir/raw.log)
#   timeout   — maximum seconds to wait (default: 600)
#   job_id    — (optional) job ID for meta.json completion check
#
# Returns:
#   0 — done (sentinel fired or idle fallback)
#   1 — timed out without completion
wait_for_done() {
  local done_file="$1" raw_log="$2" timeout="${3:-600}" job_id="${4:-}"
  local w=0 last=0 idle_n=0 used_fallback=false
  local block_check_offset=0  # raw_log offset for detecting new Stop hook blocks
  local done_source="" current_sz=""

  # Record the initial log size. If the log never grows beyond this baseline,
  # the session never processed anything (prompt pasted but not submitted —
  # issue #26). The idle fallback must not fire in that case.
  local initial_sz
  initial_sz=$(wc -c < "$raw_log" 2>/dev/null | tr -d ' ')
  initial_sz="${initial_sz:-0}"

  while [ "$w" -lt "$timeout" ]; do
    # Primary: done sentinel file (written by Stop hook)
    if [ -f "$done_file" ]; then
      # cat piped to tr (not redirect) so 2>/dev/null suppresses ENOENT
      # if the file disappears between -f check and read.
      done_source=$(cat "$done_file" 2>/dev/null | tr -d '[:space:]')

      if [ "$done_source" = "stop" ]; then
        # Stop-triggered done signal — validate it's not premature.
        # Another Stop hook may have blocked (e.g. check-improvements.sh).
        # The plugin's Stop hook fires unconditionally (can't know if another
        # hook will block), so we check raw.log for the block message.
        #
        # Claude Code renders "Stop hook error: <reason>" when a Stop hook
        # blocks. We look for this pattern in recent raw.log output. Two-pass
        # check with a gap to tolerate TUI flush latency.
        if _stop_hook_blocked "$raw_log" "$block_check_offset"; then
          pool_log "wait" "ignoring premature done signal (Stop hook blocked)"
          rm -f "$done_file"
          current_sz=$(wc -c < "$raw_log" 2>/dev/null | tr -d ' ')
          block_check_offset="${current_sz:-0}"
          idle_n=0
          sleep 1; w=$((w + 1)); continue
        fi
      fi

      # Validated Stop — accept.
      return 0
    fi

    # Secondary: if a job ID was provided, check whether the watcher already
    # marked it completed (covers the case where the done file was processed
    # before we started polling).
    # POOL_DIR is set by core.sh before this file is sourced
    # shellcheck disable=SC2153
    if [ -n "$job_id" ] && [ -f "$POOL_DIR/jobs/$job_id/meta.json" ]; then
      local meta_status
      meta_status=$(jq -r '.status // empty' "$POOL_DIR/jobs/$job_id/meta.json" 2>/dev/null)
      [ "$meta_status" = "completed" ] && return 0
    fi

    local sz
    sz=$(wc -c < "$raw_log" 2>/dev/null | tr -d ' ')
    sz="${sz:-0}"
    if [ "$sz" = "$last" ] && [ "$last" -gt 0 ]; then
      idle_n=$((idle_n + 1))
      if [ "$idle_n" -ge "$IDLE_FALLBACK" ]; then
        # Guard: only treat idle as "done" if the log actually grew since we
        # started waiting. No growth means the prompt was never submitted
        # (issue #26) — break and return timeout exit code immediately.
        if [ "$sz" -gt "$initial_sz" ]; then
          used_fallback=true
        fi
        break
      fi
    else
      idle_n=0
      last="$sz"
    fi

    sleep 1
    w=$((w + 1))
  done

  if $used_fallback; then
    echo "warning: Stop hook did not fire — completed via idle fallback (${IDLE_FALLBACK}s)" >&2
    echo "warning: check that check-improvements.sh Stop hook is configured in settings.json" >&2
    return 0
  fi

  return 1  # hard timeout
}

# ---------------------------------------------------------------------------
# Output logging
# ---------------------------------------------------------------------------

# setup_pipe_pane — start mirroring a slot's pane output to raw.log.
# Uses tmux pipe-pane to append every byte of terminal output to the log.
# The log is consumed by wait_for_done's idle heuristic and by snapshot capture.
setup_pipe_pane() {
  local slot="$1"
  # POOL_DIR is set by core.sh before this file is sourced
  # shellcheck disable=SC2153
  local raw_log="$POOL_DIR/slots/$slot/raw.log"
  touch "$raw_log"
  tmux_cmd pipe-pane -t "$(slot_target "$slot")" "cat >> '$raw_log'"
}
