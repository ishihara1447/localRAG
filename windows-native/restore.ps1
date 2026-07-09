# restore.ps1 - Restore LocalRAG data from a backup zip created by backup.ps1.
#
# Overwrites app\server\storage and app\collector\hotdir with the backup content.
# .env files are restored only with -RestoreEnv (ports/paths may differ between machines).
#
# Usage (elevated PowerShell, from the install root):
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\restore.ps1 -BackupZip C:\ProgramData\LocalRAG\backups\localrag-backup-XXXX.zip

param(
    [Parameter(Mandatory = $true)][string]$BackupZip,
    [switch]$RestoreEnv
)

$ErrorActionPreference = "Stop"
$InstallRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not (Test-Path $BackupZip)) { Write-Host "ERROR: backup zip not found: $BackupZip"; exit 1 }
if (-not (Test-Path (Join-Path $InstallRoot "app\server"))) { Write-Host "ERROR: app\server not found. Is this the install root?"; exit 1 }

$staging = Join-Path $env:TEMP "localrag-restore-$(Get-Date -Format yyyyMMdd-HHmmss)"
Expand-Archive -Path $BackupZip -DestinationPath $staging
if (-not (Test-Path (Join-Path $staging "storage"))) {
    Remove-Item -Recurse -Force $staging
    Write-Host "ERROR: the zip does not look like a LocalRAG backup (no storage\ inside)."
    exit 1
}

Write-Host "Stopping services..."
foreach ($svc in @("LocalRAG-Server", "LocalRAG-Collector", "LocalRAG-Ollama")) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($s -and $s.Status -eq "Running") { Stop-Service -Name $svc -Force }
}

Write-Host "Restoring storage and hotdir..."
robocopy (Join-Path $staging "storage") (Join-Path $InstallRoot "app\server\storage") /MIR /NFL /NDL /NJH /NJS | Out-Null
if (Test-Path (Join-Path $staging "hotdir")) {
    robocopy (Join-Path $staging "hotdir") (Join-Path $InstallRoot "app\collector\hotdir") /MIR /NFL /NDL /NJH /NJS | Out-Null
}
if ($RestoreEnv) {
    if (Test-Path (Join-Path $staging "server.env")) { Copy-Item (Join-Path $staging "server.env") (Join-Path $InstallRoot "app\server\.env") -Force }
    if (Test-Path (Join-Path $staging "collector.env")) { Copy-Item (Join-Path $staging "collector.env") (Join-Path $InstallRoot "app\collector\.env") -Force }
}
$global:LASTEXITCODE = 0
Remove-Item -Recurse -Force $staging

Write-Host "Starting services..."
foreach ($svc in @("LocalRAG-Ollama", "LocalRAG-Collector", "LocalRAG-Server")) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($s) { Start-Service -Name $svc }
}
Write-Host "Restore complete."
