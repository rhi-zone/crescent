#!/bin/sh
set -e

CRESCENT_HOME="${CRESCENT_HOME:-$HOME/.crescent}"
REPO="https://github.com/rhi-zone/crescent.git"
TARBALL="https://github.com/rhi-zone/crescent/archive/refs/heads/master.tar.gz"

say() { printf '%s\n' "$*"; }
err() { printf 'error: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# Detect existing install: prefer git pull, else re-download tarball
if [ -d "$CRESCENT_HOME/.git" ]; then
  say "Updating crescent in $CRESCENT_HOME via git pull..."
  git -C "$CRESCENT_HOME" pull --ff-only
elif [ -d "$CRESCENT_HOME" ]; then
  err "$CRESCENT_HOME exists but is not a git checkout. Remove it or set CRESCENT_HOME elsewhere."
elif have git; then
  say "Cloning crescent to $CRESCENT_HOME..."
  git clone --depth 1 "$REPO" "$CRESCENT_HOME"
elif have curl; then
  say "Git not found; downloading tarball to $CRESCENT_HOME..."
  mkdir -p "$CRESCENT_HOME"
  curl -fsSL "$TARBALL" | tar -xz --strip-components=1 -C "$CRESCENT_HOME"
elif have wget; then
  say "Git not found; downloading tarball to $CRESCENT_HOME..."
  mkdir -p "$CRESCENT_HOME"
  wget -qO- "$TARBALL" | tar -xz --strip-components=1 -C "$CRESCENT_HOME"
else
  err "Need git, curl, or wget to install."
fi

# Detect shell rc to add bin/ to PATH (idempotent)
BIN_DIR="$CRESCENT_HOME/bin"
case "${SHELL:-}" in
  */zsh)  RC="$HOME/.zshrc"                  ; LINE="export PATH=\"$BIN_DIR:\$PATH\"" ;;
  */bash) RC="$HOME/.bashrc"                 ; LINE="export PATH=\"$BIN_DIR:\$PATH\"" ;;
  */fish) RC="$HOME/.config/fish/config.fish"; LINE="fish_add_path \"$BIN_DIR\"" ;;
  *)      RC="$HOME/.profile"                ; LINE="export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac

mkdir -p "$(dirname "$RC")"
if [ -f "$RC" ] && grep -q "$BIN_DIR" "$RC"; then
  say "PATH entry already in $RC."
else
  printf '\n# crescent\n%s\n' "$LINE" >> "$RC"
  say "Added $BIN_DIR to PATH in $RC."
  say "Reload your shell or run: . \"$RC\""
fi

say ""
say "Installed crescent at $CRESCENT_HOME"
say "Run: $BIN_DIR/cr test  # verify"
