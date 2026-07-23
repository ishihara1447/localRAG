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
                    if ($procPath.StartsWith(($root.TrimEnd('\') + '\'), [System.StringComparison]::OrdinalIgnoreCase)) {
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

# The steps below are wrapped in individual try/catch so that one locked file
# (e.g. storage held open by a straggler process) does not abort the rest of
# the uninstall. Uninstall is idempotent, so it is better to run to the end and
# warn about what could not be removed than to stop at the first failure.

# 2. Preserve or remove data
# $storagePreserved は「顧客文書(storage)を app の外へ安全に退避できたか」を表す。
# keep-data モードで退避に失敗した場合、後続の app 一括削除で文書を消さないよう
# 手順5で app フォルダをスキップするために使う。
$storagePreserved = $false
$storage = Join-Path $InstallRoot "app\server\storage"
if (-not $RemoveData -and (Test-Path $storage)) {
    try {
        $keep = Join-Path $DataRoot "uninstalled-$(Get-Date -Format yyyyMMdd-HHmmss)"
        Write-Host "Preserving data to $keep (use -RemoveData to delete instead)..."
        New-Item -ItemType Directory -Path $keep -Force -ErrorAction Stop | Out-Null
        Move-Item $storage (Join-Path $keep "storage") -ErrorAction Stop
        $storagePreserved = $true
    } catch {
        Write-Host "WARN: 文書データ($storage)を退避できませんでした($($_.Exception.Message))。ロックしているアプリ(エクスプローラ/ウイルス対策等)がある可能性があります。文書を保護するため、この後 $InstallRoot\app は削除せずに残します。"
    }
}

# 3. Remove the desktop shortcuts (created by install.ps1)
$desktopDir = [Environment]::GetFolderPath("CommonDesktopDirectory")
foreach ($lnkName in @("LocalRAG.lnk", "OTE-RAG アンインストール.lnk")) {
    $shortcut = Join-Path $desktopDir $lnkName
    if (Test-Path $shortcut) {
        Write-Host "Removing desktop shortcut $shortcut ..."
        try { Remove-Item $shortcut -Force -ErrorAction Stop } catch {
            Write-Host "WARN: could not remove shortcut $shortcut ($($_.Exception.Message))."
        }
    }
}

# 4. Remove the Programs and Features (ARP) registry entry.
try {
    Remove-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OTE-RAG" -Recurse -Force -ErrorAction Stop
} catch {
    Write-Host "WARN: could not remove the Programs and Features entry ($($_.Exception.Message))."
}

# 5. Remove application files.
Write-Host "Removing $InstallRoot ..."
# This script (uninstall.ps1) lives inside InstallRoot, so it cannot delete
# itself while running. We delete every other entry now; the leftover
# uninstall.ps1 (and the empty InstallRoot folder) must be removed manually,
# as noted in the final message below.
Get-ChildItem -Path $InstallRoot -Force | Where-Object { $_.FullName -ne $SelfPath } | ForEach-Object {
    $entryPath = $_.FullName
    # keep-data モードで storage を退避できなかった場合、顧客文書を含む app フォルダは
    # 削除しない(サイレントな文書消失を防ぐ)。ユーザーには手動削除を案内する。
    if ((-not $RemoveData) -and (-not $storagePreserved) -and ($_.Name -eq "app")) {
        Write-Host "文書保護のため $entryPath は削除せず残しました。ロックを解除してから手動で削除してください。"
        return
    }
    try { Remove-Item -Recurse -Force $entryPath -ErrorAction Stop } catch {
        Write-Host "WARN: could not remove $entryPath ($($_.Exception.Message)). It may be in use; a reboot may be required."
    }
}

# 6. Data root
if ($RemoveData) {
    Write-Host "Removing $DataRoot (models, logs, backups)..."
    try { Remove-Item -Recurse -Force $DataRoot -ErrorAction Stop } catch {
        Write-Host "WARN: could not fully remove $DataRoot ($($_.Exception.Message)). It may be in use; a reboot may be required."
    }
} else {
    Write-Host "Kept: $DataRoot (models/logs/backups and preserved storage)."
}

Write-Host ""
Write-Host "Uninstall complete. You can delete the remaining uninstall.ps1 manually."
