# Sub-Claude

Session-oriented pool of persistent Claude TUI slots backed by tmux.

## Dev

- `./dev.sh test unit` — fast, mocked (bats). Use `-q` for failures-only output.
- `./dev.sh test integration` — real tmux, mock claude
- `./dev.sh test live` — real Claude, burns tokens
- Manual testing of pool commands: see [docs/manual-testing.md](docs/manual-testing.md)
- Worktrees go in `.wt/<name>` (gitignored). Not `.claude/worktrees/`.

## Deployment

Two deployment channels — CLI and plugin update independently:

| Component | What | How it updates |
|-----------|------|----------------|
| **Plugin** | hooks, skills | Push to `main` → CI bumps version → marketplace → auto-update |
| **CLI** | `bin/sub-claude`, `lib/` | `git pull` (if installed with `./install.sh --link`) |

The bin script resolves symlinks via `readlink -f` to find its sibling `lib/` dir.

## Plugin

This repo is also a Claude Code plugin. Structure:

- `.claude-plugin/plugin.json` — manifest
- `skills/sub-claude/` — skill docs (SKILL.md + sub-skills)
- `hooks/hooks.json` — hook wiring (done signal, guardrails, SessionStart PID mapping)
- `hooks/*.sh` — hook scripts (reference copies; hooks.json inlines the logic)

Test locally: `claude --plugin-dir .` (bypasses marketplace, loads from working directory)

## Versioning & Releases

Plugin version lives in `.claude-plugin/plugin.json`. On every push to `main`, GitHub Actions automatically:

1. Bumps the patch version (e.g. `0.1.5` → `0.1.6`)
2. Pushes the new version to the marketplace repo (`EliasSchlie/claude-plugins`)

**Manual version bumps** — for major/minor changes, bump the version in `plugin.json` yourself before pushing:
- Breaking changes → bump major (e.g. `1.0.0` → `2.0.0`)
- New features → bump minor (e.g. `0.1.0` → `0.2.0`)
- The CI will then increment from *your* number (e.g. `0.2.0` → `0.2.1` on next push)

**Required secret**: `MARKETPLACE_PAT` — a GitHub PAT with repo access to `EliasSchlie/claude-plugins`.

**Auto-update for users**: Run `/plugin` → Marketplaces → enable auto-update for `elias-tools` (one-time).

## Rules

- **Never `git add -A` or `git add .`** — always stage specific files by name
