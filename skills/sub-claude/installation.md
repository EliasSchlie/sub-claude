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

Ensure `~/.local/bin` is in your PATH. The installer warns if it isn't.

## Verify

```bash
sub-claude --help
```

## Update

```bash
cd /path/to/sub-claude
git pull
./install.sh
```

## Uninstall

```bash
./install.sh --uninstall
```
