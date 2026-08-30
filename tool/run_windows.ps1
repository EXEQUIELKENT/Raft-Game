# Runs Raft Rumble on Windows (desktop).
#
#   .\tool\run_windows.ps1                 # debug, hot reload enabled
#   .\tool\run_windows.ps1 -Mode release   # release, no hot reload, fast
#   .\tool\run_windows.ps1 -Mode profile   # release speed + DevTools
#
# Requires the "Desktop development with C++" workload in Visual Studio 2022
# (or the Build Tools) — Flutter compiles the Win32 runner host from
# windows/runner with MSVC. Check with:  flutter doctor -v
[CmdletBinding()]
param(
    [ValidateSet('debug', 'profile', 'release')]
    [string]$Mode = 'debug'
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    Write-Host "Running Raft Rumble on Windows ($Mode)..." -ForegroundColor Cyan

    if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
        Write-Error "flutter was not found on PATH. Install the Flutter SDK and add it to PATH first."
    }

    flutter config --enable-windows-desktop | Out-Null
    flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed' }

    flutter run -d windows -t lib/main.dart --$Mode
    if ($LASTEXITCODE -ne 0) { throw 'flutter run failed' }
}
finally {
    Pop-Location
}
