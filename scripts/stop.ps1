# stop.ps1 - Launch stop.sh inside WSL2 Docker Engine environment.

param(
    [string]$Distro = "Ubuntu-22.04",
    [string]$WslPath = ""
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\localrag-wsl-launcher.ps1"

$code = Invoke-LocalRagWslScript -ScriptName "stop.sh" -Distro $Distro -WslPath $WslPath
exit $code
