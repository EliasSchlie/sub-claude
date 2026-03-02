#!/usr/bin/env bash
set -euo pipefail
# Description: Explain a file or code snippet

file="${1:?Usage: sub-claude run explain <file>}"
[[ -f "$file" ]] || { echo "File not found: $file" >&2; exit 1; }

sub-claude -v response start \
  "Explain this file concisely — purpose, key functions, and how it fits into the project:\n\n$(cat "$file")" \
  --block
