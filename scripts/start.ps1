# start.ps1 - LocalRAG サービスを起動する。(start.sh のWindows/PowerShell版)
$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

Write-Host "[起動] LocalRAG サービスを起動中..."
docker compose up -d
if ($LASTEXITCODE -ne 0) {
    Write-Host "エラー: docker compose up に失敗しました。"
    exit 1
}

Write-Host "[待機] AnythingLLM の起動を待機中..."
for ($i = 1; $i -le 36; $i++) {
    try {
        $response = Invoke-WebRequest -Uri "http://localhost:3001/api/ping" -UseBasicParsing -TimeoutSec 5
        if ($response.StatusCode -eq 200) {
            Write-Host ""
            Write-Host "起動完了: http://localhost:3001"
            exit 0
        }
    } catch {
        # まだ起動していない。待機を継続する。
    }
    Write-Host -NoNewline "."
    Start-Sleep -Seconds 5
}

Write-Host ""
Write-Host "警告: 3 分以内に起動を確認できませんでした。ログ: docker compose logs -f"
exit 1
