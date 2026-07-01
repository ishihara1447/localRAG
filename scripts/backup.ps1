# backup.ps1 - 顧客データ (anythingllm-storage) をバックアップする。(backup.sh のWindows/PowerShell版)
#
# 使い方:
#   .\backup.ps1              既定: サービスを一時停止して整合性の取れたバックアップを作成
#   .\backup.ps1 -Live        サービスを止めずにバックアップ（DB書き込み中の不整合の恐れ）
#
# 出力: backups\localrag-backup-<日時>.tar.gz
#
# 前提: Windows 10 1803以降 / Windows 11 に標準搭載の tar.exe (bsdtar) を使用する。
#       Linux版(backup.sh/restore.sh)と同じ .tar.gz 形式のため、相互に復元可能。

param(
    [switch]$Live
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

$StorageDir = Join-Path $ScriptDir "anythingllm-storage"
if (-not (Test-Path $StorageDir -PathType Container)) {
    Write-Host "エラー: anythingllm-storage\ が見つかりません。バックアップ対象がありません。"
    exit 1
}

$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$BackupsDir = Join-Path $ScriptDir "backups"
New-Item -ItemType Directory -Force -Path $BackupsDir | Out-Null
$BackupFile = Join-Path $BackupsDir "localrag-backup-$Timestamp.tar.gz"

$RunningServices = docker compose ps --status running --quiet 2>$null
$WasRunning = -not [string]::IsNullOrWhiteSpace($RunningServices)

# 整合性確保のためサービス停止（-Live 指定時は停止しない）
if (-not $Live -and $WasRunning) {
    Write-Host "[1/3] 整合性確保のためサービスを一時停止中..."
    docker compose stop
    if ($LASTEXITCODE -ne 0) {
        Write-Host "エラー: サービスの停止に失敗しました。"
        exit 1
    }
} elseif ($Live) {
    Write-Host "[1/3] -Live 指定: サービスを停止せずにバックアップします（不整合の恐れ）"
}

Write-Host "[2/3] バックアップを作成中: $BackupFile"
$BackupItems = @("anythingllm-storage")
if (Test-Path (Join-Path $ScriptDir "versions.lock")) {
    $BackupItems += "versions.lock"
}
tar czf $BackupFile -C $ScriptDir @BackupItems
if ($LASTEXITCODE -ne 0) {
    Write-Host "エラー: バックアップの作成に失敗しました。"
    exit 1
}

# サービスを元の状態に戻す
if (-not $Live -and $WasRunning) {
    Write-Host "[3/3] サービスを再起動中..."
    docker compose start
    if ($LASTEXITCODE -ne 0) {
        Write-Host "警告: サービスの再起動に失敗しました。手動で 'docker compose start' を実行してください。"
    }
} else {
    Write-Host "[3/3] 完了"
}

$SizeMB = [math]::Round((Get-Item $BackupFile).Length / 1MB, 1)
Write-Host ""
Write-Host "=== バックアップ完了 ==="
Write-Host "ファイル: $BackupFile"
Write-Host "サイズ:   $SizeMB MB"
Write-Host ""
Write-Host "復元するには: .\restore.ps1 -BackupFile '$BackupFile'"
