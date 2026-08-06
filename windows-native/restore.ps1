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
$DataRoot = "C:\ProgramData\LocalRAG"
if (-not (Test-Path $BackupZip)) { Write-Host "ERROR: backup zip not found: $BackupZip"; exit 1 }
if (-not (Test-Path (Join-Path $InstallRoot "app\server"))) { Write-Host "ERROR: app\server not found. Is this the install root?"; exit 1 }

$staging = Join-Path $env:TEMP "localrag-restore-$(Get-Date -Format yyyyMMdd-HHmmss)"
# tar.exe は zip も展開できる。Expand-Archive は 2GB 超で失敗するため使わない。
if (Get-Command tar.exe -ErrorAction SilentlyContinue) {
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    & tar.exe -xf $BackupZip -C $staging
    if ($LASTEXITCODE -ne 0) { $global:LASTEXITCODE = 0; Write-Host "ERROR: バックアップを展開できませんでした。"; exit 1 }
    $global:LASTEXITCODE = 0
} else {
    Expand-Archive -Path $BackupZip -DestinationPath $staging
}
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

# 🔴 ここから先で中断してもサービスを止めたままにしない。
# データは守られても製品が起動しなくなり、顧客からは
# 「復元に失敗したうえ OTE-RAG が動かなくなった」と見える。
function Start-AllServices {
    Write-Host "Starting services..."
    foreach ($svc in @("LocalRAG-Ollama", "LocalRAG-Collector", "LocalRAG-Server")) {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($s -and $s.Status -ne "Running") {
            try { Start-Service -Name $svc -ErrorAction Stop } catch {
                Write-Host "  WARN: $svc を再開できませんでした($($_.Exception.Message))。"
            }
        }
    }
}
function Abort([string]$msg) {
    Write-Host "ERROR: $msg"
    Start-AllServices
    exit 1
}

# 🔴 /MIR は上書きではなく同期なので、復元前の状態は戻せない。先に退避する。
$storageNow = Join-Path $InstallRoot "app\server\storage"
$safety = "(退避なし)"
if (Test-Path $storageNow) {
    $safety = Join-Path $DataRoot "before-restore-$(Get-Date -Format yyyyMMdd-HHmmss)"
    Write-Host "Saving the current storage to $safety before overwriting..."
    New-Item -ItemType Directory -Path $safety -Force | Out-Null
    robocopy $storageNow (Join-Path $safety "storage") /E /R:2 /W:5 /NFL /NDL /NJH /NJS | Out-Null
    if ($LASTEXITCODE -ge 8) {
        $global:LASTEXITCODE = 0
        Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue
        Abort "復元前の退避に失敗しました。現在のデータを壊さないため中止します。"
    }
    $global:LASTEXITCODE = 0
}

Write-Host "Restoring storage and hotdir..."
# 🔴 storage\models には**製品同梱**のリランカーと OCR 言語データが入っている
# (export-windows.ps1 が storage\models 配下に置く)。/MIR でそのまま同期すると、
# 古いバックアップに無いこれらが削除される。リランカーは読み込みに失敗しても
# 例外を投げず黙って元の検索順へ落ちるため、**エラーが出ないまま精度だけ落ちる**。
# OCR 言語データが消えるとスキャンPDFの取り込みが失敗する。models は同期対象から外す。
robocopy (Join-Path $staging "storage") $storageNow /MIR /XD models /R:2 /W:5 /NFL /NDL /NJH /NJS | Out-Null
if ($LASTEXITCODE -ge 8) {
    $global:LASTEXITCODE = 0
    Write-Host "       復元前の状態は $safety に退避してあります。"
    Abort "storage の復元に失敗しました(コピーできないファイルがあります)。"
}
$global:LASTEXITCODE = 0
# バックアップ側に models があれば、削除ではなく追加のみで戻す(顧客が入れた物を拾う)。
if (Test-Path (Join-Path $staging "storage\models")) {
    robocopy (Join-Path $staging "storage\models") (Join-Path $storageNow "models") /E /R:2 /W:5 /NFL /NDL /NJH /NJS | Out-Null
    $global:LASTEXITCODE = 0
}
if (Test-Path (Join-Path $staging "hotdir")) {
    robocopy (Join-Path $staging "hotdir") (Join-Path $InstallRoot "app\collector\hotdir") /MIR /R:2 /W:5 /NFL /NDL /NJH /NJS | Out-Null
    $global:LASTEXITCODE = 0
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
