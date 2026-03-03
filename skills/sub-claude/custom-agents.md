# Custom Agents

Reusable sub-agents as shell scripts. Define a prompt template once, call it repeatedly with different arguments via `sub-claude run <name> [args...]`.

## Locations

| Path | Scope |
|------|-------|
| `~/.sub-claude/commands/<name>.sh` | Global — all projects |
| `.sub-claude/commands/<name>.sh` | Project-local — overrides global with same name |

**When to create a command** vs inline `start`: when you'd call the same prompt pattern more than twice, or when the prompt template is complex enough that rewriting it inline is error-prone.

**Global vs project-local**: general-purpose agents (review, explain, test-gen) go global. Agents tied to project conventions (deploy checklist, repo-specific lint) go project-local.

## Example

A multi-turn agent that reviews, then suggests fixes — showing the key sub-claude composition patterns:

```bash
#!/usr/bin/env bash
set -euo pipefail
# Description: Review staged changes and suggest fixes

diff=$(git diff --cached)
[[ -z "$diff" ]] && { echo "No staged changes." >&2; exit 1; }

# start → wait → result: first pass
id=$(sub-claude start "Review this diff for bugs and security issues:\n\n$diff")
sub-claude wait "$id" --quiet
sub-claude -v response result "$id"

# followup: multi-turn on same session (history preserved)
sub-claude -v response followup "$id" "Now suggest concrete fixes for each issue." --block
```

The three composition building blocks — all from SKILL.md primitives:
- **One-shot**: `sub-claude -v response start "prompt with $args" --block`
- **Multi-turn**: `start` → `wait` → `followup` (session keeps conversation history)
- **Parallel fan-out**: multiple `start` calls → `wait` each → collect `result`s

## Sub-Claude-Specific Gotchas

- **Always use `-v response`** for agent output — strips TUI chrome, returns just the model's answer.
- **ARG_MAX limit** (~256KB on macOS): embedding large content via `$(cat file)` in the prompt string can hit OS limits. Write to a tempfile and reference the path instead:
  ```bash
  tmp=$(mktemp); git diff > "$tmp"
  sub-claude -v response start "Review the diff at $tmp" --block
  rm "$tmp"
  ```
- `# Description:` line is what `sub-claude run --list` displays — keep it concise.
- Run `sub-claude run --help` for full CLI reference.
