# backup.ps1 - Launch backup.sh inside WSL2 Docker Engine environment.

param(
    [switch]$Live,
    [string]$Distro = "Ubuntu-22.04",
    [string]$WslPath = ""
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\localrag-wsl-launcher.ps1"

$argsForBash = @()
if ($Live) {
    $argsForBash += "--live"
}

$code = Invoke-LocalRagWslScript -ScriptName "backup.sh" -ScriptArgs $argsForBash -Distro $Distro -WslPath $WslPath
exit $code
