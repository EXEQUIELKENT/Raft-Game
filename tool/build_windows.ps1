# Builds Raft Rumble as a standalone Windows desktop application.
#
#   .\tool\build_windows.ps1
#
# Output lands in build\windows\x64\runner\<Mode>\ — the folder is
# self-contained enough to zip and hand to someone: raft_rumble.exe plus the
# Flutter engine DLL, the icudtl.dat data file and a data\ folder holding the
# app's assets and compiled Dart code.
#
# Requires the "Desktop development with C++" workload in Visual Studio 2022
# (or the Build Tools). Check with:  flutter doctor -v
[CmdletBinding()]
param(
    [ValidateSet('Release', 'Profile', 'Debug')]
    [string]$Mode = 'Release'
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    Write-Host "Building Raft Rumble for Windows ($Mode)..." -ForegroundColor Cyan

    if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
        Write-Error "flutter was not found on PATH. Install the Flutter SDK and add it to PATH first."
    }

    flutter config --enable-windows-desktop | Out-Null
    flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed' }

    flutter build windows --$($Mode.ToLowerInvariant())
    if ($LASTEXITCODE -ne 0) { throw 'flutter build windows failed' }

    $out = Join-Path $root "build\windows\x64\runner\$Mode"
    if (Test-Path $out) {
        Write-Host ""
        Write-Host "Built OK -> $out" -ForegroundColor Green
        Get-ChildItem $out | ForEach-Object { Write-Host ("   " + $_.Name) }
    }
}
finally {
    Pop-Location
}
