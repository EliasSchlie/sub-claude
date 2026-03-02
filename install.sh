#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# install.sh — Install sub-claude CLI
# =============================================================================
# Installs the sub-claude binary and libraries to standard locations.
# Also sets up the Claude Code stop hook for pool completion detection.
#
# Usage:
#   ./install.sh              # install to ~/.local/{bin,lib}
#   ./install.sh --prefix /usr/local   # custom prefix
#   ./install.sh --uninstall  # remove installed files

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${HOME}/.local"
UNINSTALL=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)
      [[ $# -ge 2 ]] || { echo "install.sh: --prefix requires an argument" >&2; exit 1; }
      PREFIX="$2"; shift 2 ;;
    --uninstall) UNINSTALL=true; shift ;;
    -h|--help)
      cat <<'EOF'
Usage: ./install.sh [options]

Options:
  --prefix DIR    Install prefix (default: ~/.local)
  --uninstall     Remove installed files
  -h, --help      Show this help

Installs:
  <prefix>/bin/sub-claude           CLI binary
  <prefix>/lib/claude-pool/         Pool library
  <prefix>/lib/claude-output/       Output parser library
  ~/.claude/hooks/sub-claude-done.sh  Stop hook (optional)
EOF
      exit 0 ;;
    *) echo "install.sh: unknown option '$1'" >&2; exit 1 ;;
  esac
done

BIN_DIR="$PREFIX/bin"
LIB_DIR="$PREFIX/lib"

if $UNINSTALL; then
  echo "Uninstalling sub-claude..."
  rm -f "$BIN_DIR/sub-claude"
  rm -rf "$LIB_DIR/claude-pool"
  rm -rf "$LIB_DIR/claude-output"
  rm -f "$HOME/.claude/hooks/sub-claude-done.sh"
  echo "Done."
  exit 0
fi

echo "Installing sub-claude to $PREFIX..."

# Create directories
mkdir -p "$BIN_DIR" "$LIB_DIR/claude-pool" "$LIB_DIR/claude-output"

# Install binary
cp "$SCRIPT_DIR/bin/sub-claude" "$BIN_DIR/sub-claude"
chmod +x "$BIN_DIR/sub-claude"

# Install libraries
cp "$SCRIPT_DIR/lib/claude-pool/"*.sh "$LIB_DIR/claude-pool/"
cp "$SCRIPT_DIR/lib/claude-output/"*.sh "$LIB_DIR/claude-output/"

echo "  Installed binary:  $BIN_DIR/sub-claude"
echo "  Installed libs:    $LIB_DIR/claude-pool/"
echo "                     $LIB_DIR/claude-output/"

# Install stop hook (if ~/.claude/ exists)
if [[ -d "$HOME/.claude" ]]; then
  mkdir -p "$HOME/.claude/hooks"
  cp "$SCRIPT_DIR/hooks/sub-claude-done.sh" "$HOME/.claude/hooks/sub-claude-done.sh"
  chmod +x "$HOME/.claude/hooks/sub-claude-done.sh"
  echo "  Installed hook:    ~/.claude/hooks/sub-claude-done.sh"
  echo ""
  echo "NOTE: Add the stop hook to ~/.claude/settings.json if not already configured:"
  echo '  "hooks": {'
  echo '    "Stop": [{'
  echo '      "matcher": "",'
  echo '      "hooks": [{ "type": "command", "command": "~/.claude/hooks/sub-claude-done.sh" }]'
  echo '    }]'
  echo '  }'
else
  echo ""
  echo "NOTE: ~/.claude/ not found. Install Claude Code first, then re-run to install the stop hook."
  echo "  Or manually copy hooks/sub-claude-done.sh to ~/.claude/hooks/"
fi

# Check PATH
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
  echo ""
  echo "WARNING: $BIN_DIR is not in your PATH."
  echo "  Add to your shell rc:  export PATH=\"$BIN_DIR:\$PATH\""
fi

echo ""
echo "Installation complete. Run 'sub-claude help' to get started."
