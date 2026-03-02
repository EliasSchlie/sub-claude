# sub-claude — Output Architecture

## Overview

sub-claude commands that return session output (`result`, `wait`, `start --block`, `followup --block`) use a two-stage dispatch:

1. **JSONL extraction** (default) — parse Claude Code's session transcript for the last assistant text response
2. **Terminal capture** (fallback / `--terminal`) — capture the tmux pane or snapshot file

JSONL gives clean text without TUI chrome, ANSI codes, or tool call markers. Terminal capture preserves the full interactive output.

## Output dispatch flow

```
_emit_output(job_id, slot, --terminal?)
  │
  ├─ --terminal? ──► terminal capture (old behavior)
  │
  ├─ verbosity = conversation|full? ──► terminal capture
  │     (JSONL only has last response, not full history)
  │
  ├─ try JSONL extraction:
  │     meta.json → claude_session_id (UUID)
  │     pool.json → project_dir (fallback: meta.json → cwd)
  │     ~/.claude/projects/<encoded-dir>/<uuid>.jsonl
  │     grep + jq → last assistant text response
  │     ├─ success ──► return clean text
  │     └─ failure ──► fall through
  │
  └─ terminal capture fallback:
        ├─ slot available ──► capture tmux pane
        ├─ snapshot.log exists ──► cat snapshot
        └─ neither ──► warn + return 1
```

## JSONL source

Claude Code stores session transcripts at `~/.claude/projects/<encoded-dir>/<uuid>.jsonl`. The directory name is the project path with `/` replaced by `-` (e.g., `/Users/me/project` → `-Users-me-project`).

Each assistant message is a JSON line with structure:
```json
{"type":"assistant", "message":{"role":"assistant", "stop_reason":"end_turn", "content":[{"type":"text", "text":"..."}]}}
```

The library (`config/lib/claude-output/jsonl.sh`) provides two functions:
- **`claude_jsonl_find <uuid> [project_dir]`** — locate JSONL file (fast path via computed dir, glob fallback)
- **`claude_jsonl_last_response <jsonl_path>`** — extract last assistant message containing text blocks

## Flags

### `--terminal`

Bypasses JSONL extraction entirely and uses terminal capture. Available as:
- **Global option**: `sub-claude --terminal result <id>` — applies to all commands
- **Per-command flag**: `sub-claude result <id> --terminal` — applies to that command only

Use when you need the full TUI output (tool call details, thinking blocks, system messages).

### `--verbosity` interaction

| Verbosity | JSONL used? | Behavior |
|-----------|-------------|----------|
| `raw` (default) | Yes | JSONL text, or raw terminal fallback |
| `response` | Yes | JSONL text, or parsed terminal fallback |
| `conversation` | No | Terminal capture → parse all turns |
| `full` | No | Terminal capture → strip chrome only |

JSONL extraction naturally produces "response" level output (last assistant text only). For `conversation` and `full` modes that need multi-turn history or tool output, terminal capture is used directly since only the TUI contains that context.

## Libraries

| File | Depends on | Purpose |
|------|-----------|---------|
| `config/lib/claude-output/jsonl.sh` | Nothing (standalone) | JSONL file lookup + response extraction |
| `config/lib/claude-output/parse.sh` | Nothing (standalone) | Terminal output parsing by verbosity level |
| `config/lib/sub-claude/session.sh` | Both above | `_emit_response`, `_emit_output` dispatch |
