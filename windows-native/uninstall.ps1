# uninstall.ps1 - Remove LocalRAG from this machine.
#
# Default: removes services and application files, KEEPS data
# (app\server\storage is moved to C:\ProgramData\LocalRAG\uninstalled-<date>\storage).
# -RemoveData: removes everything including storage, models and logs.
#
# Usage (elevated PowerShell, from the install root):
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1 -RemoveData

param(
    [switch]$RemoveData
)

$ErrorActionPreference = "Stop"
$SelfPath = $MyInvocation.MyCommand.Path
$InstallRoot = Split-Path -Parent $SelfPath
$DataRoot = "C:\ProgramData\LocalRAG"

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: run this script from an elevated (Administrator) PowerShell."
    exit 1
}

# 1. Unregister services
$unregister = Join-Path $InstallRoot "winsw\unregister-services.ps1"
if (Test-Path $unregister) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $unregister
} else {
    Write-Host "WARN: $unregister not found. Removing services via sc.exe."
    foreach ($svc in @("LocalRAG-Server", "LocalRAG-Collector", "LocalRAG-Ollama")) {
        Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        & sc.exe delete $svc 2>$null | Out-Null
    }
}

# 2. Preserve or remove data
$storage = Join-Path $InstallRoot "app\server\storage"
if (-not $RemoveData -and (Test-Path $storage)) {
    $keep = Join-Path $DataRoot "uninstalled-$(Get-Date -Format yyyyMMdd-HHmmss)"
    Write-Host "Preserving data to $keep (use -RemoveData to delete instead)..."
    New-Item -ItemType Directory -Path $keep -Force | Out-Null
    Move-Item $storage (Join-Path $keep "storage")
}

# 3. Remove the desktop shortcut (created by install.ps1)
$shortcut = Join-Path ([Environment]::GetFolderPath("CommonDesktopDirectory")) "LocalRAG.lnk"
if (Test-Path $shortcut) {
    Write-Host "Removing desktop shortcut $shortcut ..."
    Remove-Item $shortcut -Force -ErrorAction SilentlyContinue
}

# 4. Remove application files
Write-Host "Removing $InstallRoot ..."
# This script lives inside InstallRoot, so delete contents except this script,
# then schedule best-effort self-cleanup.
Get-ChildItem -Path $InstallRoot -Force | Where-Object { $_.FullName -ne $SelfPath } | ForEach-Object {
    Remove-Item -Recurse -Force $_.FullName -ErrorAction SilentlyContinue
}

# 5. Data root
if ($RemoveData) {
    Write-Host "Removing $DataRoot (models, logs, backups)..."
    Remove-Item -Recurse -Force $DataRoot -ErrorAction SilentlyContinue
} else {
    Write-Host "Kept: $DataRoot (models/logs/backups and preserved storage)."
}

Write-Host ""
Write-Host "Uninstall complete. You can delete the remaining uninstall.ps1 manually."
