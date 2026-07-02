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
    return $converted.Trim()
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
