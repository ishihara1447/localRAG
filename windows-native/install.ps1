# install.ps1 - Install LocalRAG (Windows native, fully offline) from this package.
#
# Run from the extracted package root, in an elevated (Administrator) PowerShell:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -InstallRoot D:\LocalRAG -ServerPort 3001
#
# What it does:
#   preflight checks -> checksum verification -> copy files -> generate .env ->
#   prisma migrate -> register+start Windows services -> ping check.
# Data layout after install:
#   <InstallRoot>\app\server\storage   (documents, vectors, sqlite DB)
#   <InstallRoot>\app\collector\hotdir (upload staging)
#   C:\ProgramData\LocalRAG\models     (LLM/embedding models)
#   C:\ProgramData\LocalRAG\logs       (service logs)

param(
    [string]$InstallRoot = "C:\LocalRAG",
    [int]$ServerPort = 3001,
    [switch]$SkipChecksum,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$PkgRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataRoot = "C:\ProgramData\LocalRAG"

# Rollback state. Stays $false through preflight/checksum (nothing has been
# created yet), and is set to $true immediately before the first file copy.
# While $true, Fail throws instead of exiting so the body try/catch can run
# Invoke-Rollback and clean up this run's artifacts.
$script:rollbackActive = $false
$script:servicesTouched = $false
# Set in preflight when -Force is used over an existing install. When true,
# Invoke-Rollback must NOT delete InstallRoot / move storage, so a failed
# -Force run never destroys the already-working installation it overwrote.
$script:preExisting = $false
# Where Invoke-Rollback moved the customer's documents (if it had to). Shown in
# the final failure message so they know the data was preserved, not lost.
$script:storageRescuePath = $null

function Fail([string]$msg) {
    if ($script:rollbackActive) { throw $msg }
    Write-Host "ERROR: $msg"; exit 1
}
function Info([string]$msg) { Write-Host $msg }

# Stop any ollama.exe / node.exe launched by THIS install, matched by
# executable path (under InstallRoot or DataRoot) so a customer's own
# Node/Ollama elsewhere is never touched. Mirrors uninstall.ps1's
# Stop-LocalRagProcesses (the two scripts cannot share a function).
function Stop-LocalRagProcesses {
    $roots = @($InstallRoot, $DataRoot) | Where-Object { $_ }
    foreach ($procName in @("ollama", "node")) {
        Get-Process -Name $procName -ErrorAction SilentlyContinue | ForEach-Object {
            $procPath = $null
            try { $procPath = $_.Path } catch {}
            if ($procPath) {
                foreach ($root in $roots) {
                    if ($procPath.StartsWith(($root.TrimEnd('\') + '\'), [System.StringComparison]::OrdinalIgnoreCase)) {
                        try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch {}
                        break
                    }
                }
            }
        }
    }
}

# Undo everything this run created (services, InstallRoot, shortcuts, ARP key).
# Existing customer documents under app\server\storage are preserved first.
# $DataRoot\models (copied models) is intentionally kept to speed up a retry.
function Invoke-Rollback {
    Write-Host "[rollback] インストールに失敗したため、この操作で作成したファイルとサービスを片付けています..."

    # 1. Remove the three services if this run reached the registration step.
    if ($script:servicesTouched) {
        $unregister = Join-Path $InstallRoot "winsw\unregister-services.ps1"
        if (Test-Path $unregister) {
            try { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $unregister } catch {}
        } else {
            foreach ($svc in @("LocalRAG-Server", "LocalRAG-Collector", "LocalRAG-Ollama")) {
                Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
                & sc.exe delete $svc 2>$null | Out-Null
            }
        }

        # 1b. Kill any ollama.exe/node.exe this run started (they hold file
        # locks under InstallRoot) and wait for the services to actually
        # disappear. sc.exe delete only marks a service for deletion while a
        # process still holds a handle; deleting InstallRoot before the locks
        # release leaves a partial tree that trips the next install's preflight.
        Stop-LocalRagProcesses
        $deadline = (Get-Date).AddSeconds(30)
        foreach ($svc in @("LocalRAG-Server", "LocalRAG-Collector", "LocalRAG-Ollama")) {
            while ((Get-Service -Name $svc -ErrorAction SilentlyContinue) -and ((Get-Date) -lt $deadline)) {
                Start-Sleep -Milliseconds 500
            }
        }
    }

    # 2. Remove desktop shortcuts created by this run.
    try {
        $desktop = [Environment]::GetFolderPath("CommonDesktopDirectory")
        foreach ($lnkName in @("LocalRAG.lnk", "OTE-RAG アンインストール.lnk")) {
            $lnkPath = Join-Path $desktop $lnkName
            if (Test-Path $lnkPath) { Remove-Item $lnkPath -Force -ErrorAction SilentlyContinue }
        }
    } catch {}

    # 3. Remove the ARP (Programs and Features) key if it was written.
    Remove-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OTE-RAG" -Recurse -Force -ErrorAction SilentlyContinue

    # 4. Preserve existing documents, then remove InstallRoot (created by this run).
    # When -Force overwrote an already-working install ($preExisting), we must
    # NOT touch InstallRoot or move its storage: doing so would destroy the
    # customer's existing, functioning installation. Leave it in place and tell
    # them how to clean up manually if they want to.
    if ($script:preExisting) {
        Write-Host "[rollback] 既存のインストールが残っている可能性があります。必要なら『OTE-RAG アンインストール』を実行してください。"
    } elseif (Test-Path $InstallRoot) {
        $storagePath = Join-Path $InstallRoot "app\server\storage"
        if (Test-Path $storagePath) {
            try {
                if (Get-ChildItem -Path $storagePath -Force -ErrorAction SilentlyContinue) {
                    $keep = Join-Path $DataRoot "uninstalled-$(Get-Date -Format yyyyMMdd-HHmmss)"
                    New-Item -ItemType Directory -Path $keep -Force | Out-Null
                    Move-Item $storagePath (Join-Path $keep "storage") -Force
                    $script:storageRescuePath = $keep
                    Write-Host "[rollback] 既存の文書データを $keep\storage へ退避しました。"
                }
            } catch {}
        }
        Remove-Item -Recurse -Force $InstallRoot -ErrorAction SilentlyContinue
    }
}

Write-Host "=== LocalRAG Windows native installer ==="

# =====================================================================
# Preflight
# =====================================================================
Info "[preflight] Checking environment..."

# Admin
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail "管理者として実行してください(管理者権限の PowerShell から起動が必要です)。"
}

# OS version (Windows 10 21H2+ / 11)
$build = [System.Environment]::OSVersion.Version.Build
if ($build -lt 19044) { Fail "この Windows は古すぎます(ビルド $build)。Windows 11(または Windows 10 21H2 以降)が必要です。" }

# GPU via nvidia-smi
$nvidiaSmi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if (-not $nvidiaSmi) {
    $default = "$env:SystemRoot\System32\nvidia-smi.exe"
    if (Test-Path $default) { $nvidiaSmi = $default } else {
        Fail "NVIDIA GPU が見つかりません(nvidia-smi が無い)。対応する NVIDIA GPU と最新ドライバーが必要です。"
    }
} else { $nvidiaSmi = $nvidiaSmi.Source }
try {
    $vramMiB = [int]((& $nvidiaSmi --query-gpu=memory.total --format=csv,noheader,nounits | Select-Object -First 1).Trim())
} catch { Fail "GPU 情報の取得に失敗しました(nvidia-smi 実行エラー)。NVIDIA ドライバーの状態を確認してください。" }
Info "  GPU VRAM: $vramMiB MiB"
if ($vramMiB -lt 15000) {
    Write-Host "注意: GPU メモリが 16GB 未満です。OTE-RAG は RTX 5070 Ti(16GB)相当の GPU で動作確認しています。動作が不安定になる場合があります。"
    if (-not $Force) { Fail "GPU メモリが 16GB 未満です(推奨環境外)。それでも続行する場合は -Force を付けて再実行してください。" }
}

# Disk space (>= 20GB free on the InstallRoot drive)
$drive = (Split-Path -Qualifier ([System.IO.Path]::GetFullPath($InstallRoot))).TrimEnd(":")
$freeGB = [math]::Round((Get-PSDrive $drive).Free / 1GB, 1)
Info "  Free space on drive ${drive}: $freeGB GB"
if ($freeGB -lt 20) { Fail "ドライブ $drive の空き容量が不足しています。20GB 以上の空き容量が必要です。" }

# The ~9GB of models always land on C:\ProgramData\LocalRAG and the package is
# expanded to C:\OTR, so C: needs headroom even when InstallRoot is elsewhere.
# Skip when InstallRoot is already on C: (the check above already covered it).
$sysDrive = (Split-Path -Qualifier $env:SystemRoot).TrimEnd(":")
if ($drive -ne $sysDrive) {
    $sysFreeGB = [math]::Round((Get-PSDrive $sysDrive).Free / 1GB, 1)
    Info "  Free space on drive ${sysDrive}: $sysFreeGB GB"
    if ($sysFreeGB -lt 12) { Fail "システムドライブ $sysDrive の空き容量が不足しています。モデルと作業ファイル用に 12GB 以上の空き容量が必要です。" }
}

# Ports (server / collector / dedicated ollama)
foreach ($port in @($ServerPort, 8888, 11435)) {
    $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    if ($conn) {
        $owner = "unknown"
        try { $owner = (Get-Process -Id $conn[0].OwningProcess -ErrorAction SilentlyContinue).ProcessName } catch {}
        if ($owner -eq "wslrelay") {
            Fail "ポート $port が WSL2 の転送サービス(wslrelay.exe)に使われています。WSL 側のサービスを止める(例: 'wsl --shutdown')か、-ServerPort で別のポートを指定してください。"
        }
        Fail "ポート $port は既に別のプログラム('$owner')が使用中です。そのプログラムを止めるか、-ServerPort で別のポートを指定してください。"
    }
}
Info "  Ports $ServerPort/8888/11435: free"

# Existing installation
if (Test-Path (Join-Path $InstallRoot "app")) {
    if (-not $Force) {
        Fail "$InstallRoot\app が既に存在します。先にアンインストール(デスクトップの「OTE-RAG アンインストール」または uninstall.ps1)を実行してください。上書きする場合は -Force を付けて再実行します(app\server\storage 内のデータは backup.ps1 でのみ保護されます。先にバックアップしてください)。"
    }
    # -Force over an existing install: if this run fails, Invoke-Rollback must
    # not delete/relocate the existing installation we are overwriting.
    $script:preExisting = $true
}
$existingSvc = Get-Service -Name "LocalRAG-*" -ErrorAction SilentlyContinue
if ($existingSvc -and -not $Force) {
    Fail "OTE-RAG のサービスが既に登録されています。先にアンインストールを実行してください。"
}

# =====================================================================
# Checksum verification
# =====================================================================
if (-not $SkipChecksum) {
    $checksumFile = Join-Path $PkgRoot "checksums\package.sha256"
    if (-not (Test-Path $checksumFile)) { Fail "checksums\package.sha256 が見つかりません。配布パッケージが不完全です(-SkipChecksum は開発用途のみ)。" }
    Info "[checksum] Verifying package integrity (this can take a while)..."
    $bad = 0; $count = 0
    foreach ($line in Get-Content $checksumFile) {
        if ($line -notmatch "^([0-9a-f]{64})\s+(.+)$") { continue }
        $expected = $Matches[1]; $rel = $Matches[2] -replace "/", "\"
        $path = Join-Path $PkgRoot $rel
        if (-not (Test-Path $path)) { Write-Host "  MISSING: $rel"; $bad++; continue }
        $actual = (Get-FileHash -Algorithm SHA256 -Path $path).Hash.ToLower()
        if ($actual -ne $expected) { Write-Host "  MISMATCH: $rel"; $bad++ }
        $count++
    }
    if ($bad -gt 0) { Fail "$bad 個のファイルが整合性チェックに失敗しました。配布パッケージが破損しています。ダウンロード/コピーし直してください。" }
    Info "  $count files verified."
}

# =====================================================================
# Installation body (transactional: any failure below triggers Invoke-Rollback)
# From here on we start creating artifacts, so arm rollback and wrap the rest.
# =====================================================================
$script:rollbackActive = $true
try {

# =====================================================================
# Copy files
# =====================================================================
Info "[install] Copying application files to $InstallRoot ..."
foreach ($d in @("app", "runtime", "winsw")) {
    robocopy (Join-Path $PkgRoot $d) (Join-Path $InstallRoot $d) /E /NFL /NDL /NJH /NJS | Out-Null
    if ($LASTEXITCODE -ge 8) { Fail "ファイルのコピーに失敗しました($d, robocopy 終了コード $LASTEXITCODE)。" }
}
Copy-Item (Join-Path $PkgRoot "rag-e2e-test.ps1") $InstallRoot -Force
if (Test-Path (Join-Path $PkgRoot "fixtures")) {
    robocopy (Join-Path $PkgRoot "fixtures") (Join-Path $InstallRoot "fixtures") /E /NFL /NDL /NJH /NJS | Out-Null
}
foreach ($f in @("uninstall.ps1", "Uninstall-OTE-RAG.cmd", "start.ps1", "stop.ps1", "backup.ps1", "restore.ps1")) {
    Copy-Item (Join-Path $PkgRoot $f) $InstallRoot -Force
}
if (Test-Path (Join-Path $PkgRoot "LICENSES")) {
    robocopy (Join-Path $PkgRoot "LICENSES") (Join-Path $InstallRoot "LICENSES") /E /NFL /NDL /NJH /NJS | Out-Null
}
if (Test-Path (Join-Path $PkgRoot "NOTICE")) { Copy-Item (Join-Path $PkgRoot "NOTICE") $InstallRoot -Force }
if (Test-Path (Join-Path $PkgRoot "docs")) {
    robocopy (Join-Path $PkgRoot "docs") (Join-Path $InstallRoot "docs") /E /NFL /NDL /NJH /NJS | Out-Null
}
if (Test-Path (Join-Path $PkgRoot "versions.lock")) { Copy-Item (Join-Path $PkgRoot "versions.lock") $InstallRoot -Force }
$global:LASTEXITCODE = 0

Info "[install] Copying models to $DataRoot\models ..."
New-Item -ItemType Directory -Path "$DataRoot\models" -Force | Out-Null
New-Item -ItemType Directory -Path "$DataRoot\logs" -Force | Out-Null
robocopy (Join-Path $PkgRoot "models") "$DataRoot\models" /E /NFL /NDL /NJH /NJS | Out-Null
if ($LASTEXITCODE -ge 8) { Fail "モデルファイルのコピーに失敗しました(robocopy models)。" }
$global:LASTEXITCODE = 0

# Runtime data dirs
New-Item -ItemType Directory -Path (Join-Path $InstallRoot "app\server\storage") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $InstallRoot "app\collector\hotdir") -Force | Out-Null

# =====================================================================
# Generate .env files from templates
# =====================================================================
Info "[install] Generating .env files..."
function Render-Template([string]$templatePath, [string]$outPath) {
    $content = Get-Content $templatePath -Raw
    $content = $content -replace "\{\{INSTALL_ROOT\}\}", $InstallRoot
    $content = $content -replace "\{\{SERVER_PORT\}\}", "$ServerPort"
    # UTF-8 without BOM: keeps non-ASCII / Japanese InstallRoot paths intact and
    # avoids a BOM that Node/dotenv can mis-parse.
    [System.IO.File]::WriteAllText($outPath, $content, (New-Object System.Text.UTF8Encoding($false)))
}
Render-Template (Join-Path $PkgRoot "config\server.env.template") (Join-Path $InstallRoot "app\server\.env")
Render-Template (Join-Path $PkgRoot "config\server.env.template") (Join-Path $InstallRoot "app\server\.env.production")
Render-Template (Join-Path $PkgRoot "config\collector.env.template") (Join-Path $InstallRoot "app\collector\.env")

# =====================================================================
# Desktop launcher + shortcut
# =====================================================================
$launcherSrc = Join-Path $PkgRoot "launcher\LocalRAG.html"
if (Test-Path $launcherSrc) {
    Info "[install] Installing desktop launcher + shortcut..."
    # The launcher page contains Japanese text: render with UTF-8 (not ascii).
    $launcherHtml = Get-Content $launcherSrc -Raw -Encoding UTF8
    $launcherHtml = $launcherHtml -replace "\{\{SERVER_PORT\}\}", "$ServerPort"
    Set-Content -Path (Join-Path $InstallRoot "LocalRAG.html") -Value $launcherHtml -Encoding UTF8
    Copy-Item (Join-Path $PkgRoot "launcher\LocalRAG.ico") (Join-Path $InstallRoot "LocalRAG.ico") -Force

    # All-users desktop shortcut. Opens the launcher page, which checks the
    # server and forwards to the app (or shows guidance when it is down).
    try {
        $desktop = [Environment]::GetFolderPath("CommonDesktopDirectory")
        $shell = New-Object -ComObject WScript.Shell
        $lnk = $shell.CreateShortcut((Join-Path $desktop "LocalRAG.lnk"))
        $lnk.TargetPath = Join-Path $InstallRoot "LocalRAG.html"
        $lnk.IconLocation = (Join-Path $InstallRoot "LocalRAG.ico") + ",0"
        $lnk.Description = "OTE-RAG"
        $lnk.WorkingDirectory = $InstallRoot
        $lnk.Save()
        Info "  Shortcut: $(Join-Path $desktop 'LocalRAG.lnk')"
    } catch {
        Write-Host "注意: デスクトップのショートカット作成に失敗しました。$InstallRoot\LocalRAG.html を直接開いてご利用ください。(詳細: $($_.Exception.Message))"
    }

    # All-users desktop shortcut for the double-click uninstaller.
    # Points at Uninstall-OTE-RAG.cmd which self-elevates (UAC) and runs uninstall.ps1.
    try {
        $desktop = [Environment]::GetFolderPath("CommonDesktopDirectory")
        $shell = New-Object -ComObject WScript.Shell
        $ulnk = $shell.CreateShortcut((Join-Path $desktop "OTE-RAG アンインストール.lnk"))
        $ulnk.TargetPath = Join-Path $InstallRoot "Uninstall-OTE-RAG.cmd"
        $ulnk.IconLocation = (Join-Path $InstallRoot "LocalRAG.ico") + ",0"
        $ulnk.Description = "OTE-RAG をアンインストールします"
        $ulnk.WorkingDirectory = $InstallRoot
        $ulnk.Save()
        Info "  Uninstall shortcut: $(Join-Path $desktop 'OTE-RAG アンインストール.lnk')"
    } catch {
        Write-Host "注意: アンインストール用ショートカットの作成に失敗しました。削除するときは $InstallRoot\Uninstall-OTE-RAG.cmd を直接実行してください。(詳細: $($_.Exception.Message))"
    }
}

# =====================================================================
# Prisma migrate (creates the SQLite DB)
# =====================================================================
Info "[install] Running prisma migrate deploy..."
$node = Join-Path $InstallRoot "runtime\node\node.exe"
$serverDir = Join-Path $InstallRoot "app\server"
$prismaCli = Join-Path $serverDir "node_modules\prisma\build\index.js"
if (-not (Test-Path $prismaCli)) { Fail "データベース初期化ツールが見つかりません($prismaCli)。" }
Push-Location $serverDir
try {
    & $node $prismaCli migrate deploy --schema=.\prisma\schema.prisma
    if ($LASTEXITCODE -ne 0) { Fail "データベースの初期化に失敗しました(prisma migrate deploy, 終了コード $LASTEXITCODE)。" }
} finally { Pop-Location }

# =====================================================================
# Register + start services
# =====================================================================
Info "[install] Registering Windows services..."
$script:servicesTouched = $true
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $InstallRoot "winsw\register-services.ps1")
if ($LASTEXITCODE -ne 0) { Fail "Windows サービスの登録・起動に失敗しました。" }

# =====================================================================
# Register in Programs and Features (ARP). Installer runs elevated, so HKLM
# is writable. A failure here does NOT trigger rollback (the product is already
# installed); we only warn so the desktop uninstall shortcut can still be used.
# =====================================================================
$displayVersion = "1.2.2"
$versionsLock = Join-Path $InstallRoot "versions.lock"
if (Test-Path $versionsLock) {
    $vLine = Get-Content $versionsLock | Where-Object { $_ -match "^package_version=" } | Select-Object -First 1
    if ($vLine) { $displayVersion = ($vLine -replace "^package_version=", "").Trim() }
}
try {
    $arpKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OTE-RAG"
    New-Item -Path $arpKey -Force | Out-Null
    New-ItemProperty -Path $arpKey -Name "DisplayName" -Value "OTE-RAG" -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $arpKey -Name "DisplayVersion" -Value $displayVersion -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $arpKey -Name "Publisher" -Value "OTE-RAG" -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $arpKey -Name "InstallLocation" -Value $InstallRoot -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $arpKey -Name "DisplayIcon" -Value (Join-Path $InstallRoot "LocalRAG.ico") -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $arpKey -Name "UninstallString" -Value ('"' + (Join-Path $InstallRoot "Uninstall-OTE-RAG.cmd") + '"') -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $arpKey -Name "QuietUninstallString" -Value ('powershell -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $InstallRoot "uninstall.ps1") + '"') -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $arpKey -Name "NoModify" -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $arpKey -Name "NoRepair" -Value 1 -PropertyType DWord -Force | Out-Null
    try {
        $sizeBytes = (Get-ChildItem -Path $InstallRoot -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        # Include the ~9GB of models under $DataRoot\models so Programs and
        # Features reports the real on-disk footprint, not just InstallRoot.
        $modelsPath = Join-Path $DataRoot "models"
        if (Test-Path $modelsPath) {
            $sizeBytes += (Get-ChildItem -Path $modelsPath -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        }
        $sizeKB = [int]($sizeBytes / 1KB)
        if ($sizeKB -gt 0) { New-ItemProperty -Path $arpKey -Name "EstimatedSize" -Value $sizeKB -PropertyType DWord -Force | Out-Null }
    } catch {}
    Info "  Registered in Programs and Features (OTE-RAG, v$displayVersion)."
} catch {
    Write-Host "注意: 「プログラムと機能」への登録に失敗しました。アンインストールするときはデスクトップの「OTE-RAG アンインストール」をお使いください。(詳細: $($_.Exception.Message))"
}

# =====================================================================
# Ping check
# =====================================================================
Info "[install] Waiting for the server to come online (max 120s)..."
$ok = $false
for ($i = 0; $i -lt 24; $i++) {
    Start-Sleep -Seconds 5
    try {
        $ping = & curl.exe -s --max-time 5 "http://localhost:$ServerPort/api/ping"
        if ($ping -match '"online"\s*:\s*true') { $ok = $true; break }
    } catch {}
}
if (-not $ok) {
    # The product IS installed (services registered, ARP written). The server
    # just did not answer within 120s, usually because the first model load
    # takes a few minutes. This is NOT a failure: exit 3 and do NOT roll back.
    Write-Host "インストールは完了しました。サービスの起動確認がタイムアウトしました(初回はモデル読み込みに数分かかることがあります)。数分後にデスクトップのアイコンから開いてください。"
    Write-Host "      (詳細: http://localhost:$ServerPort/api/ping が120秒以内に応答しませんでした。ログ: $DataRoot\logs)"
    exit 3
}

Write-Host ""
Write-Host "=== Install complete ==="
Write-Host "UI:            http://localhost:$ServerPort"
Write-Host "Services:      LocalRAG-Server / LocalRAG-Collector / LocalRAG-Ollama (automatic start)"
Write-Host "Data:          $InstallRoot\app\server\storage"
Write-Host "Logs:          $DataRoot\logs"
Write-Host "E2E test:      set LOCALRAG_API_KEY and run rag-e2e-test.ps1 (see docs)"

}
catch {
    # Any failure in the installation body: undo this run's artifacts so the
    # customer can simply run the installer again from a clean state.
    Invoke-Rollback
    Write-Host "ERROR: インストールに失敗しました($($_.Exception.Message))。環境を元に戻しました。もう一度インストールを実行できます。"
    if ($script:storageRescuePath) {
        Write-Host "お客様の文書データは $script:storageRescuePath\storage に保管しました(消えていません)。"
    }
    exit 1
}
