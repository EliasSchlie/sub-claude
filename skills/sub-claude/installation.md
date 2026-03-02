# Installation

## Check if installed

```bash
command -v sub-claude && sub-claude --help
```

## Install

```bash
git clone https://github.com/EliasSchlie/sub-claude.git
cd sub-claude
./install.sh
```

This installs:
- `~/.local/bin/sub-claude` — CLI binary
- `~/.local/lib/sub-claude/` — pool library
- `~/.local/lib/claude-output/` — output parser
- `~/.local/share/sub-claude/` — Claude Code plugin (hooks + skills)

## Verify

```bash
sub-claude --help
sub-claude pool init --size 3
sub-claude pool status
```

## Update

Pull the latest and re-run the installer:

```bash
cd /path/to/sub-claude
git pull
./install.sh
```

## Uninstall

```bash
./install.sh --uninstall
```
