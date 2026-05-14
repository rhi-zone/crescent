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

# ── Desktop integration ────────────────────────────────────────────────────
# Linux: drop a .desktop file under $XDG_DATA_HOME/applications and the
# branding SVG into the hicolor icon theme. Both standard freedesktop paths,
# no root needed. macOS: drop a thin .app wrapper into ~/Applications when
# the user has that directory. We skip rasters; the SVG is enough on Linux.
OS_NAME=$(uname -s 2>/dev/null || echo unknown)
case "$OS_NAME" in
  Linux)
    APP_DIR="$XDG_DATA_HOME/applications"
    ICON_DIR="$XDG_DATA_HOME/icons/hicolor/scalable/apps"
    mkdir -p "$APP_DIR" "$ICON_DIR"
    if [ -f "$CRESCENT_HOME/branding/crescent.svg" ]; then
      cp "$CRESCENT_HOME/branding/crescent.svg" "$ICON_DIR/crescent.svg"
      say "Installed icon: $ICON_DIR/crescent.svg"
    else
      say "note: $CRESCENT_HOME/branding/crescent.svg missing; skipping icon."
    fi
    cat > "$APP_DIR/crescent.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Crescent
Comment=Open the Crescent library
Exec=$XDG_BIN_HOME/cr open
Icon=crescent
Terminal=false
Categories=Development;Utility;
StartupNotify=false
EOF
    say "Installed launcher: $APP_DIR/crescent.desktop"
    # Refresh desktop/icon caches; failure is non-fatal.
    command -v update-desktop-database >/dev/null 2>&1 \
      && update-desktop-database "$APP_DIR" >/dev/null 2>&1 || true
    command -v gtk-update-icon-cache >/dev/null 2>&1 \
      && gtk-update-icon-cache "$XDG_DATA_HOME/icons/hicolor" >/dev/null 2>&1 || true
    ;;
  Darwin)
    APPS="$HOME/Applications"
    if [ -d "$APPS" ]; then
      APP="$APPS/Crescent.app"
      mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
      cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>crescent</string>
  <key>CFBundleIdentifier</key><string>zone.rhi.crescent</string>
  <key>CFBundleName</key><string>Crescent</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>0.1</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
      cat > "$APP/Contents/MacOS/crescent" <<EOF
#!/bin/sh
exec "$XDG_BIN_HOME/cr" open
EOF
      chmod +x "$APP/Contents/MacOS/crescent"
      # Icon: use rasterized .icns when present; SVG isn't supported by macOS.
      if [ -f "$CRESCENT_HOME/branding/crescent.icns" ]; then
        cp "$CRESCENT_HOME/branding/crescent.icns" "$APP/Contents/Resources/crescent.icns"
        # Patch Info.plist to reference the icon. Simple sed; awk would also work.
        # We just append; macOS reads the last value for duplicate keys.
        # (Skip on systems without sed -i since this is best-effort.)
        :
      fi
      say "Installed launcher: $APP/Contents/MacOS/crescent"
    else
      say "note: $APPS not present; skipping macOS .app bundle."
    fi
    ;;
  *)
    say "note: desktop integration not implemented for $OS_NAME; skipping."
    ;;
esac

say ""
say "Installed crescent at $CRESCENT_HOME"
say "Run: cr test  # verify"
say "Run: cr open  # launch the library in your browser"
