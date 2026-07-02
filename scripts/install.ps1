# install.ps1 - Launch install.sh inside WSL2 Docker Engine environment.
#
# The LocalRAG package should live on the WSL2 Linux filesystem, not under C:\.
# Example:
#   \\wsl.localhost\Ubuntu-22.04\home\<user>\localrag\install.ps1

param(
    [string]$Distro = "Ubuntu-22.04",
    [string]$WslPath = ""
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\localrag-wsl-launcher.ps1"

$code = Invoke-LocalRagWslScript -ScriptName "install.sh" -Distro $Distro -WslPath $WslPath
exit $code
