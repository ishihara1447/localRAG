# install.ps1 - LocalRAG をインストールして起動する。(install.sh のWindows/PowerShell版)
#
# 使い方:
#   .\install.ps1
#
# 必要条件:
#   - Docker Desktop (Docker Engine + Docker Compose v2)（インターネット接続不要）
#   - NVIDIA ドライバ + WSL2 GPU連携（GPU 推論用）
#   - このスクリプトと同じディレクトリに以下が存在すること（欠落時はインストール失敗）:
#       images\rag-images.tar.gz        Docker イメージアーカイブ
#       ollama-models\                  Ollama モデルファイル群
#       docker-compose.yml              Compose 設定
#       versions.lock                   バージョン固定ファイル
#       checksums\images.sha256         イメージ tar のチェックサム（必須）
#       checksums\ollama-models.sha256  モデルファイルのチェックサム（必須）
#       checksums\package.sha256        パッケージ全体のチェックサム（必須）
#
# 注意: Windows には sha256sum コマンドが無いため、Get-FileHash で
#       同等のSHA-256検証を行う。sha256sum形式(<hash>  <相対パス>)の
#       マニフェストを解釈する。

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

$LogFile = Join-Path $ScriptDir "install.log"
$RequiredFreeGB = 5
$HealthcheckRetries = 36
$HealthcheckIntervalSec = 5

function Write-Log {
    param([string]$Level, [string]$Message)
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $Line = "[$Timestamp] [$Level] $Message"
    Write-Host $Line
    Add-Content -Path $LogFile -Value $Line
}

# 実際のチェックサム検証を行う (sha256sum 形式マニフェストを解釈)
function Test-Sha256Manifest {
    param([string]$ManifestPath, [string]$BaseDir)
    $Lines = Get-Content $ManifestPath
    foreach ($Line in $Lines) {
        if ($Line -notmatch '^([0-9a-fA-F]{64})\s+\*?(.+)$') { continue }
        $ExpectedHash = $Matches[1].ToLower()
        $RelPath = $Matches[2]
        $FullPath = Join-Path $BaseDir $RelPath
        if (-not (Test-Path $FullPath -PathType Leaf)) {
            Write-Log ERROR "      $RelPath が見つかりません"
            return $false
        }
        $ActualHash = (Get-FileHash -Path $FullPath -Algorithm SHA256).Hash.ToLower()
        if ($ActualHash -ne $ExpectedHash) {
            Write-Log ERROR "      $RelPath のチェックサム不一致"
            return $false
        }
    }
    return $true
}

Write-Log INFO "=== LocalRAG インストーラー 開始 ==="
Write-Log INFO "インストール先: $ScriptDir"
$VersionsLock = Join-Path $ScriptDir "versions.lock"
if (Test-Path $VersionsLock) {
    Write-Log INFO "--- バージョン情報 ---"
    Get-Content $VersionsLock | Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() -ne "" } | ForEach-Object {
        Write-Log INFO "  $_"
    }
    Write-Log INFO "---------------------"
}

# ---------------------------------------------------------------------------
# 前提条件チェック（全チェックを実行してから失敗させる）
# ---------------------------------------------------------------------------
Write-Log INFO "[チェック] 前提条件を確認中..."
$PreflightOk = $true

# Docker インストール確認
$DockerCmd = Get-Command docker -ErrorAction SilentlyContinue
if (-not $DockerCmd) {
    Write-Log ERROR "  [NG] Docker がインストールされていません。"
    Write-Log ERROR "       Docker Desktop for Windows を IT 担当者に依頼してください。"
    $PreflightOk = $false
} else {
    $DockerVer = (docker --version)
    Write-Log INFO "  [OK] $DockerVer"
}

# Docker デーモン稼働確認
if ($DockerCmd) {
    docker info *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Log ERROR "  [NG] Docker デーモンが起動していません。Docker Desktop を起動してください。"
        $PreflightOk = $false
    }
}

# Docker Compose v2 確認
docker compose version *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Log ERROR "  [NG] Docker Compose v2 がインストールされていません。"
    $PreflightOk = $false
} else {
    $ComposeVer = (docker compose version --short 2>$null)
    Write-Log INFO "  [OK] Docker Compose $ComposeVer"
}

# ディスク空き容量チェック
$Drive = (Get-Item $ScriptDir).PSDrive
$AvailGB = [math]::Round($Drive.Free / 1GB, 1)
if ($AvailGB -lt $RequiredFreeGB) {
    Write-Log ERROR "  [NG] ディスク空き容量不足。必要: ${RequiredFreeGB}GB、現在: ${AvailGB}GB"
    $PreflightOk = $false
} else {
    Write-Log INFO "  [OK] ディスク空き: ${AvailGB}GB"
}

# ポート 3001 が使用中でないか確認
$PortInUse = Get-NetTCPConnection -LocalPort 3001 -State Listen -ErrorAction SilentlyContinue
if ($PortInUse) {
    Write-Log ERROR "  [NG] ポート 3001 が既に使用されています。"
    Write-Log ERROR "       競合するプロセスを停止するか、docker-compose.yml でポートを変更してください。"
    $PreflightOk = $false
} else {
    Write-Log INFO "  [OK] ポート 3001 は空き"
}

# NVIDIA Container Runtime 確認（警告のみ、致命的ではない）
$Runtimes = docker info --format '{{.Runtimes}}' 2>$null
if ($Runtimes -notmatch 'nvidia') {
    Write-Log INFO "  [警告] NVIDIA Container Runtime が検出されませんでした。"
    Write-Log INFO "         GPU なしでも起動できますが推論速度が非常に遅くなります。"
    $GpuAvailable = $false
} else {
    Write-Log INFO "  [OK] NVIDIA Container Runtime"
    $GpuAvailable = $true
}

# 必須ファイル確認
$ImagesTar = Join-Path $ScriptDir "images\rag-images.tar.gz"
if (-not (Test-Path $ImagesTar -PathType Leaf)) {
    Write-Log ERROR "  [NG] images\rag-images.tar.gz が見つかりません。"
    $PreflightOk = $false
} else {
    $SizeGB = [math]::Round((Get-Item $ImagesTar).Length / 1GB, 2)
    Write-Log INFO "  [OK] images\rag-images.tar.gz (${SizeGB}GB)"
}

$OllamaModelsDir = Join-Path $ScriptDir "ollama-models"
if (-not (Test-Path $OllamaModelsDir -PathType Container)) {
    Write-Log ERROR "  [NG] ollama-models\ ディレクトリが見つかりません。"
    $PreflightOk = $false
} else {
    Write-Log INFO "  [OK] ollama-models\"
}

$ComposeFile = Join-Path $ScriptDir "docker-compose.yml"
if (-not (Test-Path $ComposeFile -PathType Leaf)) {
    Write-Log ERROR "  [NG] docker-compose.yml が見つかりません。"
    $PreflightOk = $false
} else {
    Write-Log INFO "  [OK] docker-compose.yml"
}

foreach ($Req in @("checksums\images.sha256", "checksums\ollama-models.sha256", "checksums\package.sha256")) {
    $ReqPath = Join-Path $ScriptDir $Req
    if (-not (Test-Path $ReqPath -PathType Leaf)) {
        Write-Log ERROR "  [NG] $Req が見つかりません（真正性検証に必須）。"
        $PreflightOk = $false
    } else {
        Write-Log INFO "  [OK] $Req"
    }
}

if (-not $PreflightOk) {
    exit 1
}

# ---------------------------------------------------------------------------
# 冪等性チェック: 既にサービスが起動中なら再起動を促して終了
# ---------------------------------------------------------------------------
$RunningNames = docker ps --format '{{.Names}}' 2>$null
if ($RunningNames -match '^anythingllm$') {
    Write-Log INFO ""
    Write-Log INFO "LocalRAG は既に起動中です。"
    Write-Log INFO "  ブラウザ: http://localhost:3001"
    Write-Log INFO "  再起動する場合: docker compose restart"
    Write-Log INFO "  停止する場合:   .\uninstall.ps1 (データを残す場合は -KeepData)"
    exit 3
}

# ---------------------------------------------------------------------------
# 1. SHA-256 チェックサム検証（イメージ + モデル manifest + パッケージ全体）
# ---------------------------------------------------------------------------
Write-Log INFO ""
Write-Log INFO "[1/4] チェックサムを検証中..."

Write-Log INFO "      イメージ tar を検証中..."
if (-not (Test-Sha256Manifest (Join-Path $ScriptDir "checksums\images.sha256") (Join-Path $ScriptDir "images"))) {
    Write-Log ERROR "イメージのチェックサム不一致。ファイル破損の可能性があります。再転送してください。"
    exit 2
}

Write-Log INFO "      モデルファイルを検証中..."
if (-not (Test-Sha256Manifest (Join-Path $ScriptDir "checksums\ollama-models.sha256") $ScriptDir)) {
    Write-Log ERROR "モデルのチェックサム不一致。ファイル破損の可能性があります。再転送してください。"
    exit 2
}

Write-Log INFO "      パッケージ全体を検証中..."
if (-not (Test-Sha256Manifest (Join-Path $ScriptDir "checksums\package.sha256") $ScriptDir)) {
    Write-Log ERROR "パッケージのチェックサム不一致。ファイル破損の可能性があります。再転送してください。"
    exit 2
}

Write-Log INFO "      チェックサム検証 OK"

# ---------------------------------------------------------------------------
# 2. Docker イメージのロード
# ---------------------------------------------------------------------------
Write-Log INFO ""
Write-Log INFO "[2/4] Docker イメージを読み込み中（数分かかります）..."
docker load -i $ImagesTar
if ($LASTEXITCODE -ne 0) {
    Write-Log ERROR "Docker イメージの読み込みに失敗しました。"
    exit 2
}
Write-Log INFO "      イメージ読み込み完了"

# ---------------------------------------------------------------------------
# 3. データディレクトリの作成
# ---------------------------------------------------------------------------
Write-Log INFO ""
Write-Log INFO "[3/4] データディレクトリを準備中..."
New-Item -ItemType Directory -Force -Path (Join-Path $ScriptDir "anythingllm-storage") | Out-Null
Write-Log INFO "      anythingllm-storage\ を作成しました"

# ---------------------------------------------------------------------------
# 4. サービス起動
# ---------------------------------------------------------------------------
Write-Log INFO ""
Write-Log INFO "[4/4] サービスを起動中..."
docker compose up -d
if ($LASTEXITCODE -ne 0) {
    Write-Log ERROR "docker compose up に失敗しました。"
    docker compose down 2>$null
    exit 2
}
Write-Log INFO "      Compose 起動コマンド送信完了"

# ヘルスチェックループ
Write-Log INFO ""
Write-Log INFO "AnythingLLM の起動を待機中（最大 $([math]::Round($HealthcheckRetries * $HealthcheckIntervalSec / 60)) 分）..."
for ($i = 1; $i -le $HealthcheckRetries; $i++) {
    try {
        $Response = Invoke-WebRequest -Uri "http://localhost:3001/api/ping" -UseBasicParsing -TimeoutSec 5
        if ($Response.StatusCode -eq 200) {
            Write-Log INFO ""
            Write-Log INFO "=== インストール完了 ==="
            Write-Log INFO ""
            Write-Log INFO "ブラウザで以下の URL にアクセスしてください:"
            Write-Log INFO "  http://localhost:3001"
            Write-Log INFO ""
            Write-Log INFO "動作確認:"
            Write-Log INFO "  bash smoke-test.sh (WSL2/Git Bash) または手動でAPI確認"
            Write-Log INFO ""
            Write-Log INFO "操作コマンド:"
            Write-Log INFO "  停止:   .\stop.ps1"
            Write-Log INFO "  再起動: .\start.ps1"
            Write-Log INFO "  ログ:   docker compose logs -f"
            Write-Log INFO "  削除:   .\uninstall.ps1"
            Write-Log INFO ""
            $GpuStatus = if ($GpuAvailable) { "有効" } else { "無効（CPU のみ）" }
            Write-Log INFO "GPU 状態: $GpuStatus"
            exit 0
        }
    } catch {
        # まだ起動していない。待機を継続する。
    }
    Start-Sleep -Seconds $HealthcheckIntervalSec
}

Write-Log ERROR ""
Write-Log ERROR "起動タイムアウト（$([math]::Round($HealthcheckRetries * $HealthcheckIntervalSec / 60)) 分）"
Write-Log ERROR "ログを確認してください:"
Write-Log ERROR "  docker compose logs anythingllm"
Write-Log ERROR "  docker compose logs ollama"
exit 2
