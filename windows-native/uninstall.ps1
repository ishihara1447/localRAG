# uninstall.ps1 - Remove LocalRAG from this machine.
#
# Default: removes services and application files, KEEPS data
# (app\server\storage is moved to C:\ProgramData\LocalRAG\uninstalled-<date>\storage).
# -RemoveData: removes everything including storage, models and logs.
#
# Usage (elevated PowerShell, from the install root):
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1 -RemoveData

param(
    [switch]$RemoveData
)

$ErrorActionPreference = "Stop"
$SelfPath = $MyInvocation.MyCommand.Path
$InstallRoot = Split-Path -Parent $SelfPath
$DataRoot = "C:\ProgramData\LocalRAG"

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: run this script from an elevated (Administrator) PowerShell."
    exit 1
}

$Services = @("LocalRAG-Server", "LocalRAG-Collector", "LocalRAG-Ollama")

# Stop any ollama.exe / node.exe that belong to THIS install, matched by
# executable path so a customer's own Node/Ollama elsewhere is never touched.
function Stop-LocalRagProcesses {
    $roots = @($InstallRoot, $DataRoot) | Where-Object { $_ }
    foreach ($procName in @("ollama", "node")) {
        Get-Process -Name $procName -ErrorAction SilentlyContinue | ForEach-Object {
            $procPath = $null
            try { $procPath = $_.Path } catch {}
            if ($procPath) {
                foreach ($root in $roots) {
                    if ($procPath.StartsWith(($root.TrimEnd('\') + '\'), [System.StringComparison]::OrdinalIgnoreCase)) {
                        Write-Host "Stopping process $($_.ProcessName) (PID $($_.Id)) from $procPath ..."
                        try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch {}
                        break
                    }
                }
            }
        }
    }
}

# 1. Unregister services
$unregister = Join-Path $InstallRoot "winsw\unregister-services.ps1"
if (Test-Path $unregister) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $unregister
} else {
    Write-Host "WARN: $unregister not found. Removing services via sc.exe."
    foreach ($svc in $Services) {
        Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        & sc.exe delete $svc 2>$null | Out-Null
    }
}

# 1b. Kill any leftover ollama.exe/node.exe (releases file locks so InstallRoot
# can actually be deleted below), then wait for the services to disappear.
# sc.exe delete only marks a service for deletion while handles remain open.
Stop-LocalRagProcesses

$deadline = (Get-Date).AddSeconds(30)
foreach ($svc in $Services) {
    while ((Get-Service -Name $svc -ErrorAction SilentlyContinue) -and ((Get-Date) -lt $deadline)) {
        Start-Sleep -Milliseconds 500
    }
}
# 🔴 サービスが「削除保留」で残ると、この後の再インストールが必ず失敗する
# （install.ps1 の preflight が「先にアンインストールしてください」で止まる）。
# いまアンインストールしたばかりなのに、である。従来は WARN を出すだけで
# 終了コード 0 を返していたため、Setup.exe は成功と見なして再インストールへ進み、
# 顧客は同じ所で失敗し続けるループに入っていた。
# 発火条件は日常的で、services.msc やタスクマネージャでこのサービスを開いていると
# SCM がハンドルを掴んだまま削除保留にする。
# 専用の終了コード 4 を返し、呼び出し側が「再起動が必要」と案内できるようにする。
$residual = Get-Service -Name "LocalRAG-*" -ErrorAction SilentlyContinue
$servicesPendingDelete = $false
if ($residual) {
    $servicesPendingDelete = $true
    Write-Host ""
    Write-Host "[!] サービス $($residual.Name -join ', ') が削除待ちのまま残っています。"
    Write-Host "    Windows がサービスの削除を完了できていません。"
    Write-Host "    サービス画面(services.msc)やタスクマネージャを開いている場合は閉じてください。"
    Write-Host "    **PC を再起動すると削除が完了します。** 再起動後にインストールをやり直してください。"
    Write-Host ""
}

# The steps below are wrapped in individual try/catch so that one locked file
# (e.g. storage held open by a straggler process) does not abort the rest of
# the uninstall. Uninstall is idempotent, so it is better to run to the end and
# warn about what could not be removed than to stop at the first failure.

# 2. Preserve or remove data
# $storagePreserved は「顧客文書(storage)を app の外へ安全に退避できたか」を表す。
# keep-data モードで退避に失敗した場合、後続の app 一括削除で文書を消さないよう
# 手順5で app フォルダをスキップするために使う。
$storagePreserved = $false
# keep-data で storage をロック等で退避できず、app を残した(=完全には削除できなかった)ことを表す。
# この場合、末尾で専用 exit 3 を返し、呼び出し側(Setup.exe)が「文書がロックされている」旨を
# 具体的に案内して中止できるようにする(自動アンインストール成功と誤認して再インストールへ進むと、
# install.ps1 の preflight が app 残存で失敗し堂々巡りになるのを防ぐ)。
$storageLocked = $false
# app を削除せず残した場合は成功として終わってはいけない（呼び出し側が
# 再インストールへ進むと preflight で必ず失敗し、堂々巡りになる）。
$script:appKept = $false
$storage = Join-Path $InstallRoot "app\server\storage"
if (-not $RemoveData -and (Test-Path $storage)) {
    try {
        $keep = Join-Path $DataRoot "uninstalled-$(Get-Date -Format yyyyMMdd-HHmmss)"
        Write-Host "Preserving data to $keep (use -RemoveData to delete instead)..."
        New-Item -ItemType Directory -Path $keep -Force -ErrorAction Stop | Out-Null
        Move-Item $storage (Join-Path $keep "storage") -ErrorAction Stop
        $storagePreserved = $true
        # アップグレード(アンインストール→インストール)のとき、install.ps1 がこの目印を
        # 見て文書データを引き継ぐ。これが無いと**更新のたびにコーパスが空になり**、
        # 顧客は全文書を入れ直すことになる(復元手段は用意されていなかった)。
        Set-Content -Path (Join-Path $DataRoot "pending-restore.txt") `
                    -Value (Join-Path $keep "storage") -Encoding UTF8
    } catch {
        $storageLocked = $true
        Write-Host "WARN: 文書データ($storage)を退避できませんでした($($_.Exception.Message))。ロックしているアプリ(エクスプローラ/ウイルス対策等)がある可能性があります。文書を保護するため、この後 $InstallRoot\app は削除せずに残します。"
    }
}

# 3. Remove the desktop shortcuts (created by install.ps1)
$desktopDir = [Environment]::GetFolderPath("CommonDesktopDirectory")
foreach ($lnkName in @("LocalRAG.lnk", "OTE-RAG アンインストール.lnk")) {
    $shortcut = Join-Path $desktopDir $lnkName
    if (Test-Path $shortcut) {
        Write-Host "Removing desktop shortcut $shortcut ..."
        try { Remove-Item $shortcut -Force -ErrorAction Stop } catch {
            Write-Host "WARN: could not remove shortcut $shortcut ($($_.Exception.Message))."
        }
    }
}

# 4. Remove the Programs and Features (ARP) registry entry.
try {
    Remove-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OTE-RAG" -Recurse -Force -ErrorAction Stop
} catch {
    Write-Host "WARN: could not remove the Programs and Features entry ($($_.Exception.Message))."
}

# 5. Remove application files.
Write-Host "Removing $InstallRoot ..."
# This script (uninstall.ps1) lives inside InstallRoot, so it cannot delete
# itself while running. We delete every other entry now; the leftover
# uninstall.ps1 (and the empty InstallRoot folder) must be removed manually,
# as noted in the final message below.
# 🔴 InstallRoot 配下を列挙して消してはならない。顧客が製品専用でないフォルダー
# (例: D:\業務データ)をインストール先に選んでいた場合、そこにある顧客のファイルを
# 巻き添えで消してしまう。ごみ箱も経由しない。本インストーラーが作る項目だけを消す。
# install.ps1 の Invoke-Rollback と同じ一覧。**増減したら両方直すこと。**
$ownedItems = @("app", "runtime", "winsw", "docs", "fixtures", "LICENSES",
                "LocalRAG.html", "LocalRAG.ico", "NOTICE", "versions.lock",
                "Uninstall-OTE-RAG.cmd", "backup.ps1", "restore.ps1",
                "start.ps1", "stop.ps1", "rag-e2e-test.ps1")
Get-ChildItem -Path $InstallRoot -Force |
    Where-Object { $_.FullName -ne $SelfPath -and $ownedItems -contains $_.Name } |
    ForEach-Object {
    $entryPath = $_.FullName
    # keep-data モードで storage を退避できなかった場合、顧客文書を含む app フォルダは
    # 削除しない(サイレントな文書消失を防ぐ)。ユーザーには手動削除を案内する。
    if ((-not $RemoveData) -and (-not $storagePreserved) -and ($_.Name -eq "app")) {
        # 🔴 storage が「そもそも無い」場合まで app を残してはいけない。
        # 守るべき文書が無いのに app が残り、次のインストールが
        # 「app が既に存在します」で失敗し、アンインストール→失敗の
        # 堂々巡りになる（そこから抜ける手段が手動削除しかない）。
        if (-not (Test-Path $storage)) {
            Write-Host "退避対象の文書データが無いため $entryPath を削除します。"
        } else {
            Write-Host "文書保護のため $entryPath は削除せず残しました。ロックを解除してから手動で削除してください。"
            $script:appKept = $true
            return
        }
    }
    try { Remove-Item -Recurse -Force $entryPath -ErrorAction Stop } catch {
        Write-Host "WARN: could not remove $entryPath ($($_.Exception.Message)). It may be in use; a reboot may be required."
    }
}

# 6. Data root
if ($RemoveData) {
    # 🔴 backups\ は残す。顧客は「消す前にバックアップを取る」運用で、既定の保存先が
    # ここ(backup.ps1 の既定出力先)。完全削除の確認文にも backups は出てこないため、
    # 一緒に消すと「告げられていない物が消える」ことになる。
    Write-Host "Removing $DataRoot (models, logs, preserved storage) - backups は残します..."
    Get-ChildItem -Path $DataRoot -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne "backups" } | ForEach-Object {
        try { Remove-Item -Recurse -Force $_.FullName -ErrorAction Stop } catch {
            Write-Host "WARN: could not remove $($_.FullName) ($($_.Exception.Message)). It may be in use; a reboot may be required."
        }
    }
    $backupDir = Join-Path $DataRoot "backups"
    if (Test-Path $backupDir) {
        Write-Host "Kept: $backupDir (バックアップは削除していません。不要なら手動で削除してください)"
    }
} else {
    Write-Host "Kept: $DataRoot (models/logs/backups and preserved storage)."
}

Write-Host ""
if ($script:appKept -and -not $storageLocked) {
    Write-Host "アンインストールは完了しましたが、文書データを保護するため $InstallRoot\app を残しました。手動で削除してから、もう一度インストールしてください。"
    exit 3
}
if ($storageLocked) {
    # 文書がロックされていて app を消せなかった。呼び出し側が区別できるよう専用コードで終了する。
    Write-Host "アンインストールは完了しましたが、文書ファイルがロックされていたため $InstallRoot\app を削除できませんでした。ロックしているアプリ(エクスプローラ/ウイルス対策等)を閉じてから、もう一度お試しください。"
    exit 3
}
# 🔴 判定は終了直前に取り直す。上の $residual は 30 秒待機の直後に採取した
# 古いスナップショットで、その後のストレージ移動（GB単位で数分かかりうる）の間に
# SCM がハンドルを解放していることが多い。古い値のまま exit 4 を返すと、
# 再起動の必要が無いのにアップグレードを止めてしまう。
if ($servicesPendingDelete) {
    $stillThere = Get-Service -Name "LocalRAG-*" -ErrorAction SilentlyContinue
    if (-not $stillThere) {
        Write-Host "サービスの削除は完了しました。"
        $servicesPendingDelete = $false
    }
}
if ($servicesPendingDelete) {
    # 削除保留のまま再インストールへ進ませない。呼び出し側が案内できるよう専用コードで返す。
    Write-Host "アンインストールは完了しましたが、サービスの削除が Windows 側で保留されています。PC を再起動してからインストールをやり直してください。"
    exit 4
}
Write-Host "Uninstall complete. You can delete the remaining uninstall.ps1 manually."
