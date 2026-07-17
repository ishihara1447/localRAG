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
#   6. Quantized ONNX reranker dir prepared for offline use.
#
# Usage example:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\export-windows.ps1 `
#     -Version 1.0.0 `
#     -SourceDir C:\LocalRAG\src `
#     -NodeDir C:\LocalRAG\build-deps\node-v22.20.0-win-x64 `
#     -OllamaDir C:\LocalRAG\build-deps\ollama `
#     -WinSWExe C:\LocalRAG\build-deps\WinSW-x64.exe `
#     -ModelsDir $env:USERPROFILE\.ollama\models `
#     -RerankerModelDir C:\LocalRAG\build-deps\reranker\bge-reranker-v2-m3-ONNX `
#     -OutputDir C:\LocalRAG\dist

param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$SourceDir,
    [Parameter(Mandatory = $true)][string]$NodeDir,
    [Parameter(Mandatory = $true)][string]$OllamaDir,
    [Parameter(Mandatory = $true)][string]$WinSWExe,
    [Parameter(Mandatory = $true)][string]$ModelsDir,
    [Parameter(Mandatory = $true)][string]$RerankerModelDir,
    [string]$OutputDir = ".\dist",
    [switch]$NoZip
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Models to bundle: model name -> manifest relative path
# 2026-07-14: switched LLM to gemma4:12b (non-Chinese, Apache 2.0, official Ollama library)
# after the model-selection evaluation (docs/MODEL_SELECTION_NON_CHINESE_2026-07-14.md).
# gemma4:12b + the tuned Japanese RAG prompt scored 25/30 with zero hallucination and beat
# qwen3:8b (22/30, 4 hallucinations) on the current 30-question eval. Embedding stays bge-m3.
# NOTE: the build machine must have gemma4:12b pulled into ModelsDir before running this
#   (ollama pull gemma4:12b). Requires an Ollama new enough for gemma4 (bundled v0.31.2 OK).
$BundleModels = @{
    "gemma4:12b"      = "manifests\registry.ollama.ai\library\gemma4\12b";
    "bge-m3:latest"   = "manifests\registry.ollama.ai\library\bge-m3\latest";
}

function Assert-Path([string]$p, [string]$what) {
    if (-not (Test-Path $p)) { Write-Host "ERROR: $what not found: $p"; exit 1 }
}

Assert-Path $SourceDir "SourceDir"
Assert-Path (Join-Path $SourceDir "server\node_modules") "server\node_modules (run yarn install on Windows first)"
Assert-Path (Join-Path $SourceDir "collector\node_modules") "collector\node_modules (run yarn install on Windows first)"
$publicDir = Join-Path $SourceDir "server\public"
if (-not ((Test-Path (Join-Path $publicDir "index.html")) -or (Test-Path (Join-Path $publicDir "_index.html")))) {
    Write-Host "ERROR: built frontend at server\public not found (expected index.html or _index.html)."
    Write-Host "       Build frontend and copy dist to server\public first."
    exit 1
}
Assert-Path (Join-Path $NodeDir "node.exe") "node.exe in NodeDir"
Assert-Path (Join-Path $OllamaDir "ollama.exe") "ollama.exe in OllamaDir"
Assert-Path (Join-Path $OllamaDir "lib\ollama\llama-server.exe") "llama-server.exe in OllamaDir (extract the full Ollama Windows zip, not only ollama.exe)"
Assert-Path $WinSWExe "WinSW executable"
Assert-Path $ModelsDir "ModelsDir"
Assert-Path $RerankerModelDir "RerankerModelDir"
foreach ($rerankerFile in @(
    "config.json",
    "tokenizer.json",
    "tokenizer_config.json",
    "special_tokens_map.json",
    "onnx\model_quantized.onnx"
)) {
    Assert-Path (Join-Path $RerankerModelDir $rerankerFile) "reranker file $rerankerFile"
}

# Verify prisma windows engine was generated
$prismaClient = Join-Path $SourceDir "server\node_modules\.prisma\client"
$winEngine = Get-ChildItem -Path $prismaClient -Filter "query_engine-windows*" -ErrorAction SilentlyContinue
if (-not $winEngine) {
    Write-Host "ERROR: no windows prisma query engine under $prismaClient."
    Write-Host "       Run: node node_modules\prisma\build\index.js generate --schema=.\prisma\schema.prisma (in server dir)"
    exit 1
}

$PkgName = "OTE-RAG-win64-v$Version"
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

# NativeEmbeddingReranker loads this exact cache path. Bundle only the default
# int8 model; the optional fp32 diagnostic model would add about 1.1GB.
Write-Host "  bundling: bge-reranker-v2-m3 ONNX int8"
$rerankerOut = Join-Path $Pkg "app\server\storage\models\onnx-community\bge-reranker-v2-m3-ONNX"
robocopy $RerankerModelDir $rerankerOut /E /NFL /NDL /NJH /NJS | Out-Null
if ($LASTEXITCODE -ge 8) { Write-Host "ERROR: robocopy reranker failed ($LASTEXITCODE)"; exit 1 }
$global:LASTEXITCODE = 0

# --- 5. scripts / config / fixtures / docs / licenses ---
Write-Host "[5/7] Copying install scripts, config templates, fixtures, docs, licenses..."
foreach ($f in @("Install-OTE-RAG.cmd", "install.ps1", "uninstall.ps1", "start.ps1", "stop.ps1", "backup.ps1", "restore.ps1", "rag-e2e-test.ps1")) {
    $src = Join-Path $ScriptDir $f
    Assert-Path $src $f
    Copy-Item $src (Join-Path $Pkg $f)
}
robocopy (Join-Path $ScriptDir "config") (Join-Path $Pkg "config") /E /NFL /NDL /NJH /NJS | Out-Null
robocopy (Join-Path $ScriptDir "launcher") (Join-Path $Pkg "launcher") /E /NFL /NDL /NJH /NJS | Out-Null
$repoRoot = Split-Path -Parent $ScriptDir
if (Test-Path (Join-Path $repoRoot "fixtures")) {
    robocopy (Join-Path $repoRoot "fixtures") (Join-Path $Pkg "fixtures") /E /NFL /NDL /NJH /NJS /XF "*Zone.Identifier*" | Out-Null
}
if (Test-Path (Join-Path $repoRoot "LICENSES")) {
    robocopy (Join-Path $repoRoot "LICENSES") (Join-Path $Pkg "LICENSES") /E /NFL /NDL /NJH /NJS | Out-Null
}
if (Test-Path (Join-Path $repoRoot "NOTICE")) {
    Copy-Item (Join-Path $repoRoot "NOTICE") (Join-Path $Pkg "NOTICE")
}
# Windows native package ships the Windows-native customer docs
# (docs\customer is the Docker-distribution manual and does not apply here).
if (Test-Path (Join-Path $repoRoot "docs\customer-windows")) {
    robocopy (Join-Path $repoRoot "docs\customer-windows") (Join-Path $Pkg "docs") /E /NFL /NDL /NJH /NJS | Out-Null
} else {
    throw "ERROR: docs\customer-windows not found. Sync customer docs into the build tree before exporting."
}
if (Test-Path (Join-Path $repoRoot "docs\MODEL_CARDS.md")) {
    New-Item -ItemType Directory -Force -Path (Join-Path $Pkg "docs") | Out-Null
    Copy-Item (Join-Path $repoRoot "docs\MODEL_CARDS.md") (Join-Path $Pkg "docs\MODEL_CARDS.md")
}
$global:LASTEXITCODE = 0

# --- 6. versions.lock ---
Write-Host "[6/7] Writing versions.lock..."
$nodeVer = & (Join-Path $Pkg "runtime\node\node.exe") --version
$ollamaVer = "unknown"
try {
    # "ollama --version" reports the version of a REACHABLE SERVER on the first
    # line (e.g. a WSL relay on 11434), plus "Warning: client version is X" when
    # they differ. versions.lock must record the bundled CLIENT binary version.
    $verOut = & (Join-Path $Pkg "runtime\ollama\ollama.exe") --version 2>&1
    $clientLine = $verOut | Where-Object { $_ -match "client version is" } | Select-Object -First 1
    if ($clientLine) {
        $ollamaVer = ($clientLine -replace ".*client version is\s*", "").Trim()
    } else {
        $ollamaVer = ($verOut | Select-Object -First 1) -replace "ollama version is\s*", ""
    }
} catch {}
@(
    "package_version=$Version",
    "build_date=$(Get-Date -Format yyyy-MM-ddTHH:mm:ssK)",
    "node=$nodeVer",
    "ollama=$ollamaVer",
    "models=$($BundleModels.Keys -join ', ')",
    "reranker=onnx-community/bge-reranker-v2-m3-ONNX (int8)",
    "source_dir=$SourceDir"
) | Set-Content -Path (Join-Path $Pkg "versions.lock")

# --- 7. checksums (package.sha256 over every file) ---
Write-Host "[7/7] Generating checksums\package.sha256 (this can take a while)..."
$zoneIdentifierFiles = @(Get-ChildItem -Path $Pkg -Recurse -File | Where-Object { $_.Name -like "*Zone.Identifier*" })
if ($zoneIdentifierFiles.Count -gt 0) {
    Write-Host "ERROR: Zone.Identifier sidecar files must not be packaged:"
    $zoneIdentifierFiles | ForEach-Object { Write-Host "  $($_.FullName)" }
    exit 1
}
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
    $largeFiles = Get-ChildItem -Path $Pkg -Recurse -File | Where-Object { $_.Length -gt 1900MB }
    if ($largeFiles) {
        $tar = Get-Command tar.exe -ErrorAction SilentlyContinue
        if (-not $tar) {
            Write-Host "ERROR: package contains files larger than 2GB, but tar.exe was not found."
            Write-Host "       Install a zip tool that supports large files or rerun with -NoZip and archive manually."
            exit 1
        }
        Write-Host "  Large files detected; using tar.exe because Compress-Archive is not reliable above 2GB per file."
        Push-Location $OutputDir
        try {
            & $tar.Source -a -cf "$PkgName.zip" $PkgName
            if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: tar.exe zip creation failed ($LASTEXITCODE)"; exit 1 }
        } finally {
            Pop-Location
        }
    } else {
        Compress-Archive -Path $Pkg -DestinationPath $zipPath -CompressionLevel Optimal
    }

    Write-Host "Generating outer ZIP checksum..."
    $zipHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLower()
    $zipShaPath = "$zipPath.sha256"
    "$zipHash  $([System.IO.Path]::GetFileName($zipPath))" | Set-Content -LiteralPath $zipShaPath -Encoding ascii

    Write-Host "Building double-click Setup.exe..."
    $setupBuilder = Join-Path $ScriptDir "setup\build-setup.ps1"
    Assert-Path $setupBuilder "OTE-RAG setup builder"
    $setupPath = Join-Path $OutputDir "OTE-RAG-Setup.exe"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setupBuilder -OutputPath $setupPath
    if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: Setup.exe build failed ($LASTEXITCODE)"; exit 1 }

    Write-Host "Package sha: $zipShaPath"
    Write-Host "Installer:     $setupPath"
    Write-Host "Package zip: $zipPath"
}

Write-Host ""
Write-Host "Export complete: $Pkg"
Write-Host "Next: verify on a clean machine/state with install.ps1 (see docs)."

