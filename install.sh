#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# install.sh — Install sub-claude CLI + Claude Code plugin
# =============================================================================
# Installs the sub-claude binary, libraries, and plugin to standard locations.
#
# Usage:
#   ./install.sh              # install to ~/.local/{bin,lib,share}
#   ./install.sh --prefix /usr/local   # custom prefix
#   ./install.sh --uninstall  # remove installed files

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${HOME}/.local"
UNINSTALL=false
LINK=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)
      [[ $# -ge 2 ]] || { echo "install.sh: --prefix requires an argument" >&2; exit 1; }
      PREFIX="$2"; shift 2 ;;
    --link) LINK=true; shift ;;
    --uninstall) UNINSTALL=true; shift ;;
    -h|--help)
      cat <<'EOF'
Usage: ./install.sh [options]

Options:
  --prefix DIR    Install prefix (default: ~/.local)
  --link          Symlink instead of copy (for development — updates via git pull)
  --uninstall     Remove installed files
  -h, --help      Show this help

Installs:
  <prefix>/bin/sub-claude              CLI binary (or symlink with --link)
  <prefix>/lib/sub-claude/             Pool library (not needed with --link)
  <prefix>/lib/claude-output/          Output parser library (not needed with --link)
  <prefix>/share/sub-claude/           Claude Code plugin (hooks + skills)
EOF
      exit 0 ;;
    *) echo "install.sh: unknown option '$1'" >&2; exit 1 ;;
  esac
done

BIN_DIR="$PREFIX/bin"
LIB_DIR="$PREFIX/lib"
SHARE_DIR="$PREFIX/share/sub-claude"

if $UNINSTALL; then
  echo "Uninstalling sub-claude..."
  rm -f "$BIN_DIR/sub-claude"
  rm -rf "$LIB_DIR/sub-claude"
  rm -rf "$LIB_DIR/claude-output"
  rm -rf "$SHARE_DIR"
  # Clean up legacy hook from pre-plugin installs
  rm -f "$HOME/.claude/hooks/sub-claude-done.sh"
  rm -f "$HOME/.claude/hooks/sub-claude-guardrails.sh"
  echo "Done."
  exit 0
fi

if $LINK; then
  echo "Symlinking sub-claude to $PREFIX (dev mode)..."
else
  echo "Installing sub-claude to $PREFIX..."
fi

mkdir -p "$BIN_DIR"

if $LINK; then
  # Dev mode: symlink the binary. The bin script resolves symlinks via
  # readlink -f to find its sibling lib/ dir, so no lib install needed.
  rm -f "$BIN_DIR/sub-claude"
  ln -s "$SCRIPT_DIR/bin/sub-claude" "$BIN_DIR/sub-claude"
  # Clean up any previously copied libs (no longer needed)
  rm -rf "$LIB_DIR/sub-claude" "$LIB_DIR/claude-output"
  echo "  Symlinked binary:  $BIN_DIR/sub-claude -> $SCRIPT_DIR/bin/sub-claude"
  echo "  Removed libs (resolved via symlink)"
else
  # Standard mode: copy binary and libraries
  mkdir -p "$LIB_DIR/sub-claude" "$LIB_DIR/claude-output"
  cp "$SCRIPT_DIR/bin/sub-claude" "$BIN_DIR/sub-claude"
  chmod +x "$BIN_DIR/sub-claude"
  cp "$SCRIPT_DIR/lib/sub-claude/"*.sh "$LIB_DIR/sub-claude/"
  cp "$SCRIPT_DIR/lib/claude-output/"*.sh "$LIB_DIR/claude-output/"
  echo "  Installed binary:  $BIN_DIR/sub-claude"
  echo "  Installed libs:    $LIB_DIR/sub-claude/"
  echo "                     $LIB_DIR/claude-output/"
fi

# Install Claude Code plugin (hooks + skills)
rm -rf "$SHARE_DIR"
mkdir -p "$SHARE_DIR/.claude-plugin" "$SHARE_DIR/hooks"
cp "$SCRIPT_DIR/.claude-plugin/plugin.json" "$SHARE_DIR/.claude-plugin/plugin.json"
cp "$SCRIPT_DIR/hooks/hooks.json" "$SHARE_DIR/hooks/hooks.json"
cp "$SCRIPT_DIR/hooks/"*.sh "$SHARE_DIR/hooks/"
cp -r "$SCRIPT_DIR/skills" "$SHARE_DIR/skills"
echo "  Installed plugin:  $SHARE_DIR/"

# Clean up legacy hook files from pre-plugin installs
if [[ -f "$HOME/.claude/hooks/sub-claude-done.sh" ]]; then
  rm -f "$HOME/.claude/hooks/sub-claude-done.sh"
  echo "  Removed legacy:    ~/.claude/hooks/sub-claude-done.sh"
fi
if [[ -f "$HOME/.claude/hooks/sub-claude-guardrails.sh" ]]; then
  rm -f "$HOME/.claude/hooks/sub-claude-guardrails.sh"
  echo "  Removed legacy:    ~/.claude/hooks/sub-claude-guardrails.sh"
fi

# Check PATH
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
  echo ""
  echo "WARNING: $BIN_DIR is not in your PATH."
  echo "  Add to your shell rc:  export PATH=\"$BIN_DIR:\$PATH\""
fi

echo ""
echo "Installation complete. Run 'sub-claude help' to get started."
