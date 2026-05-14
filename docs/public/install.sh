#!/bin/sh
set -e

XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
XDG_BIN_HOME="${XDG_BIN_HOME:-$HOME/.local/bin}"
CRESCENT_HOME="${CRESCENT_HOME:-$XDG_DATA_HOME/crescent}"
REPO="https://github.com/rhi-zone/crescent.git"
TARBALL="https://github.com/rhi-zone/crescent/archive/refs/heads/master.tar.gz"

say() { printf '%s\n' "$*"; }
err() { printf 'error: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# Migration hint for users who installed under the old path.
if [ -d "$HOME/.crescent" ] && [ ! -d "$CRESCENT_HOME" ]; then
  say "note: $HOME/.crescent exists from a previous install."
  say "      Consider moving it to $CRESCENT_HOME (XDG Base Directory layout):"
  say "        mv \"$HOME/.crescent\" \"$CRESCENT_HOME\""
fi

# Detect existing install: prefer git pull, else re-download tarball
if [ -d "$CRESCENT_HOME/.git" ]; then
  say "Updating crescent in $CRESCENT_HOME via git pull..."
  git -C "$CRESCENT_HOME" pull --ff-only
elif [ -d "$CRESCENT_HOME" ]; then
  err "$CRESCENT_HOME exists but is not a git checkout. Remove it or set CRESCENT_HOME elsewhere."
elif have git; then
  say "Cloning crescent to $CRESCENT_HOME..."
  mkdir -p "$(dirname "$CRESCENT_HOME")"
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

# Symlink cr into $XDG_BIN_HOME so it's on PATH on standard XDG systems.
mkdir -p "$XDG_BIN_HOME"
ln -sf "$CRESCENT_HOME/bin/cr" "$XDG_BIN_HOME/cr"
say "Linked $XDG_BIN_HOME/cr -> $CRESCENT_HOME/bin/cr"

# If $XDG_BIN_HOME is already on PATH (the case on most modern Linux/macOS),
# we're done. Otherwise drop a PATH line into the user's shell rc.
case ":$PATH:" in
  *":$XDG_BIN_HOME:"*)
    say "$XDG_BIN_HOME is already on PATH."
    ;;
  *)
    case "${SHELL:-}" in
      */zsh)  RC="$HOME/.zshrc"                  ; LINE="export PATH=\"$XDG_BIN_HOME:\$PATH\"" ;;
      */bash) RC="$HOME/.bashrc"                 ; LINE="export PATH=\"$XDG_BIN_HOME:\$PATH\"" ;;
      */fish) RC="$HOME/.config/fish/config.fish"; LINE="fish_add_path \"$XDG_BIN_HOME\"" ;;
      *)      RC="$HOME/.profile"                ; LINE="export PATH=\"$XDG_BIN_HOME:\$PATH\"" ;;
    esac
    mkdir -p "$(dirname "$RC")"
    if [ -f "$RC" ] && grep -q "$XDG_BIN_HOME" "$RC"; then
      say "PATH entry already in $RC."
    else
      printf '\n# crescent (XDG_BIN_HOME)\n%s\n' "$LINE" >> "$RC"
      say "Added $XDG_BIN_HOME to PATH in $RC."
      say "Reload your shell or run: . \"$RC\""
    fi
    ;;
esac

say ""
say "Installed crescent at $CRESCENT_HOME"
say "Run: cr test  # verify"
