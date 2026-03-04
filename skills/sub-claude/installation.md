# Installation

## Check if installed

```bash
command -v sub-claude && sub-claude --help
```

## Install

```bash
git clone https://github.com/EliasSchlie/sub-claude.git
cd sub-claude
./install.sh          # copies to ~/.local/{bin,lib}
# or
./install.sh --link   # symlinks binary (updates via git pull, no reinstall)
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
./install.sh          # only needed for copy installs
```

With `--link` installs, `git pull` is sufficient — the symlink resolves to the repo automatically.

## Uninstall

```bash
./install.sh --uninstall
```
