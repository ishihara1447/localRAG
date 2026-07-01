# restore.ps1 - バックアップから顧客データ (anythingllm-storage) を復元する。(restore.sh のWindows/PowerShell版)
#
# 使い方:
#   .\restore.ps1 -BackupFile <backup.tar.gz>
#
# 既存の anythingllm-storage\ は削除前に退避される（anythingllm-storage.bak-<日時>）。

param(
    [string]$BackupFile
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

if ([string]::IsNullOrWhiteSpace($BackupFile)) {
    Write-Host "使い方: .\restore.ps1 -BackupFile <backup.tar.gz>"
    Write-Host ""
    Write-Host "利用可能なバックアップ:"
    $Available = Get-ChildItem -Path (Join-Path $ScriptDir "backups") -Filter "*.tar.gz" -ErrorAction SilentlyContinue
    if ($Available) {
        $Available | ForEach-Object { Write-Host "  $($_.FullName)" }
    } else {
        Write-Host "  (backups\ にバックアップがありません)"
    }
    exit 1
}

if (-not (Test-Path $BackupFile -PathType Leaf)) {
    Write-Host "エラー: バックアップファイルが見つかりません: $BackupFile"
    exit 1
}

# バックアップ内容の妥当性チェック（anythingllm-storage を含むか）
$Listing = tar tzf $BackupFile 2>$null
if (-not ($Listing -match '^anythingllm-storage/')) {
    Write-Host "エラー: このファイルは LocalRAG のバックアップではないようです。"
    Write-Host "       (anythingllm-storage/ が含まれていません)"
    exit 1
}

Write-Host "復元元: $BackupFile"
Write-Host "警告: 現在の anythingllm-storage\ は退避されます。"
$Answer = Read-Host "続行しますか？ [y/N]"
if ($Answer -notmatch '^[Yy]$') {
    Write-Host "キャンセルしました。"
    exit 0
}

Write-Host "[1/4] サービスを停止中..."
docker compose down 2>$null

$StorageDir = Join-Path $ScriptDir "anythingllm-storage"
if (Test-Path $StorageDir -PathType Container) {
    $Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $BakDir = Join-Path $ScriptDir "anythingllm-storage.bak-$Timestamp"
    Write-Host "[2/4] 既存データを退避中: $(Split-Path -Leaf $BakDir)"
    Move-Item -Path $StorageDir -Destination $BakDir
} else {
    Write-Host "[2/4] 既存データなし（退避スキップ）"
}

Write-Host "[3/4] バックアップを展開中..."
tar xzf $BackupFile -C $ScriptDir
if ($LASTEXITCODE -ne 0) {
    Write-Host "エラー: バックアップの展開に失敗しました。"
    exit 1
}

Write-Host "[4/4] サービスを起動中..."
docker compose up -d
if ($LASTEXITCODE -ne 0) {
    Write-Host "エラー: サービスの起動に失敗しました。'docker compose logs' を確認してください。"
    exit 1
}

Write-Host ""
Write-Host "=== 復元完了 ==="
Write-Host "ブラウザ: http://localhost:3001"
Write-Host "退避した旧データが不要なら手動削除してください: anythingllm-storage.bak-*"
