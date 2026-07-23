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

$Services = @("LocalRAG-Server", "LocalRAG-Collector", "LocalRAG-Ollama")

# Stop any ollama.exe / node.exe that belong to THIS install, matched by
# executable path so a customer's own Node/Ollama elsewhere is never touched.
function Stop-LocalRagProcesses {
    $roots = @($InstallRoot, $DataRoot) | Where-Object { $_ }
    foreach ($procName in @("ollama", "node")) {
        Get-Process -Name $procName -ErrorAction SilentlyContinue | ForEach-Object {
            $procPath = $null
            try { $procPath = $_.Path } catch {}
            if ($procPath) {
                foreach ($root in $roots) {
                    if ($procPath.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
                        Write-Host "Stopping process $($_.ProcessName) (PID $($_.Id)) from $procPath ..."
                        try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch {}
                        break
                    }
                }
            }
        }
    }
}

# 1. Unregister services
$unregister = Join-Path $InstallRoot "winsw\unregister-services.ps1"
if (Test-Path $unregister) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $unregister
} else {
    Write-Host "WARN: $unregister not found. Removing services via sc.exe."
    foreach ($svc in $Services) {
        Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        & sc.exe delete $svc 2>$null | Out-Null
    }
}

# 1b. Kill any leftover ollama.exe/node.exe (releases file locks so InstallRoot
# can actually be deleted below), then wait for the services to disappear.
# sc.exe delete only marks a service for deletion while handles remain open.
Stop-LocalRagProcesses

$deadline = (Get-Date).AddSeconds(30)
foreach ($svc in $Services) {
    while ((Get-Service -Name $svc -ErrorAction SilentlyContinue) -and ((Get-Date) -lt $deadline)) {
        Start-Sleep -Milliseconds 500
    }
}
$residual = Get-Service -Name "LocalRAG-*" -ErrorAction SilentlyContinue
if ($residual) {
    Write-Host "WARN: services still present after 30s: $($residual.Name -join ', '). A reboot may be required to finish removal."
}

# 2. Preserve or remove data
$storage = Join-Path $InstallRoot "app\server\storage"
if (-not $RemoveData -and (Test-Path $storage)) {
    $keep = Join-Path $DataRoot "uninstalled-$(Get-Date -Format yyyyMMdd-HHmmss)"
    Write-Host "Preserving data to $keep (use -RemoveData to delete instead)..."
    New-Item -ItemType Directory -Path $keep -Force | Out-Null
    Move-Item $storage (Join-Path $keep "storage")
}

# 3. Remove the desktop shortcuts (created by install.ps1)
$desktopDir = [Environment]::GetFolderPath("CommonDesktopDirectory")
foreach ($lnkName in @("LocalRAG.lnk", "OTE-RAG アンインストール.lnk")) {
    $shortcut = Join-Path $desktopDir $lnkName
    if (Test-Path $shortcut) {
        Write-Host "Removing desktop shortcut $shortcut ..."
        Remove-Item $shortcut -Force -ErrorAction SilentlyContinue
    }
}

# 4. Remove the Programs and Features (ARP) registry entry.
Remove-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OTE-RAG" -Recurse -Force -ErrorAction SilentlyContinue

# 5. Remove application files.
Write-Host "Removing $InstallRoot ..."
# This script (uninstall.ps1) lives inside InstallRoot, so it cannot delete
# itself while running. We delete every other entry now; the leftover
# uninstall.ps1 (and the empty InstallRoot folder) must be removed manually,
# as noted in the final message below.
Get-ChildItem -Path $InstallRoot -Force | Where-Object { $_.FullName -ne $SelfPath } | ForEach-Object {
    Remove-Item -Recurse -Force $_.FullName -ErrorAction SilentlyContinue
}

# 6. Data root
if ($RemoveData) {
    Write-Host "Removing $DataRoot (models, logs, backups)..."
    Remove-Item -Recurse -Force $DataRoot -ErrorAction SilentlyContinue
} else {
    Write-Host "Kept: $DataRoot (models/logs/backups and preserved storage)."
}

Write-Host ""
Write-Host "Uninstall complete. You can delete the remaining uninstall.ps1 manually."
