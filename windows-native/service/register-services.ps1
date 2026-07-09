# register-services.ps1 - Install and start the three LocalRAG Windows services via WinSW.
#
# Comments and messages are ASCII-only on purpose (PowerShell 5.1 compatibility,
# same convention as scripts/*.ps1).
#
# Prerequisites:
#   - Run from an elevated (Administrator) PowerShell.
#   - WinSW.exe placed in this directory (bundled by the export script as WinSW.exe).
#     WinSW convention: each service needs "<Id>.exe" next to "<Id>.xml", so this
#     script copies WinSW.exe to LocalRAG-Server.exe / LocalRAG-Collector.exe /
#     LocalRAG-Ollama.exe before installing.
#   - Directory layout as described in docs/WINDOWS_NATIVE_PHASE4_DESIGN_2026-07-09.md:
#       <install root>\winsw\      (this directory)
#       <install root>\runtime\node\node.exe
#       <install root>\runtime\ollama\ollama.exe
#       <install root>\app\server, <install root>\app\collector
#       C:\ProgramData\LocalRAG\{storage,hotdir,models,logs}
#
# Usage:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\register-services.ps1
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\register-services.ps1 -NoStart

param(
    [switch]$NoStart
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Order matters: dependencies (Ollama, Collector) first, then Server.
$Services = @("LocalRAG-Ollama", "LocalRAG-Collector", "LocalRAG-Server")

# --- Elevation check ---
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: This script must be run from an elevated (Administrator) PowerShell."
    exit 1
}

# --- WinSW binary check ---
$WinSW = Join-Path $ScriptDir "WinSW.exe"
if (-not (Test-Path $WinSW)) {
    Write-Host "ERROR: WinSW.exe not found in $ScriptDir."
    Write-Host "       The distribution package should bundle it. If building manually,"
    Write-Host "       download WinSW-x64.exe (MIT license) from the WinSW releases page"
    Write-Host "       and save it here as WinSW.exe."
    exit 1
}

# --- Ensure data directories exist ---
foreach ($dir in @(
    "C:\ProgramData\LocalRAG\storage",
    "C:\ProgramData\LocalRAG\hotdir",
    "C:\ProgramData\LocalRAG\models",
    "C:\ProgramData\LocalRAG\logs"
)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Host "Created: $dir"
    }
}

# --- Install + start each service ---
foreach ($svc in $Services) {
    $xml = Join-Path $ScriptDir "$svc.xml"
    $exe = Join-Path $ScriptDir "$svc.exe"
    if (-not (Test-Path $xml)) {
        Write-Host "ERROR: $xml not found."
        exit 1
    }

    if (-not (Test-Path $exe)) {
        Copy-Item $WinSW $exe
    }

    $existing = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "SKIP install: service $svc already exists (state: $($existing.Status))."
    } else {
        Write-Host "Installing service: $svc"
        & $exe install
        if ($LASTEXITCODE -ne 0) {
            Write-Host "ERROR: failed to install $svc (exit $LASTEXITCODE)."
            exit 1
        }
    }

    if (-not $NoStart) {
        Write-Host "Starting service: $svc"
        & $exe start
        if ($LASTEXITCODE -ne 0) {
            Write-Host "ERROR: failed to start $svc (exit $LASTEXITCODE)."
            Write-Host "       Check logs under C:\ProgramData\LocalRAG\logs"
            exit 1
        }
    }
}

Write-Host ""
Write-Host "Done. Service status:"
Get-Service -Name $Services | Format-Table -AutoSize Name, Status, StartType
if (-not $NoStart) {
    Write-Host "LocalRAG UI: check the SERVER_PORT value in app\server\.env (default http://localhost:3001)"
}
