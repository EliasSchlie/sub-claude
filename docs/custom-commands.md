# Custom Commands

Create reusable sub-claude workflows as shell scripts.

## Quick Start

```bash
# Create the commands directory
mkdir -p ~/.sub-claude/commands

# Write a command
cat > ~/.sub-claude/commands/review.sh << 'EOF'
#!/usr/bin/env bash
# Description: Review staged git changes
diff=$(git diff --cached)
[[ -z "$diff" ]] && diff=$(git diff)
[[ -z "$diff" ]] && { echo "No changes to review." >&2; exit 1; }
sub-claude -v response start "Review this diff for bugs, security issues, and style:\n\n$diff" --block
EOF
chmod +x ~/.sub-claude/commands/review.sh

# Run it
sub-claude run review
```

## How It Works

`sub-claude run <name> [args...]` looks up `<name>.sh` in two locations (first match wins):

1. **`.sub-claude/commands/`** — project-local (git root or `$PWD`)
2. **`~/.sub-claude/commands/`** — global

Project-local commands override global ones with the same name.

## Command Anatomy

A command is a plain shell script. It receives any extra arguments as `$@` and can call `sub-claude` like any other script.

```bash
#!/usr/bin/env bash
# Description: One-line summary shown in --list output

# Your logic here — full shell power
sub-claude -v response start "your prompt" --block
```

### Required

- **Shebang** (`#!/usr/bin/env bash`)
- **Executable bit** (`chmod +x`)

### Optional

- **`# Description: ...`** — first matching line is shown by `sub-claude run --list`

## Listing Commands

```bash
sub-claude run --list
```

Output:

```
  review               (global) Review staged git changes
  test-plan            (project) Generate a test plan for the current module
```

## Examples

### Simple: One-Shot Prompt

```bash
#!/usr/bin/env bash
# Description: Explain a file
file="${1:?Usage: sub-claude run explain <file>}"
[[ -f "$file" ]] || { echo "File not found: $file" >&2; exit 1; }
sub-claude -v response start "Explain this file concisely:\n\n$(cat "$file")" --block
```

### Intermediate: Multi-Turn Conversation

```bash
#!/usr/bin/env bash
# Description: Interactive code review — review, then suggest fixes
diff=$(git diff --cached)
[[ -z "$diff" ]] && { echo "No staged changes." >&2; exit 1; }

id=$(sub-claude start "Review this diff for bugs and security issues:\n\n$diff")
sub-claude wait "$id" --quiet
echo "=== Review ==="
sub-claude result "$id" -v response

sub-claude followup "$id" "Now suggest concrete fixes for the issues you found." --block -v response
```

### Advanced: Parallel Fan-Out

```bash
#!/usr/bin/env bash
# Description: Analyze codebase from multiple angles in parallel
target="${1:-.}"

id1=$(sub-claude start "List all security concerns in $target")
id2=$(sub-claude start "Find performance bottlenecks in $target")
id3=$(sub-claude start "Suggest architectural improvements for $target")

for id in "$id1" "$id2" "$id3"; do
  sub-claude wait "$id" --quiet
done

echo "=== Security ==="
sub-claude result "$id1" -v response
echo ""
echo "=== Performance ==="
sub-claude result "$id2" -v response
echo ""
echo "=== Architecture ==="
sub-claude result "$id3" -v response
```

### With Arguments and Options

```bash
#!/usr/bin/env bash
# Description: Generate tests for a file
file=""
framework="jest"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --framework|-f) framework="$2"; shift 2 ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *) file="$1"; shift ;;
  esac
done

[[ -n "$file" ]] || { echo "Usage: sub-claude run test-gen <file> [--framework jest|pytest|bats]" >&2; exit 1; }
[[ -f "$file" ]] || { echo "File not found: $file" >&2; exit 1; }

sub-claude -v response start \
  "Write $framework tests for this code. Return only the test file contents:\n\n$(cat "$file")" \
  --block
```

## Lookup and Shadowing

When project-local and global directories both contain a command with the same name, **project-local wins**. `sub-claude run --list` shows both entries so you can spot shadows:

```
  review               (project) Review with project conventions
  review               (global) Generic code review
```

Running `sub-claude run review` executes the project-local one.

## Tips

- **Use `-v response`** to get just the model's answer (strips TUI chrome)
- **Use `--block`** for synchronous one-shot commands
- **Use `start` + `wait` + `result`** when you need the job ID for followups or parallel work
- **Commands inherit the current directory** — `git`, `cat`, relative paths all work as expected
- **Exit codes propagate** — if `sub-claude` fails, your script's `set -euo pipefail` catches it
- **Project-local commands** are great for repo-specific workflows (deploy, lint, review with project conventions)
- **Global commands** are great for general-purpose tools (explain, summarize, translate)

## Limitations

- **Argument length:** Embedding large content (e.g., `$(git diff)`) directly in the prompt string can hit the OS `ARG_MAX` limit (~256KB on macOS, ~2MB on Linux). For large inputs, write to a tempfile and reference it in the prompt:
  ```bash
  tmp=$(mktemp)
  git diff > "$tmp"
  sub-claude -v response start "Review this diff (in $tmp):\n\nSee the file at $tmp" --block
  rm "$tmp"
  ```
- **Command names** must start with a letter or digit, followed by letters, digits, hyphens, or underscores (`[a-zA-Z0-9][a-zA-Z0-9_-]*`). No dots, slashes, spaces, or leading hyphens.
