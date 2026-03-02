# Sub-Claude

Session-oriented pool of persistent Claude TUI slots backed by tmux.

## Dev

- `./dev.sh test unit` — fast, mocked (bats)
- `./dev.sh test integration` — real tmux, mock claude
- `./dev.sh test live` — real Claude, burns tokens
- Manual testing of pool commands: see [docs/manual-testing.md](docs/manual-testing.md)

## Rules

- **Never `git add -A` or `git add .`** — always stage specific files by name
- **Never run real `pool stop`/`pool gc`/`pool destroy` from this repo or its worktrees** — it kills the pool you're running in. Use a temp dir outside any git repo instead.
