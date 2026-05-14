# Install

## One-liner

**Linux / macOS:**

```sh
curl -fsSL crescent.run/install.sh | sh
```

**Windows PowerShell:**

```powershell
iwr -useb crescent.run/install.ps1 | iex
```

**Windows cmd:**

```bat
curl -fsSL crescent.run/install.bat -o install.bat && install.bat
```

## Manual

**Git clone:**

```sh
# Linux / macOS — follow XDG Base Directory layout.
git clone https://github.com/rhi-zone/crescent.git \
  "${XDG_DATA_HOME:-$HOME/.local/share}/crescent"
ln -s "${XDG_DATA_HOME:-$HOME/.local/share}/crescent/bin/cr" \
  "${XDG_BIN_HOME:-$HOME/.local/bin}/cr"
# Ensure ${XDG_BIN_HOME:-$HOME/.local/bin} is on PATH (most modern systems do this).
```

**Download release:** [Source ZIP](https://github.com/rhi-zone/crescent/archive/refs/heads/master.zip) — extract anywhere; everything's vendored.

**Copy from another user:** the repo is fully self-contained (vendored binaries in `bin/`). Copy the folder, set `PATH`, done.

## Install layout (Linux / macOS, XDG Base Directory)

| What | Location |
|---|---|
| Git clone of crescent | `${XDG_DATA_HOME:-$HOME/.local/share}/crescent` |
| `cr` binary on PATH | `${XDG_BIN_HOME:-$HOME/.local/bin}/cr` (symlink) |
| Daemon apps dir | `${XDG_STATE_HOME:-$HOME/.local/state}/crescent/apps` |
| Daemon databases | `${XDG_STATE_HOME:-$HOME/.local/state}/crescent/db` |
| User config | `${XDG_CONFIG_HOME:-$HOME/.config}/crescent` |
| Cache | `${XDG_CACHE_HOME:-$HOME/.cache}/crescent` |

## Install layout (Windows)

| What | Location |
|---|---|
| Git clone | `%LOCALAPPDATA%\crescent` |
| `cr.bat` on PATH | `%LOCALAPPDATA%\crescent\bin` (added to user PATH) |
| Daemon apps dir | `%LOCALAPPDATA%\crescent\state\apps` |
| Daemon databases | `%LOCALAPPDATA%\crescent\state\db` |

Windows doesn't have an XDG spec; everything is bundled under `%LOCALAPPDATA%\crescent` with a `state\` subdir.

## Override install location

Set `CRESCENT_HOME` before running the script. This overrides the *source* dir
only — state, config, and cache still follow their own XDG env vars on Unix.

- Linux / macOS default: `${XDG_DATA_HOME:-$HOME/.local/share}/crescent`
- Windows default: `%LOCALAPPDATA%\crescent`
