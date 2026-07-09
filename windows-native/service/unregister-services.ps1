# unregister-services.ps1 - Stop and remove the three LocalRAG Windows services.
#
# Does NOT delete any data (C:\ProgramData\LocalRAG is left untouched).
# Data removal is handled by the uninstaller, not here.
#
# Usage (elevated PowerShell):
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\unregister-services.ps1

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Reverse order: Server first (it depends on the other two).
$Services = @("LocalRAG-Server", "LocalRAG-Collector", "LocalRAG-Ollama")

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: This script must be run from an elevated (Administrator) PowerShell."
    exit 1
}

foreach ($svc in $Services) {
    $exe = Join-Path $ScriptDir "$svc.exe"
    $existing = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if (-not $existing) {
        Write-Host "SKIP: service $svc does not exist."
        continue
    }

    if (Test-Path $exe) {
        Write-Host "Stopping service: $svc"
        & $exe stop 2>$null
        Write-Host "Uninstalling service: $svc"
        & $exe uninstall
        if ($LASTEXITCODE -ne 0) {
            Write-Host "WARN: WinSW uninstall for $svc returned exit $LASTEXITCODE."
        }
    } else {
        # Fallback when the renamed WinSW exe is missing: use sc.exe directly.
        Write-Host "WARN: $exe not found. Falling back to sc.exe for $svc."
        Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        & sc.exe delete $svc | Out-Null
    }
}

Write-Host ""
Write-Host "Done. Remaining LocalRAG services (should be empty):"
Get-Service -Name "LocalRAG-*" -ErrorAction SilentlyContinue | Format-Table -AutoSize Name, Status
Write-Host "Data under C:\ProgramData\LocalRAG was NOT removed."
