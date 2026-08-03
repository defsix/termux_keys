#!/usr/bin/env bash
# Installer for conn: symlinks bin/conn onto PATH and creates config dirs.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${PREFIX:-$HOME/.local}/bin"

mkdir -p "$BIN_DIR"
ln -sf "$REPO_DIR/bin/conn" "$BIN_DIR/conn"
chmod +x "$REPO_DIR/bin/conn"

mkdir -p "$HOME/.config/conn/snippets" "$HOME/.config/conn/secrets" "$HOME/.config/conn/age"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
# ~/.ssh/config itself (and its Include line pointing at the synced
# ~/.config/conn/ssh_config) is set up by conn's own ensure_dirs on first
# run, which also knows how to safely migrate an existing config's content
# rather than just blindly creating an empty file here.

echo "conn: installed -> $BIN_DIR/conn"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "conn: add $BIN_DIR to your PATH (e.g. in ~/.bashrc): export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac
echo "conn: run 'conn doctor' to check dependencies, then 'conn add' to add a host."
