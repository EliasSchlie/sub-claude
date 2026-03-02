#!/usr/bin/env bash
set -euo pipefail
# Description: Generate a commit message for staged changes

diff=$(git diff --cached)
[[ -z "$diff" ]] && { echo "No staged changes." >&2; exit 1; }

sub-claude -v response start \
  "Write a concise git commit message for this diff. Use conventional commits format (feat/fix/refactor/docs/...). Return ONLY the commit message, nothing else.\n\n$diff" \
  --block
