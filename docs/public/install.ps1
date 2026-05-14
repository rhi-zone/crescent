#Requires -Version 5.1
$ErrorActionPreference = "Stop"

# Windows: fold source + state under %LOCALAPPDATA%\crescent (overridable via $env:CRESCENT_HOME).
$LocalAppData = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $env:USERPROFILE "AppData\Local" }
$CrescentHome = if ($env:CRESCENT_HOME) { $env:CRESCENT_HOME } else { Join-Path $LocalAppData "crescent" }
$Repo = "https://github.com/rhi-zone/crescent.git"
$ZipUrl = "https://github.com/rhi-zone/crescent/archive/refs/heads/master.zip"

function Test-Command($name) {
  $null -ne (Get-Command $name -ErrorAction SilentlyContinue)
}

# Migration hint for users who installed under the old path.
$LegacyHome = Join-Path $env:USERPROFILE ".crescent"
if ((Test-Path $LegacyHome) -and -not (Test-Path $CrescentHome)) {
  Write-Host "note: $LegacyHome exists from a previous install."
  Write-Host "      Consider moving it to $CrescentHome (XDG-style layout on Windows):"
  Write-Host "        Move-Item `"$LegacyHome`" `"$CrescentHome`""
}

if (Test-Path (Join-Path $CrescentHome ".git")) {
  Write-Host "Updating crescent in $CrescentHome via git pull..."
  git -C $CrescentHome pull --ff-only
} elseif (Test-Path $CrescentHome) {
  Write-Error "$CrescentHome exists but is not a git checkout. Remove it or set CRESCENT_HOME elsewhere."
  exit 1
} elseif (Test-Command git) {
  Write-Host "Cloning crescent to $CrescentHome..."
  $parent = Split-Path -Parent $CrescentHome
  if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  git clone --depth 1 $Repo $CrescentHome
} else {
  Write-Host "Git not found; downloading zip to $CrescentHome..."
  New-Item -ItemType Directory -Force -Path $CrescentHome | Out-Null
  $tmpZip = Join-Path $env:TEMP "crescent-master.zip"
  $tmpDir = Join-Path $env:TEMP "crescent-master-extract"
  if (Test-Path $tmpDir) { Remove-Item -Recurse -Force $tmpDir }
  # Use TLS 1.2 for compatibility with older PowerShell defaults
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Invoke-WebRequest -UseBasicParsing -Uri $ZipUrl -OutFile $tmpZip
  Expand-Archive -Path $tmpZip -DestinationPath $tmpDir -Force
  # Zip contains a single top-level dir "crescent-master"; move its contents
  $inner = Get-ChildItem -Path $tmpDir | Select-Object -First 1
  Get-ChildItem -Path $inner.FullName -Force | ForEach-Object {
    Move-Item -Path $_.FullName -Destination $CrescentHome -Force
  }
  Remove-Item $tmpZip -Force
  Remove-Item -Recurse -Force $tmpDir
}

$BinDir = Join-Path $CrescentHome "bin"

# Update user PATH (idempotent). No symlink — Windows symlinks need admin.
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if (-not $userPath) { $userPath = "" }
$paths = $userPath -split ";" | Where-Object { $_ -ne "" }
if ($paths -notcontains $BinDir) {
  $newPath = if ($userPath) { "$userPath;$BinDir" } else { $BinDir }
  [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
  Write-Host "Added $BinDir to user PATH."
} else {
  Write-Host "$BinDir already in user PATH."
}

# Also update current session PATH
if (($env:Path -split ";") -notcontains $BinDir) {
  $env:Path = "$env:Path;$BinDir"
}

Write-Host ""
Write-Host "Installed crescent at $CrescentHome"
Write-Host "Run: $BinDir\cr.bat test  # verify"
Write-Host "Open a new terminal to pick up the PATH change."
