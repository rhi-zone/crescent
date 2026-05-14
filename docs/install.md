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
git clone https://github.com/rhi-zone/crescent.git ~/.crescent
echo 'export PATH="$HOME/.crescent/bin:$PATH"' >> ~/.bashrc
```

**Download release:** [Source ZIP](https://github.com/rhi-zone/crescent/archive/refs/heads/master.zip) — extract anywhere; everything's vendored.

**Copy from another user:** the repo is fully self-contained (vendored binaries in `bin/`). Copy the folder, set `PATH`, done.

## Override install location

Set `CRESCENT_HOME` before running the script. Default: `~/.crescent` (or `%USERPROFILE%\.crescent` on Windows).
