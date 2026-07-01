# uninstall.ps1 - LocalRAG をアンインストールする。(uninstall.sh のWindows/PowerShell版)
#
# 使い方:
#   .\uninstall.ps1                  データを削除して完全除去
#   .\uninstall.ps1 -KeepData        anythingllm-storage\ を残す（RAGデータ保持）

param(
    [switch]$KeepData
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

Write-Host "=== LocalRAG アンインストーラー ==="
if ($KeepData) {
    Write-Host "データ保持モード: 有効（anythingllm-storage\ を残す）"
} else {
    Write-Host "データ保持モード: 無効（全削除）"
}
Write-Host ""

# --- 確認プロンプト ---
if (-not $KeepData) {
    Write-Host "警告: anythingllm-storage\ (アップロード済み文書・ベクターDB) も削除されます。"
    Write-Host "      文書データを保持する場合は -KeepData オプションを使ってください。"
    Write-Host ""
    $Answer = Read-Host "続行しますか？ [y/N]"
    if ($Answer -notmatch '^[Yy]$') {
        Write-Host "アンインストールをキャンセルしました。"
        exit 0
    }
}

# --- 1. サービス停止とコンテナ削除 ---
Write-Host "[1/3] サービスを停止・削除中..."
$Running = docker compose ps --quiet 2>$null
if (-not [string]::IsNullOrWhiteSpace($Running)) {
    docker compose down --remove-orphans
    if ($LASTEXITCODE -ne 0) {
        Write-Host "エラー: サービスの停止・削除に失敗しました。"
        exit 1
    }
    Write-Host "      コンテナ・ネットワークを削除しました"
} else {
    Write-Host "      起動中のサービスはありませんでした"
}

# --- 2. Docker イメージ削除 ---
Write-Host "[2/3] Docker イメージを削除中..."
# 実際にインストールされた image は versions.lock に記録されている
# (バージョンにより image 名・タグが変わり得るため、それを優先する)。
# versions.lock が無い場合のみ、現行既定値にフォールバックする。
$AnythingLlmImage = "localrag-anythingllm:1.0.0"
$OllamaImage = "ollama/ollama:latest"
$VersionsLock = Join-Path $ScriptDir "versions.lock"
if (Test-Path $VersionsLock) {
    $Lines = Get-Content $VersionsLock
    $Match1 = $Lines | Where-Object { $_ -match '^ANYTHINGLLM_IMAGE=(.+)$' }
    if ($Match1) { $AnythingLlmImage = ($Match1 -replace '^ANYTHINGLLM_IMAGE=', '') }
    $Match2 = $Lines | Where-Object { $_ -match '^OLLAMA_IMAGE=(.+)$' }
    if ($Match2) { $OllamaImage = ($Match2 -replace '^OLLAMA_IMAGE=', '') }
}

$ImagesRemoved = 0
foreach ($Image in @($AnythingLlmImage, $OllamaImage)) {
    docker image inspect $Image *> $null
    if ($LASTEXITCODE -eq 0) {
        docker rmi $Image
        $ImagesRemoved++
    }
}
if ($ImagesRemoved -eq 0) {
    Write-Host "      削除対象のイメージはありませんでした"
} else {
    Write-Host "      $ImagesRemoved 個のイメージを削除しました"
}

# --- 3. データディレクトリ処理 ---
Write-Host "[3/3] データディレクトリを処理中..."
$StorageDir = Join-Path $ScriptDir "anythingllm-storage"
if ($KeepData) {
    Write-Host "      anythingllm-storage\ を保持します（-KeepData 指定）"
    Write-Host "      ★ 再インストール後もこのデータは引き続き使えます"
} else {
    if (Test-Path $StorageDir -PathType Container) {
        Remove-Item -Recurse -Force $StorageDir
        Write-Host "      anythingllm-storage\ を削除しました"
    }
}

# --- 完了 ---
Write-Host ""
Write-Host "=== アンインストール完了 ==="
Write-Host ""
Write-Host "【削除されたもの】"
Write-Host "  - コンテナ: anythingllm, rag-ollama"
Write-Host "  - ネットワーク: rag-internal, rag-public"
Write-Host "  - Docker イメージ: $AnythingLlmImage, $OllamaImage"
if (-not $KeepData) {
    Write-Host "  - データ: anythingllm-storage\"
}
Write-Host ""
Write-Host "【削除されていないもの】"
Write-Host "  - Ollama モデルファイル: ollama-models\ （大容量のため手動削除してください）"
Write-Host "    削除するには: Remove-Item -Recurse -Force '$ScriptDir\ollama-models'"
if ($KeepData) {
    Write-Host "  - アプリデータ: anythingllm-storage\ （-KeepData 指定）"
}
Write-Host "  - Docker Engine 本体（システム全体に影響するため自動削除しません）"
