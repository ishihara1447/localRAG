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
    # Windows drive paths are converted to /mnt/* by wslpath. This is allowed
    # for one-time reads such as restore archives, but it is slow and should not
    # be used for the LocalRAG package or model/storage directories.
    if ($converted -like "/mnt/*") {
        Write-Warning ("Path '$resolved' was converted to a WSL /mnt Windows-drive path: $converted`n" +
            "Large file I/O may be slow. Prefer the WSL2 Linux filesystem when possible.")
    }
    return $converted
}

function Quote-BashArg {
    param([Parameter(Mandatory = $true)][string]$Value)
    $sq = [char]39
    $replacement = [string]$sq + "\" + [string]$sq + [string]$sq
    $escaped = $Value.Replace([string]$sq, $replacement)
    return ([string]$sq + $escaped + [string]$sq)
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

    # Bash scripts emit UTF-8 logs. Windows PowerShell 5.1 often uses a legacy
    # console code page, so force UTF-8 where possible.
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $OutputEncoding = [System.Text.Encoding]::UTF8
    } catch {
        # Some redirected/non-interactive hosts cannot change encoding.
    }

    # Probe the requested distro by running a tiny command. Parsing `wsl -l -q`
    # is fragile across Windows hosts because the output encoding varies.
    & wsl.exe -d $Distro -- true 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        # Add the distro list as a best-effort hint.
        $hint = ""
        $distroList = & wsl.exe -l -q 2>$null
        if ($distroList) {
            $available = @($distroList | ForEach-Object { ($_ -replace "`0", "").Trim() } | Where-Object { $_ -ne "" })
            if ($available.Count -gt 0) { $hint = " Available distros: " + ($available -join ", ") }
        }
        throw ("Cannot start WSL distro '$Distro'. Confirm WSL2 and the target Ubuntu distro are installed. " +
            "If the distro name is different, pass it with the -Distro option." + $hint)
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
