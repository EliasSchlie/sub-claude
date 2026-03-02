# Sub-Claude

Session-oriented pool of persistent Claude TUI slots backed by tmux.

## Dev

- `./dev.sh test unit` — fast, mocked (bats)
- `./dev.sh test integration` — real tmux, mock claude
- `./dev.sh test live` — real Claude, burns tokens
- Manual testing of pool commands: see [docs/manual-testing.md](docs/manual-testing.md)

## Plugin

This repo is also a Claude Code plugin. Structure:

- `.claude-plugin/plugin.json` — manifest
- `skills/sub-claude/` — skill docs (SKILL.md + sub-skills)
- `hooks/hooks.json` — hook wiring (done signal + guardrails)
- `hooks/*.sh` — hook scripts (reference copies; hooks.json inlines the logic)

Test locally: `claude --plugin-dir .`

## Rules

- **Never `git add -A` or `git add .`** — always stage specific files by name
