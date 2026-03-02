#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031,SC2329
# Unit tests for job-existence checks in cancel, clean, and unpin commands.
# Covers GitHub issues #1, #2, #3.

load '../helpers/setup'
load '../helpers/mocks'

setup()    { _common_setup;    }
teardown() { _common_teardown; }

# ---------------------------------------------------------------------------
# cmd_cancel — nonexistent job ID (#1)
# ---------------------------------------------------------------------------

@test "cmd_cancel rejects nonexistent job ID with 'unknown job ID'" {
  echo '{"version":1,"slots":[]}' | update_pool_json
  run cmd_cancel "a1b2c3d4"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown job ID"* ]]
}

# ---------------------------------------------------------------------------
# cmd_clean — nonexistent job ID (#2)
# ---------------------------------------------------------------------------

@test "cmd_clean rejects nonexistent job ID with 'unknown job ID'" {
  echo '{"version":1,"slots":[]}' | update_pool_json
  run cmd_clean "a1b2c3d4"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown job ID"* ]]
}

# ---------------------------------------------------------------------------
# cmd_unpin — nonexistent job ID (#3)
# ---------------------------------------------------------------------------

@test "cmd_unpin rejects nonexistent job ID with 'unknown job ID'" {
  echo '{"version":1,"slots":[]}' | update_pool_json
  run cmd_unpin "a1b2c3d4"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown job ID"* ]]
}
