#!/usr/bin/env bash
set -euo pipefail
# Description: Review staged git changes (falls back to unstaged)

diff=$(git diff --cached)
[[ -z "$diff" ]] && diff=$(git diff)
[[ -z "$diff" ]] && { echo "No changes to review." >&2; exit 1; }

sub-claude -v response start \
  "Review this diff for bugs, security issues, and style problems. Be concise.\n\n$diff" \
  --block
