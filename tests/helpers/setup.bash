# shellcheck disable=SC1091
# Shared test setup for claude-pool unit tests.
# Provides _common_setup() and _common_teardown() for bats files to call.
# Each .bats file should define setup() and teardown() that delegate here.
#
# Mocks are applied AFTER sourcing libs so they override the real functions.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
LIB_DIR="$REPO_ROOT/lib/claude-pool"
HELPERS_DIR="$BATS_TEST_DIRNAME/../helpers"

_common_setup() {
  export TEST_DIR
  TEST_DIR="$(mktemp -d)"
  export POOL_DIR="$TEST_DIR/pool"
  export TMUX_SOCKET="test-claude-pool-$$"
  mkdir -p "$POOL_DIR/slots" "$POOL_DIR/jobs" "$POOL_DIR/queue"

  # Source all libs in dependency order
  # shellcheck source=../../lib/claude-pool/core.sh
  source "$LIB_DIR/core.sh"
  # shellcheck source=../../lib/claude-pool/tmux.sh
  source "$LIB_DIR/tmux.sh"
  # shellcheck source=../../lib/claude-pool/offload.sh
  source "$LIB_DIR/offload.sh"
  # shellcheck source=../../lib/claude-pool/queue.sh
  source "$LIB_DIR/queue.sh"
  # shellcheck source=../../lib/claude-pool/pool.sh
  source "$LIB_DIR/pool.sh"
  # shellcheck source=../../lib/claude-pool/session.sh
  source "$LIB_DIR/session.sh"

  # Apply mocks AFTER libs so they override the real tmux/claude functions
  # shellcheck source=mocks.bash
  source "$HELPERS_DIR/mocks.bash"
}

_common_teardown() {
  rm -rf "$TEST_DIR"
}
