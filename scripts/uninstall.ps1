# uninstall.ps1 - Launch uninstall.sh inside WSL2 Docker Engine environment.

param(
    [switch]$KeepData,
    [string]$Distro = "Ubuntu-22.04",
    [string]$WslPath = ""
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\localrag-wsl-launcher.ps1"

$argsForBash = @()
if ($KeepData) {
    $argsForBash += "--keep-data"
}

$code = Invoke-LocalRagWslScript -ScriptName "uninstall.sh" -ScriptArgs $argsForBash -Distro $Distro -WslPath $WslPath
exit $code
