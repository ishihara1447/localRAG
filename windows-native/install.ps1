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
    # 🔴 -Force で既存インストールを上書きしていた場合($preExisting)は、ここで
    # サービスを消してはならない。サービス名は共通なので、消すと**元から動いていた
    # インストールのサービスまで消える**。ステップ4はファイル削除を回避しているのに
    # ここだけ回避しておらず、その状態で「環境を元に戻しました」と表示していた。
    # 実際には動いていた製品が起動不能になる。
    if ($script:servicesTouched -and -not $script:preExisting) {
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

    # 2. Remove the desktop shortcut created by this run.
    # (アンインストーラはデスクトップにショートカットを作らないため、対象は起動用の1つだけ。)
    try {
        $desktop = [Environment]::GetFolderPath("CommonDesktopDirectory")
        $lnkPath = Join-Path $desktop "LocalRAG.lnk"
        if (Test-Path $lnkPath) { Remove-Item $lnkPath -Force -ErrorAction SilentlyContinue }
    } catch {}

    # 3. Remove the ARP (Programs and Features) key if it was written.
    Remove-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OTE-RAG" -Recurse -Force -ErrorAction SilentlyContinue

    # 4. Preserve existing documents, then remove InstallRoot (created by this run).
    # When -Force overwrote an already-working install ($preExisting), we must
    # NOT touch InstallRoot or move its storage: doing so would destroy the
    # customer's existing, functioning installation. Leave it in place and tell
    # them how to clean up manually if they want to.
    if ($script:preExisting) {
        Write-Host "[rollback] 既存のインストールが残っている可能性があります。必要なら『設定 → アプリ』の「OTE-RAG」から、または $InstallRoot\Uninstall-OTE-RAG.cmd を実行してアンインストールしてください。"
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
        # 🔴 Only delete InstallRoot when this run created it. If the customer
        # chose a folder that already existed (e.g. a documents folder), it may
        # hold files that are not ours, and the storage rescue above does not
        # cover them. Deleting it would destroy their data. In that case remove
        # only the items we wrote and leave everything else alone.
        if ($script:createdInstallRoot) {
            Remove-Item -Recurse -Force $InstallRoot -ErrorAction SilentlyContinue
        } else {
            # 実際に導入先へ作られる項目に合わせること。増減したらここも直す。
            foreach ($item in @("app", "runtime", "winsw", "docs", "fixtures", "LICENSES",
                                "LocalRAG.html", "LocalRAG.ico", "NOTICE", "versions.lock",
                                "Uninstall-OTE-RAG.cmd", "backup.ps1", "restore.ps1",
                                "start.ps1", "stop.ps1", "uninstall.ps1",
                                "rag-e2e-test.ps1")) {
                Remove-Item -Recurse -Force (Join-Path $InstallRoot $item) -ErrorAction SilentlyContinue
            }
            Write-Host "[rollback] $InstallRoot は既存のフォルダーだったため、本インストーラーが作成した項目のみ削除しました。"
        }
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
# 2026-08-04: VRAM 8GB 機を対象に加えたため閾値を見直した。
# 同梱 LLM を gemma4:12b(ctx8192 で実測 8.4GB) から granite4.1:8b(同 6.7GB) へ
# 差し替え、bge-m3(0.6GB) と合わせて 7.3GB。8GB カードの実効容量は
# デスクトップ描画を引いて 7.5〜7.8GiB 程度と見込まれ、**余裕はほとんど無い**。
# したがって 8GB は「動く見込みだが実機未検証」という位置づけであり、
# 停止させずに警告する。7GB 未満は明確に足りないので従来どおり停止する。
$vramWarnMiB = 9000   # これ未満なら警告（8GB カードは 8188 前後を報告する）
$vramFailMiB = 7000   # これ未満なら停止
if ($vramMiB -lt $vramFailMiB) {
    Fail "GPU メモリが不足しています($vramMiB MiB)。8GB 以上が必要です。"
}
if ($vramMiB -lt $vramWarnMiB) {
    Write-Host ""
    Write-Host "注意: GPU メモリが $vramMiB MiB です(8GB 相当)。"
    Write-Host "  同梱 LLM(granite4.1:8b)と埋め込みで約 7.3GB を使います。"
    Write-Host "  **8GB 実機での動作確認は未実施です。** 他のアプリが GPU を使っていると"
    Write-Host "  メモリが足りず、CPU 動作に転落して回答が非常に遅くなることがあります。"
    Write-Host "  その場合はブラウザなど GPU を使うアプリを閉じてからお試しください。"
    Write-Host ""
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
        if ($port -eq $ServerPort) {
            Fail "ポート $port は既に別のプログラム('$owner')が使用中です。そのプログラムを止めるか、-ServerPort で別のポートを指定してください。"
        } else {
            Fail "ポート $port は既に別のプログラム('$owner')が使用中です。このポートは製品内部で固定されており変更できません(8888=文書取り込み, 11435=モデル実行)。そのプログラムを停止してから再実行してください。"
        }
    }
}
Info "  Ports $ServerPort/8888/11435: free"

# Existing installation
if (Test-Path (Join-Path $InstallRoot "app")) {
    if (-not $Force) {
        Fail "$InstallRoot\app が既に存在します。先にアンインストール(『設定 → アプリ』の「OTE-RAG」、または $InstallRoot\Uninstall-OTE-RAG.cmd)を実行してください。上書きする場合は -Force を付けて再実行します(app\server\storage 内のデータは backup.ps1 でのみ保護されます。先にバックアップしてください)。"
    }
    # -Force over an existing install: if this run fails, Invoke-Rollback must
    # not delete/relocate the existing installation we are overwriting.
    $script:preExisting = $true
} elseif (Test-Path $InstallRoot) {
    # An existing folder that is not one of our installations. We install into it
    # rather than refuse, but the customer should know their files are now mixed
    # in with the product (and that uninstall works on our own items only).
    if (Get-ChildItem -Path $InstallRoot -Force -ErrorAction SilentlyContinue) {
        Write-Host "[warn] $InstallRoot は既にファイルがあるフォルダーです。この中へインストールします。"
        Write-Host "       製品専用の空フォルダー(既定: C:\LocalRAG)を指定することを推奨します。"
    }
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
    if ($count -eq 0) { Fail "checksums\package.sha256 から1件も読み取れませんでした。配布パッケージが壊れているか、生成側の不具合です(この状態では整合性を確認できません)。" }
    if ($bad -gt 0) { Fail "$bad 個のファイルが整合性チェックに失敗しました。配布パッケージが破損しています。ダウンロード/コピーし直してください。" }
    Info "  $count files verified."
}

# =====================================================================
# Installation body (transactional: any failure below triggers Invoke-Rollback)
# From here on we start creating artifacts, so arm rollback and wrap the rest.
# =====================================================================
# Whether InstallRoot itself is ours to delete on rollback. If the customer
# pointed the installer at a folder that already had other files in it, deleting
# the folder would destroy their data -- see Invoke-Rollback step 4.
$script:createdInstallRoot = -not (Test-Path $InstallRoot)
$script:rollbackActive = $true
try {

# =====================================================================
# Copy files
# =====================================================================
Info "[install] Copying application files to $InstallRoot ..."
foreach ($d in @("app", "runtime", "winsw")) {
    robocopy (Join-Path $PkgRoot $d) (Join-Path $InstallRoot $d) /E /R:2 /W:5 /NFL /NDL /NJH /NJS | Out-Null
    if ($LASTEXITCODE -ge 8) { Fail "ファイルのコピーに失敗しました($d, robocopy 終了コード $LASTEXITCODE)。" }
}
Copy-Item (Join-Path $PkgRoot "rag-e2e-test.ps1") $InstallRoot -Force
if (Test-Path (Join-Path $PkgRoot "fixtures")) {
    robocopy (Join-Path $PkgRoot "fixtures") (Join-Path $InstallRoot "fixtures") /E /R:2 /W:5 /NFL /NDL /NJH /NJS | Out-Null
}
foreach ($f in @("uninstall.ps1", "Uninstall-OTE-RAG.cmd", "start.ps1", "stop.ps1", "backup.ps1", "restore.ps1")) {
    Copy-Item (Join-Path $PkgRoot $f) $InstallRoot -Force
}
if (Test-Path (Join-Path $PkgRoot "LICENSES")) {
    robocopy (Join-Path $PkgRoot "LICENSES") (Join-Path $InstallRoot "LICENSES") /E /R:2 /W:5 /NFL /NDL /NJH /NJS | Out-Null
}
if (Test-Path (Join-Path $PkgRoot "NOTICE")) { Copy-Item (Join-Path $PkgRoot "NOTICE") $InstallRoot -Force }
if (Test-Path (Join-Path $PkgRoot "docs")) {
    robocopy (Join-Path $PkgRoot "docs") (Join-Path $InstallRoot "docs") /E /R:2 /W:5 /NFL /NDL /NJH /NJS | Out-Null
}
if (Test-Path (Join-Path $PkgRoot "versions.lock")) { Copy-Item (Join-Path $PkgRoot "versions.lock") $InstallRoot -Force }
$global:LASTEXITCODE = 0

Info "[install] Copying models to $DataRoot\models ..."
New-Item -ItemType Directory -Path "$DataRoot\models" -Force | Out-Null
New-Item -ItemType Directory -Path "$DataRoot\logs" -Force | Out-Null
robocopy (Join-Path $PkgRoot "models") "$DataRoot\models" /E /R:2 /W:5 /NFL /NDL /NJH /NJS | Out-Null
if ($LASTEXITCODE -ge 8) { Fail "モデルファイルのコピーに失敗しました(robocopy models)。" }
$global:LASTEXITCODE = 0

# ---------------------------------------------------------------------
# 旧バージョンのモデルを片付ける
#
# モデルは /E（追加のみ）でコピーしており、削除する処理がどこにも無かった。
# そのため差し替えた旧モデルが残り続ける。実測(2026-08-06)では
# 必要 約6GB に対して 14GB を占有し、8GB が死蔵していた。
# 数回のアップグレードで C: が枯渇し、次の導入が空き容量不足で止まる。
#
# 方針: **過去に本製品が同梱していたモデルの manifest だけ**を対象にする。
# 顧客が自分で入れたモデルには触れない（消してしまうと再取得できないため)。
# manifest を消したうえで、どの manifest からも参照されなくなった blob を消す。
# ---------------------------------------------------------------------
$modelsRoot = Join-Path $DataRoot "models"
$libDir = Join-Path $modelsRoot "manifests\registry.ollama.ai\library"
$pkgLibDir = Join-Path $PkgRoot "models\manifests\registry.ollama.ai\library"
# 本製品がこれまで同梱してきたモデル名。**増やすことはあっても減らさないこと。**
# ここに無い名前は顧客が自分で入れたものとみなして残す。
$everBundled = @("qwen3", "gemma4", "bge-m3", "mxbai-embed-large",
                 "granite4.1", "granite-embedding", "llm-jp-3")
if ((Test-Path $libDir) -and (Test-Path $pkgLibDir)) {
    $shipped = @(Get-ChildItem -Path $pkgLibDir -Directory -ErrorAction SilentlyContinue |
                 ForEach-Object { $_.Name })
    $stale = @(Get-ChildItem -Path $libDir -Directory -ErrorAction SilentlyContinue |
               Where-Object { $shipped -notcontains $_.Name -and $everBundled -contains $_.Name })
    foreach ($m in $stale) {
        Info "[install] 旧バージョンのモデル $($m.Name) を削除します..."
        Remove-Item -Recurse -Force $m.FullName -ErrorAction SilentlyContinue
    }
    $kept = @(Get-ChildItem -Path $libDir -Directory -ErrorAction SilentlyContinue |
              Where-Object { $shipped -notcontains $_.Name })
    foreach ($m in $kept) {
        Write-Host "  残置: $($m.Name)（本製品の同梱モデルではないため触れません）"
    }

    # 残った manifest が参照している blob を集め、それ以外を消す。
    # manifest は JSON で、config.digest と layers[].digest を持つ。
    $referenced = New-Object System.Collections.Generic.HashSet[string]
    foreach ($f in (Get-ChildItem -Path (Join-Path $modelsRoot "manifests") -Recurse -File -ErrorAction SilentlyContinue)) {
        try {
            $j = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.config.digest) { [void]$referenced.Add(($j.config.digest -replace ":", "-")) }
            foreach ($l in $j.layers) { if ($l.digest) { [void]$referenced.Add(($l.digest -replace ":", "-")) } }
        } catch {
            # 読めない manifest があるときは、参照が拾えず blob を消しすぎる恐れがある。
            # 安全側に倒して掃除そのものを中止する。
            Write-Host "  WARN: $($f.Name) を読めませんでした。安全のためモデルの整理を中止します。"
            $referenced = $null
            break
        }
    }
    if ($referenced -ne $null -and $referenced.Count -gt 0) {
        $blobDir = Join-Path $modelsRoot "blobs"
        $freed = 0; $removed = 0
        foreach ($b in (Get-ChildItem -Path $blobDir -File -ErrorAction SilentlyContinue)) {
            if (-not $referenced.Contains($b.Name)) {
                $freed += $b.Length; $removed++
                Remove-Item -Force $b.FullName -ErrorAction SilentlyContinue
            }
        }
        if ($removed -gt 0) {
            Info ("[install] 参照されなくなったモデルデータ {0} 個 ({1:N1} GB) を削除しました。" -f $removed, ($freed / 1GB))
        }
    }
}

# Runtime data dirs
$storageDir = Join-Path $InstallRoot "app\server\storage"
New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $InstallRoot "app\collector\hotdir") -Force | Out-Null

# アップグレードで直前のアンインストールが退避した文書データを引き継ぐ。
# これが無いと、更新のたびにワークスペース・取り込み済み文書・ベクトル・チャット履歴が
# すべて空になる(退避先に残ってはいるが、戻す手段が無かった)。
# 引き継ぐのは storage が空のときだけ。既存データがあれば触らない。
$pendingMarker = Join-Path $DataRoot "pending-restore.txt"
if (Test-Path $pendingMarker) {
    $pendingPath = (Get-Content $pendingMarker -Raw -Encoding UTF8).Trim()
    Remove-Item $pendingMarker -Force -ErrorAction SilentlyContinue
    $storageEmpty = -not (Get-ChildItem -Path $storageDir -Force -ErrorAction SilentlyContinue)
    if ($pendingPath -and (Test-Path $pendingPath) -and $storageEmpty) {
        Info "[install] 直前のバージョンの文書データを引き継ぎます..."
        robocopy $pendingPath $storageDir /E /R:2 /W:5 /NFL /NDL /NJH /NJS | Out-Null
        if ($LASTEXITCODE -ge 8) {
            $global:LASTEXITCODE = 0
            Write-Host "  WARN: 文書データを引き継げませんでした。データは $pendingPath に残っています。"
            Write-Host "        インストール後に restore.ps1 か手動コピーで戻してください。"
        } else {
            $global:LASTEXITCODE = 0
            Info "  引き継ぎました($pendingPath)。元データは削除せず残してあります。"
        }
    }
}

# =====================================================================
# Generate .env files from templates
# =====================================================================
Info "[install] Generating .env files..."
function Render-Template([string]$templatePath, [string]$outPath) {
    # 🔴 Read as UTF-8 explicitly. Get-Content without -Encoding uses the system
    # ANSI codepage on Windows PowerShell 5.1 (CP932 on Japanese Windows). The
    # templates are BOM-less UTF-8 with Japanese comments, and a comment ending
    # in "。" (E3 80 82) makes the decoder treat 82 as a CP932 lead byte, which
    # swallows the following LF. The next line then becomes part of the comment
    # and the setting is silently disabled. v1.2.9 shipped with 11 of 31 settings
    # lost this way -- including EMBEDDING_MODEL_PREF, so RAG could not work at
    # all. Never drop this -Encoding.
    $content = Get-Content $templatePath -Raw -Encoding UTF8
    $content = $content -replace "\{\{INSTALL_ROOT\}\}", $InstallRoot
    $content = $content -replace "\{\{SERVER_PORT\}\}", "$ServerPort"
    # UTF-8 without BOM: keeps non-ASCII / Japanese InstallRoot paths intact and
    # avoids a BOM that Node/dotenv can mis-parse.
    [System.IO.File]::WriteAllText($outPath, $content, (New-Object System.Text.UTF8Encoding($false)))

    # Encoding bugs here are silent: the product installs, starts, and only fails
    # once the customer asks a question. Compare the keys we meant to write with
    # the keys that actually survived, and stop the install on any loss.
    $want = @(); foreach ($l in ([IO.File]::ReadAllLines($templatePath, [Text.Encoding]::UTF8))) {
        if ($l -match '^([A-Z_][A-Z0-9_]*)=') { $want += $Matches[1] }
    }
    $got = @(); foreach ($l in ([IO.File]::ReadAllLines($outPath, [Text.Encoding]::UTF8))) {
        if ($l -match '^([A-Z_][A-Z0-9_]*)=') { $got += $Matches[1] }
    }
    $lost = $want | Where-Object { $got -notcontains $_ }
    if ($lost) {
        Fail ("$(Split-Path -Leaf $outPath) の生成で設定 $($lost.Count) 件が失われました: " +
              ($lost -join ", ") + " — テンプレートの読み込み時に文字化けが起きています。" +
              "インストールを中止しました(この状態では検索・回答が動作しません)。")
    }
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

    # アンインストーラ(Uninstall-OTE-RAG.cmd)はデスクトップにショートカットを置かない。
    # インストール先フォルダ($InstallRoot\Uninstall-OTE-RAG.cmd、上でコピー済み)から直接実行するか、
    # 「設定→アプリ」/「プログラムと機能」(ARP登録、後述)から起動する。
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
$displayVersion = "1.2.7"
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
    Write-Host "注意: 「プログラムと機能」への登録に失敗しました。アンインストールするときは $InstallRoot\Uninstall-OTE-RAG.cmd を直接実行してください。(詳細: $($_.Exception.Message))"
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
Write-Host ""
Write-Host "アンインストール方法(いつでも削除できます):"
Write-Host "  ・Windows の「設定 → アプリ → インストールされているアプリ」で「OTE-RAG」を選んでアンインストール"
Write-Host "    (「プログラムと機能」(コントロールパネル)からも同様に削除できます)"
Write-Host "  ・または $InstallRoot\Uninstall-OTE-RAG.cmd を直接ダブルクリックしても削除できます。"

}
catch {
    # Any failure in the installation body: undo this run's artifacts so the
    # customer can simply run the installer again from a clean state.
    Invoke-Rollback
    # 🔴 「元に戻した」と言えるのは、この操作で作った物だけを消した場合に限る。
    # -Force で既存インストールを上書きしていた場合、ファイルは既に上書き済みで
    # 復元していない。事実と違うことを伝えると、顧客は動くはずだと思って放置してしまう。
    if ($script:preExisting) {
        Write-Host "ERROR: インストールに失敗しました($($_.Exception.Message))。"
        Write-Host "       既存のインストールを上書きする途中で失敗したため、**元の状態には戻っていません**。"
        Write-Host "       $InstallRoot をアンインストールしてから、インストールをやり直してください。"
    } else {
        Write-Host "ERROR: インストールに失敗しました($($_.Exception.Message))。環境を元に戻しました。もう一度インストールを実行できます。"
    }
    if ($script:storageRescuePath) {
        Write-Host "お客様の文書データは $script:storageRescuePath\storage に保管しました(消えていません)。"
    }
    exit 1
}
