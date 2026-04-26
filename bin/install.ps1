$ErrorActionPreference = "Stop"
$ReleaseUrl = "https://github.com/pterror/LuaJIT/releases/latest/download"
$Dir = Split-Path -Parent $MyInvocation.MyCommand.Path

$Arch = if ([Environment]::Is64BitOperatingSystem) { "x86_64" } else { "x86" }
$File = "luajit-windows-$Arch.exe"

Write-Host "Downloading $File..."
Invoke-WebRequest "$ReleaseUrl/$File" -OutFile "$Dir\luajit.exe"
Write-Host "Done. Run bin\cr to use crescent."
