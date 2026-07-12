# join-and-install.ps1 - Company-PC side: reassemble the split distribution,
# verify it, then install LocalRAG and leave it running for a hands-on demo.
#
# The 8.3GB v1.1.0 zip is split into <2GB parts and attached to a GitHub Release
# (a single 5.2GB model blob exceeds every GitHub Git/LFS per-file limit, so raw
# git cannot carry it). Download all `*.zip.part*` files plus the `.sha256` from
# the Release into one folder, then run this (elevated; use Join-And-Install.cmd).
#
# Prerequisites on the company PC:
#   - NVIDIA GPU (RTX 5070 Ti / 16GB VRAM class) with a recent driver.  <-- HARD requirement
#   - Windows 11 (or Win10 21H2+), ~30GB free disk, Administrator rights.
param(
    [string]$PartsDir = ".",
    [string]$WorkDir  = "C:\Temp\localrag-app",
    [string]$InstallRoot = "C:\LocalRAG",
    [int]$ServerPort = 3001,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

Write-Host "==== LocalRAG join + install (company PC) ===="
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Write-Host "ERROR: run elevated (use Join-And-Install.cmd)."; exit 1 }

$PartsDir = (Resolve-Path $PartsDir).ProviderPath
$parts = Get-ChildItem -Path $PartsDir -Filter "LocalRAG-win64-v1.1.0.zip.part*" | Sort-Object Name
if ($parts.Count -eq 0) { Write-Host "ERROR: no 'LocalRAG-win64-v1.1.0.zip.part*' files found in $PartsDir"; exit 1 }
Write-Host "Found $($parts.Count) part(s):"
$parts | ForEach-Object { Write-Host ("  {0}  ({1:N0} bytes)" -f $_.Name, $_.Length) }

New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
$zipPath = Join-Path $WorkDir "LocalRAG-win64-v1.1.0.zip"

Write-Host "[1/3] Joining parts -> $zipPath ..."
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
$out = [System.IO.File]::Create($zipPath)
try {
    foreach ($p in $parts) {
        $in = [System.IO.File]::OpenRead($p.FullName)
        try { $in.CopyTo($out, 1MB) } finally { $in.Dispose() }
        Write-Host "  appended $($p.Name)"
    }
} finally { $out.Dispose() }

# Verify against the .sha256 shipped with the parts (if present).
$shaFile = Get-ChildItem -Path $PartsDir -Filter "LocalRAG-win64-v1.1.0.zip.sha256" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($shaFile) {
    Write-Host "[2/3] Verifying SHA256 (this hashes 8GB, a minute or two)..."
    $expected = ((Get-Content $shaFile.FullName -First 1) -split '\s+')[0].ToLower()
    $actual = (Get-FileHash -Algorithm SHA256 -Path $zipPath).Hash.ToLower()
    if ($expected -ne $actual) {
        Write-Host "ERROR: SHA256 mismatch. The download is incomplete or corrupted."
        Write-Host "  expected=$expected"
        Write-Host "  actual  =$actual"
        exit 1
    }
    Write-Host "  SHA256 OK ($actual)"
} else {
    Write-Host "[2/3] WARN: no .sha256 file found next to the parts; skipping integrity check."
}

Write-Host "[3/3] Extracting + installing (leaves the app running)..."
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$installDemo = Join-Path $scriptDir "..\verify\install-demo.ps1"
if (-not (Test-Path $installDemo)) { Write-Host "ERROR: install-demo.ps1 not found at $installDemo (clone the whole windows-native tree)."; exit 1 }
$forceArg = @(); if ($Force) { $forceArg = @("-Force") }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installDemo -ZipPath $zipPath -InstallRoot $InstallRoot -ServerPort $ServerPort @forceArg
$code = $LASTEXITCODE

Write-Host ""
if ($code -eq 0) {
    Write-Host "==== DONE. Open the UI in your browser: http://localhost:$ServerPort ===="
} else {
    Write-Host "==== install exited with code $code. See messages above. ===="
    Write-Host "Note: if it stopped at 'nvidia-smi not found' or a VRAM warning, this PC does"
    Write-Host "      not meet the GPU requirement (that itself is the answer to hypothesis D)."
}
exit $code
