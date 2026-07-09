# export-windows.ps1 - Build the LocalRAG Windows-native distribution package.
#
# Runs on the BUILD machine (Windows, online). The produced package installs
# fully OFFLINE on the customer machine.
#
# ASCII-only comments/messages by convention (PowerShell 5.1 compatibility).
#
# Prerequisites on the build machine (see docs/CODEX_WINDOWS_NATIVE_BUILD_AND_VERIFY_2026-07-09.md):
#   1. Source tree copied from WSL with yarn install done on Windows
#      (server/collector with node_modules, frontend built and copied to server\public,
#       prisma generate done with binaryTargets windows).
#   2. Node.js portable runtime dir (extracted node-vXX-win-x64 zip).
#   3. Ollama standalone dir (extracted ollama-windows-amd64.zip).
#   4. WinSW-x64.exe downloaded.
#   5. Ollama models present in a models dir (manifests/ + blobs/), e.g. %USERPROFILE%\.ollama\models
#
# Usage example:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\export-windows.ps1 `
#     -Version 1.0.0 `
#     -SourceDir C:\LocalRAG\src `
#     -NodeDir C:\LocalRAG\build-deps\node-v22.20.0-win-x64 `
#     -OllamaDir C:\LocalRAG\build-deps\ollama `
#     -WinSWExe C:\LocalRAG\build-deps\WinSW-x64.exe `
#     -ModelsDir $env:USERPROFILE\.ollama\models `
#     -OutputDir C:\LocalRAG\dist

param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$SourceDir,
    [Parameter(Mandatory = $true)][string]$NodeDir,
    [Parameter(Mandatory = $true)][string]$OllamaDir,
    [Parameter(Mandatory = $true)][string]$WinSWExe,
    [Parameter(Mandatory = $true)][string]$ModelsDir,
    [string]$OutputDir = ".\dist",
    [switch]$NoZip
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Models to bundle: model name -> manifest relative path
$BundleModels = @{
    "hf.co/mmnga-o/llm-jp-4-8b-thinking-gguf:Q4_K_M" = "manifests\hf.co\mmnga-o\llm-jp-4-8b-thinking-gguf\Q4_K_M";
    "mxbai-embed-large:latest"                       = "manifests\registry.ollama.ai\library\mxbai-embed-large\latest";
}

function Assert-Path([string]$p, [string]$what) {
    if (-not (Test-Path $p)) { Write-Host "ERROR: $what not found: $p"; exit 1 }
}

Assert-Path $SourceDir "SourceDir"
Assert-Path (Join-Path $SourceDir "server\node_modules") "server\node_modules (run yarn install on Windows first)"
Assert-Path (Join-Path $SourceDir "collector\node_modules") "collector\node_modules (run yarn install on Windows first)"
Assert-Path (Join-Path $SourceDir "server\public\index.html") "built frontend at server\public (build frontend and copy dist)"
Assert-Path (Join-Path $NodeDir "node.exe") "node.exe in NodeDir"
Assert-Path (Join-Path $OllamaDir "ollama.exe") "ollama.exe in OllamaDir"
Assert-Path $WinSWExe "WinSW executable"
Assert-Path $ModelsDir "ModelsDir"

# Verify prisma windows engine was generated
$prismaClient = Join-Path $SourceDir "server\node_modules\.prisma\client"
$winEngine = Get-ChildItem -Path $prismaClient -Filter "query_engine-windows*" -ErrorAction SilentlyContinue
if (-not $winEngine) {
    Write-Host "ERROR: no windows prisma query engine under $prismaClient."
    Write-Host "       Run: node node_modules\prisma\build\index.js generate --schema=.\prisma\schema.prisma (in server dir)"
    exit 1
}

$PkgName = "LocalRAG-win64-v$Version"
$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)
$Pkg = Join-Path $OutputDir $PkgName
if (Test-Path $Pkg) { Write-Host "ERROR: $Pkg already exists. Remove it first."; exit 1 }
New-Item -ItemType Directory -Path $Pkg -Force | Out-Null
Write-Host "Building package: $Pkg"

# --- 1. app (server + collector, without dev leftovers) ---
Write-Host "[1/7] Copying app (server/collector with node_modules)..."
# Note: robocopy /XD matches directory NAMES anywhere in the tree (it would also
# hit e.g. node_modules\*\storage), so copy everything and prune top-level
# runtime-data dirs afterwards instead.
robocopy (Join-Path $SourceDir "server") (Join-Path $Pkg "app\server") /E /NFL /NDL /NJH /NJS /XF .env | Out-Null
if ($LASTEXITCODE -ge 8) { Write-Host "ERROR: robocopy server failed ($LASTEXITCODE)"; exit 1 }
robocopy (Join-Path $SourceDir "collector") (Join-Path $Pkg "app\collector") /E /NFL /NDL /NJH /NJS /XF .env | Out-Null
if ($LASTEXITCODE -ge 8) { Write-Host "ERROR: robocopy collector failed ($LASTEXITCODE)"; exit 1 }
# Runtime data must start clean on the customer machine.
Remove-Item -Recurse -Force (Join-Path $Pkg "app\server\storage") -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force (Join-Path $Pkg "app\collector\hotdir") -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path (Join-Path $Pkg "app\collector\hotdir") -Force | Out-Null
Set-Content -Path (Join-Path $Pkg "app\collector\hotdir\__HOTDIR__.md") -Value "Files dropped here are processed by the collector."
$global:LASTEXITCODE = 0

# --- 2. runtime (node + ollama) ---
Write-Host "[2/7] Copying runtimes (node, ollama)..."
robocopy $NodeDir (Join-Path $Pkg "runtime\node") /E /NFL /NDL /NJH /NJS | Out-Null
if ($LASTEXITCODE -ge 8) { Write-Host "ERROR: robocopy node failed"; exit 1 }
robocopy $OllamaDir (Join-Path $Pkg "runtime\ollama") /E /NFL /NDL /NJH /NJS | Out-Null
if ($LASTEXITCODE -ge 8) { Write-Host "ERROR: robocopy ollama failed"; exit 1 }
$global:LASTEXITCODE = 0

# --- 3. winsw (WinSW.exe + service XMLs + register/unregister) ---
Write-Host "[3/7] Copying WinSW + service definitions..."
New-Item -ItemType Directory -Path (Join-Path $Pkg "winsw") -Force | Out-Null
Copy-Item $WinSWExe (Join-Path $Pkg "winsw\WinSW.exe")
Copy-Item (Join-Path $ScriptDir "service\*.xml") (Join-Path $Pkg "winsw\")
Copy-Item (Join-Path $ScriptDir "service\register-services.ps1") (Join-Path $Pkg "winsw\")
Copy-Item (Join-Path $ScriptDir "service\unregister-services.ps1") (Join-Path $Pkg "winsw\")

# --- 4. models (only the manifests + blobs the bundled models reference) ---
Write-Host "[4/7] Copying models (manifest-driven blob selection)..."
$modelsOut = Join-Path $Pkg "models"
foreach ($model in $BundleModels.Keys) {
    $manifestRel = $BundleModels[$model]
    $manifestSrc = Join-Path $ModelsDir $manifestRel
    Assert-Path $manifestSrc "manifest for $model"
    $manifestDst = Join-Path $modelsOut $manifestRel
    New-Item -ItemType Directory -Path (Split-Path -Parent $manifestDst) -Force | Out-Null
    Copy-Item $manifestSrc $manifestDst

    $manifest = Get-Content $manifestSrc -Raw | ConvertFrom-Json
    $digests = @($manifest.config.digest) + @($manifest.layers | ForEach-Object { $_.digest })
    foreach ($digest in $digests) {
        if (-not $digest) { continue }
        $blobName = $digest -replace ":", "-"
        $blobSrc = Join-Path $ModelsDir "blobs\$blobName"
        Assert-Path $blobSrc "blob $blobName for $model"
        $blobDst = Join-Path $modelsOut "blobs\$blobName"
        if (-not (Test-Path $blobDst)) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $blobDst) -Force | Out-Null
            Copy-Item $blobSrc $blobDst
        }
    }
    Write-Host "  bundled: $model ($($digests.Count) blobs)"
}

# --- 5. scripts / config / fixtures / docs / licenses ---
Write-Host "[5/7] Copying install scripts, config templates, fixtures, docs, licenses..."
foreach ($f in @("install.ps1", "uninstall.ps1", "start.ps1", "stop.ps1", "backup.ps1", "restore.ps1", "rag-e2e-test.ps1")) {
    $src = Join-Path $ScriptDir $f
    Assert-Path $src $f
    Copy-Item $src (Join-Path $Pkg $f)
}
robocopy (Join-Path $ScriptDir "config") (Join-Path $Pkg "config") /E /NFL /NDL /NJH /NJS | Out-Null
$repoRoot = Split-Path -Parent $ScriptDir
if (Test-Path (Join-Path $repoRoot "fixtures")) {
    robocopy (Join-Path $repoRoot "fixtures") (Join-Path $Pkg "fixtures") /E /NFL /NDL /NJH /NJS | Out-Null
}
if (Test-Path (Join-Path $repoRoot "LICENSES")) {
    robocopy (Join-Path $repoRoot "LICENSES") (Join-Path $Pkg "LICENSES") /E /NFL /NDL /NJH /NJS | Out-Null
}
if (Test-Path (Join-Path $repoRoot "NOTICE")) {
    Copy-Item (Join-Path $repoRoot "NOTICE") (Join-Path $Pkg "NOTICE")
}
if (Test-Path (Join-Path $repoRoot "docs\customer")) {
    robocopy (Join-Path $repoRoot "docs\customer") (Join-Path $Pkg "docs") /E /NFL /NDL /NJH /NJS | Out-Null
}
$global:LASTEXITCODE = 0

# --- 6. versions.lock ---
Write-Host "[6/7] Writing versions.lock..."
$nodeVer = & (Join-Path $Pkg "runtime\node\node.exe") --version
$ollamaVer = "unknown"
try { $ollamaVer = (& (Join-Path $Pkg "runtime\ollama\ollama.exe") --version 2>$null | Select-Object -First 1) } catch {}
@(
    "package_version=$Version",
    "build_date=$(Get-Date -Format yyyy-MM-ddTHH:mm:ssK)",
    "node=$nodeVer",
    "ollama=$ollamaVer",
    "models=$($BundleModels.Keys -join ', ')",
    "source_dir=$SourceDir"
) | Set-Content -Path (Join-Path $Pkg "versions.lock")

# --- 7. checksums (package.sha256 over every file) ---
Write-Host "[7/7] Generating checksums\package.sha256 (this can take a while)..."
New-Item -ItemType Directory -Path (Join-Path $Pkg "checksums") -Force | Out-Null
$checksumFile = Join-Path $Pkg "checksums\package.sha256"
$lines = New-Object System.Collections.Generic.List[string]
Get-ChildItem -Path $Pkg -Recurse -File | Where-Object { $_.FullName -notlike "*\checksums\*" } | ForEach-Object {
    $rel = $_.FullName.Substring($Pkg.Length + 1) -replace "\\", "/"
    $hash = (Get-FileHash -Algorithm SHA256 -Path $_.FullName).Hash.ToLower()
    $lines.Add("$hash  $rel")
}
$lines | Set-Content -Path $checksumFile -Encoding ascii
Write-Host "  $($lines.Count) files hashed."

# --- zip ---
if (-not $NoZip) {
    $zipPath = Join-Path $OutputDir "$PkgName.zip"
    Write-Host "Compressing to $zipPath (large, please wait)..."
    if (Test-Path $zipPath) { Remove-Item $zipPath }
    Compress-Archive -Path $Pkg -DestinationPath $zipPath -CompressionLevel Optimal
    Write-Host "Package zip: $zipPath"
}

Write-Host ""
Write-Host "Export complete: $Pkg"
Write-Host "Next: verify on a clean machine/state with install.ps1 (see docs)."
