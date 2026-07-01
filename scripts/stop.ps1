# stop.ps1 - LocalRAG サービスを停止する（データは保持される）。(stop.sh のWindows/PowerShell版)
$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

Write-Host "[停止] LocalRAG サービスを停止中..."
docker compose down
if ($LASTEXITCODE -ne 0) {
    Write-Host "エラー: docker compose down に失敗しました。"
    exit 1
}

Write-Host "停止しました。データ (anythingllm-storage\, ollama-models\) は保持されています。"
Write-Host "再起動するには: .\start.ps1"
