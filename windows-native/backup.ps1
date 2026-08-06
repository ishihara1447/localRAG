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
    # 🔴 robocopy の終了コードは必ず見ること。8 以上は「一部をコピーできなかった」で、
    # 見逃すと**欠けたバックアップを「成功」と表示**してしまう。顧客はそれを完全な
    # バックアップだと信じ、後日 restore.ps1 の /MIR で現行データを欠けた内容に
    # 置き換える。取りこぼした文書は現行側からも消え、二度と戻らない。
    robocopy $storage (Join-Path $staging "storage") /E /R:2 /W:5 /NFL /NDL /NJH /NJS | Out-Null
    if ($LASTEXITCODE -ge 8) {
        $global:LASTEXITCODE = 0
        Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue
        Write-Host "ERROR: 文書データをコピーできませんでした(ウイルス対策ソフトや別プログラムが"
        Write-Host "       ファイルを掴んでいる可能性があります)。**バックアップは作成していません。**"
        Write-Host "       サービスを停止してから、もう一度実行してください。"
        exit 1
    }
    $global:LASTEXITCODE = 0
    robocopy (Join-Path $InstallRoot "app\collector\hotdir") (Join-Path $staging "hotdir") /E /R:2 /W:5 /NFL /NDL /NJH /NJS | Out-Null
    if ($LASTEXITCODE -ge 8) {
        Write-Host "WARN: hotdir をコピーできませんでした(取り込み待ちの一時ファイルのため、続行します)。"
    }
    Copy-Item (Join-Path $InstallRoot "app\server\.env") (Join-Path $staging "server.env") -ErrorAction SilentlyContinue
    Copy-Item (Join-Path $InstallRoot "app\collector\.env") (Join-Path $staging "collector.env") -ErrorAction SilentlyContinue
    $global:LASTEXITCODE = 0
    # 🔴 Compress-Archive は PowerShell 5.1 では 2GB を超えるアーカイブで失敗する。
    # 実測で 545ページPDF 1本あたり storage 約50MB。数百文書で 2GB を超える。
    # Windows 標準の tar.exe は zip も作れて上限が無い。
    if (Get-Command tar.exe -ErrorAction SilentlyContinue) {
        & tar.exe -a -c -f $zip -C $staging .
        if ($LASTEXITCODE -ne 0) { $global:LASTEXITCODE = 0; throw "バックアップの圧縮に失敗しました。" }
        $global:LASTEXITCODE = 0
    } else {
        Compress-Archive -Path "$staging\*" -DestinationPath $zip -CompressionLevel Optimal
    }
    Remove-Item -Recurse -Force $staging
    $zipSize = [math]::Round((Get-Item $zip).Length / 1MB, 1)
    Write-Host "Backup complete: $zip ($zipSize MB)"
}
finally {
    if ($wasRunning.Count -gt 0) {
        Write-Host "Restarting services..."
        foreach ($svc in @("LocalRAG-Ollama", "LocalRAG-Collector", "LocalRAG-Server")) {
            if ($wasRunning -contains $svc) { Start-Service -Name $svc }
        }
    }
}
