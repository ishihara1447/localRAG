# localrag-wsl-launcher.ps1 - Shared WSL launcher for Windows entrypoints.

function ConvertTo-LocalRagWslPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Distro,
        [switch]$RequireWslFileSystem
    )

    $resolved = $Path
    try {
        $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    } catch {
        # Keep the original path. This is useful for optional restore arguments.
    }

    $normalized = $resolved -replace '/', '\'
    if ($normalized -match '^\\\\(?:wsl\.localhost|wsl\$)\\([^\\]+)\\(.+)$') {
        $pathDistro = $Matches[1]
        if ($pathDistro -ne $Distro) {
            Write-Warning "Path is under WSL distro '$pathDistro', but launcher uses '$Distro'."
        }
        return "/" + ($Matches[2] -replace '\\', '/')
    }

    if ($RequireWslFileSystem) {
        throw @"
This launcher expects the LocalRAG package to be placed on the WSL2 Linux filesystem.
Current path: $resolved

Copy the package under the target distro, for example:
  \\wsl.localhost\$Distro\home\<user>\localrag

Or run inside WSL:
  cd ~/localrag && bash install.sh
"@
    }

    $converted = & wsl.exe -d $Distro -- wslpath -a $resolved
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($converted)) {
        throw "Failed to convert Windows path to WSL path: $resolved"
    }
    $converted = $converted.Trim()
    # Windows 側 (C:\ 等) のパスは /mnt/ 配下に変換される。DrvFs 越しの I/O は遅く
    # 信頼性も落ちるため、拒否はしないが警告する (バックアップ復元など一度きりの
    # 読み込みでは許容されうる。常時 I/O が発生する配置は WSL2 ext4 側に置くこと)。
    if ($converted -like "/mnt/*") {
        Write-Warning ("パス '$resolved' は WSL2 の /mnt (Windows ドライブ) 配下に変換されました: $converted`n" +
            "大容量ファイルの I/O が遅くなります。可能なら WSL2 Linux ファイルシステム側に配置してください。")
    }
    return $converted
}

function Quote-BashArg {
    param([Parameter(Mandatory = $true)][string]$Value)
    $escaped = $Value.Replace("'", "'\''")
    return "'$escaped'"
}

function Invoke-LocalRagWslScript {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptName,
        [string[]]$ScriptArgs = @(),
        [string]$Distro = "Ubuntu-22.04",
        [string]$WslPath = ""
    )

    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        throw "wsl.exe was not found. Enable WSL2 and install the target Ubuntu distro first."
    }

    # WSL2 内の bash スクリプトは日本語ログを出力する。既定の Windows PowerShell
    # コンソールエンコーディングは UTF-8 でないことが多く、そのままだと文字化けする
    # ため、UTF-8 を明示する。失敗しても致命的ではないので握りつぶす。
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $OutputEncoding = [System.Text.Encoding]::UTF8
    } catch {
        # コンソールが無い/リダイレクト環境では設定できないことがある。無視してよい。
    }

    # 指定 distro が使えるか、軽量コマンドで直接プローブする。wsl.exe -l -q の出力は
    # UTF-16LE で、既定コンソールだと文字化けしやすくパースが不安定なため、一覧の
    # 突き合わせではなく「実際に起動できるか」を exit code で判定する (存在しない/
    # 停止中でも起動できれば OK。この後どのみち起動するので副作用も問題ない)。
    & wsl.exe -d $Distro -- true 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        # エラーメッセージ補助として distro 一覧を best-effort で添える (文字化けし得るが
        # 既にエラー経路なので許容)。
        $hint = ""
        $distroList = & wsl.exe -l -q 2>$null
        if ($distroList) {
            $available = @($distroList | ForEach-Object { ($_ -replace "`0", "").Trim() } | Where-Object { $_ -ne "" })
            if ($available.Count -gt 0) { $hint = " 利用可能な distro: " + ($available -join ", ") }
        }
        throw ("WSL distro '$Distro' を起動できません。WSL2 と対象 Ubuntu distro が" +
            "導入済みか確認し、名前が異なる場合は ``-Distro`` オプションで指定してください。" + $hint)
    }

    if ([string]::IsNullOrWhiteSpace($WslPath)) {
        $scriptDir = $PSScriptRoot
        $WslPath = ConvertTo-LocalRagWslPath -Path $scriptDir -Distro $Distro -RequireWslFileSystem
    }

    $quotedDir = Quote-BashArg $WslPath
    $quotedScript = Quote-BashArg "./$ScriptName"
    $quotedArgs = ($ScriptArgs | ForEach-Object { Quote-BashArg $_ }) -join " "
    $cmd = "cd $quotedDir && bash $quotedScript"
    if (-not [string]::IsNullOrWhiteSpace($quotedArgs)) {
        $cmd = "$cmd $quotedArgs"
    }

    & wsl.exe -d $Distro -- bash -lc $cmd
    return $LASTEXITCODE
}
