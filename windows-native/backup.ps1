# backup.ps1 - Back up LocalRAG data (storage + hotdir + .env files).
#
# Stops the services during the backup for a consistent SQLite/LanceDB snapshot,
# then restarts them. Models and application binaries are NOT backed up (they
# are restored from the distribution package instead).
#
# Usage (elevated PowerShell, from the install root):
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\backup.ps1
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\backup.ps1 -OutputDir D:\backups

param(
    [string]$OutputDir = "C:\ProgramData\LocalRAG\backups"
)

$ErrorActionPreference = "Stop"
$InstallRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$storage = Join-Path $InstallRoot "app\server\storage"
if (-not (Test-Path $storage)) { Write-Host "ERROR: $storage not found. Is this the install root?"; exit 1 }

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$zip = Join-Path $OutputDir "localrag-backup-$stamp.zip"

$wasRunning = @()
foreach ($svc in @("LocalRAG-Server", "LocalRAG-Collector", "LocalRAG-Ollama")) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($s -and $s.Status -eq "Running") { $wasRunning += $svc }
}

try {
    if ($wasRunning.Count -gt 0) {
        Write-Host "Stopping services for a consistent snapshot..."
        foreach ($svc in @("LocalRAG-Server", "LocalRAG-Collector", "LocalRAG-Ollama")) {
            if ($wasRunning -contains $svc) { Stop-Service -Name $svc -Force }
        }
    }

    Write-Host "Creating $zip ..."
    $staging = Join-Path $env:TEMP "localrag-backup-$stamp"
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    robocopy $storage (Join-Path $staging "storage") /E /NFL /NDL /NJH /NJS | Out-Null
    robocopy (Join-Path $InstallRoot "app\collector\hotdir") (Join-Path $staging "hotdir") /E /NFL /NDL /NJH /NJS | Out-Null
    Copy-Item (Join-Path $InstallRoot "app\server\.env") (Join-Path $staging "server.env") -ErrorAction SilentlyContinue
    Copy-Item (Join-Path $InstallRoot "app\collector\.env") (Join-Path $staging "collector.env") -ErrorAction SilentlyContinue
    $global:LASTEXITCODE = 0
    Compress-Archive -Path "$staging\*" -DestinationPath $zip -CompressionLevel Optimal
    Remove-Item -Recurse -Force $staging
    Write-Host "Backup complete: $zip"
}
finally {
    if ($wasRunning.Count -gt 0) {
        Write-Host "Restarting services..."
        foreach ($svc in @("LocalRAG-Ollama", "LocalRAG-Collector", "LocalRAG-Server")) {
            if ($wasRunning -contains $svc) { Start-Service -Name $svc }
        }
    }
}
