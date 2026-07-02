# restore.ps1 - Launch restore.sh inside WSL2 Docker Engine environment.

param(
    [string]$BackupFile = "",
    [string]$Distro = "Ubuntu-22.04",
    [string]$WslPath = ""
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\localrag-wsl-launcher.ps1"

$argsForBash = @()
if (-not [string]::IsNullOrWhiteSpace($BackupFile)) {
    $argsForBash += (ConvertTo-LocalRagWslPath -Path $BackupFile -Distro $Distro)
}

$code = Invoke-LocalRagWslScript -ScriptName "restore.sh" -ScriptArgs $argsForBash -Distro $Distro -WslPath $WslPath
exit $code
