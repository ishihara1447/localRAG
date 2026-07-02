# start.ps1 - Launch start.sh inside WSL2 Docker Engine environment.

param(
    [string]$Distro = "Ubuntu-22.04",
    [string]$WslPath = ""
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\localrag-wsl-launcher.ps1"

$code = Invoke-LocalRagWslScript -ScriptName "start.sh" -Distro $Distro -WslPath $WslPath
exit $code
