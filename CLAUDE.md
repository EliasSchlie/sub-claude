# Sub-Claude

Session-oriented pool of persistent Claude TUI slots backed by tmux.

## Dev

- `./dev.sh test unit` — fast, mocked (bats)
- `./dev.sh test integration` — real tmux, mock claude
- `./dev.sh test live` — real Claude, burns tokens
- Manual testing of pool commands: see [docs/manual-testing.md](docs/manual-testing.md)

## Rules

- **Never `git add -A` or `git add .`** — always stage specific files by name
