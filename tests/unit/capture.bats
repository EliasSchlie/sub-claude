#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031,SC2329
# Unit tests for _emit_pane_full capture fallback (issue #41).
#
# When a session just started processing, raw.log may not have grown
# past the byte offset recorded at dispatch time. The offset-based read
# returns empty, AND capture_pane returns empty (TUI alternate screen).
# _emit_pane_full should fall back to reading raw.log without the offset.

load '../helpers/setup'
load '../helpers/mocks'

setup()    { _common_setup;    }
teardown() { _common_teardown; }

# ---------------------------------------------------------------------------
# _emit_pane_full fallback to full raw.log
# ---------------------------------------------------------------------------

@test "_emit_pane_full returns offset-based raw.log when available" {
  local slot=0 job_id="a1b2c3d4"
  mkdir -p "$POOL_DIR/slots/$slot" "$POOL_DIR/jobs/$job_id"

  # raw.log has 100 bytes of pre-dispatch content + 50 bytes of new content
  printf '%100s' " " > "$POOL_DIR/slots/$slot/raw.log"
  printf 'NEW OUTPUT HERE' >> "$POOL_DIR/slots/$slot/raw.log"

  # Offset = 100 (dispatch point)
  echo "100" > "$POOL_DIR/jobs/$job_id/raw_offset"

  output=$(_emit_pane_full "$slot" "$job_id")
  [[ "$output" == *"NEW OUTPUT HERE"* ]]
}

@test "_emit_pane_full falls back to full raw.log when offset-based read is empty" {
  local slot=0 job_id="a1b2c3d4"
  mkdir -p "$POOL_DIR/slots/$slot" "$POOL_DIR/jobs/$job_id"

  # raw.log has content but offset equals file size (nothing new since dispatch)
  printf 'PRE-DISPATCH CONTENT HERE' > "$POOL_DIR/slots/$slot/raw.log"
  local size
  size=$(wc -c < "$POOL_DIR/slots/$slot/raw.log")

  # Offset = file size → tail -c +N returns empty
  echo "$size" > "$POOL_DIR/jobs/$job_id/raw_offset"

  # Mock capture_pane to return empty (TUI alternate screen)
  capture_pane() { true; }

  output=$(_emit_pane_full "$slot" "$job_id")

  # Should fall back to full raw.log content (no offset)
  [[ "$output" == *"PRE-DISPATCH CONTENT"* ]]
}

@test "_emit_pane_full falls back to full raw.log when offset exceeds file size" {
  local slot=0 job_id="a1b2c3d4"
  mkdir -p "$POOL_DIR/slots/$slot" "$POOL_DIR/jobs/$job_id"

  # raw.log is smaller than the recorded offset
  printf 'SOME CONTENT' > "$POOL_DIR/slots/$slot/raw.log"

  # Offset larger than file
  echo "99999" > "$POOL_DIR/jobs/$job_id/raw_offset"

  # Mock capture_pane to return empty
  capture_pane() { true; }

  output=$(_emit_pane_full "$slot" "$job_id")
  [[ "$output" == *"SOME CONTENT"* ]]
}

@test "_emit_pane_full uses capture_pane when raw.log missing" {
  local slot=0 job_id="a1b2c3d4"
  mkdir -p "$POOL_DIR/slots/$slot" "$POOL_DIR/jobs/$job_id"

  # No raw.log exists
  # capture_pane mock returns "mock pane output" (from mocks.bash)

  output=$(_emit_pane_full "$slot" "$job_id")
  [[ "$output" == *"mock pane output"* ]]
}
