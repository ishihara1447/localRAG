# install-demo.ps1 - Hands-on install for manual动作确认 (NOT the Round2 verifier).
# Unlike round2-admin-verify.ps1, this leaves the app INSTALLED and RUNNING so a
# human can open the UI and click around. It only extracts + installs; it never
# uninstalls. Run elevated (use Install-LocalRAG-Demo.cmd for one-click UAC).
#
# Defaults are chosen to coexist with the WSL2 Docker dev instance on this machine:
#   - ServerPort 3005 (3001 is held by the WSL relay / Docker AnythingLLM)
#   - InstallRoot C:\LocalRAGProd (keeps the build tree under C:\LocalRAG clean)
param(
    [string]$ZipPath = "C:\LocalRAG\dist\LocalRAG-win64-v1.1.0.zip",
    [string]$ExtractRoot = "C:\Temp\localrag-app",
    [string]$InstallRoot = "C:\LocalRAGProd",
    [int]$ServerPort = 3005,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

Write-Host "==== LocalRAG demo install (hands-on) ===="
Write-Host "ZipPath=$ZipPath"
Write-Host "InstallRoot=$InstallRoot  ServerPort=$ServerPort"

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Write-Host "ERROR: run elevated (use Install-LocalRAG-Demo.cmd)."; exit 1 }
if (-not (Test-Path $ZipPath)) { Write-Host "ERROR: zip not found: $ZipPath"; exit 1 }

# Refuse to clobber an existing install unless -Force (keeps user data safe).
if ((Test-Path (Join-Path $InstallRoot "app")) -and -not $Force) {
    Write-Host "ERROR: $InstallRoot\app already exists. Uninstall first (uninstall.ps1) or pass -Force."
    exit 1
}

Write-Host "[1/2] Extracting package (tar.exe, a few minutes)..."
if (Test-Path $ExtractRoot) { Remove-Item -Recurse -Force $ExtractRoot -ErrorAction Continue }
New-Item -ItemType Directory -Path $ExtractRoot -Force | Out-Null
Push-Location $ExtractRoot
try {
    & tar.exe -xf $ZipPath
    if ($LASTEXITCODE -ne 0) { throw "tar.exe failed ($LASTEXITCODE)" }
} finally { Pop-Location; $global:LASTEXITCODE = 0 }

$PkgRoot = Join-Path $ExtractRoot ([System.IO.Path]::GetFileNameWithoutExtension($ZipPath))
$installPs1 = Join-Path $PkgRoot "install.ps1"
if (-not (Test-Path $installPs1)) { Write-Host "ERROR: install.ps1 not found after extract: $PkgRoot"; exit 1 }

Write-Host "[2/2] Installing (preflight -> checksum -> services). Leaves the app running..."
$forceArg = @(); if ($Force) { $forceArg = @("-Force") }
Push-Location $PkgRoot
try {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installPs1 -InstallRoot $InstallRoot -ServerPort $ServerPort @forceArg
    $code = $LASTEXITCODE
} finally { Pop-Location }

Write-Host ""
if ($code -eq 0) {
    Write-Host "==== DONE. Open the UI in your browser: http://localhost:$ServerPort ===="
    Write-Host "The three LocalRAG-* services stay running (Automatic start) until you run uninstall.ps1."
    Write-Host "Uninstall later:  cd $InstallRoot; powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1"
} else {
    Write-Host "==== install.ps1 exited with code $code. See the messages above and C:\ProgramData\LocalRAG\logs ===="
}
