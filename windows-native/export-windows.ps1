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
#     -RerankerModelDir C:\LocalRAG\build-deps\reranker\japanese-reranker-xsmall-v2 `
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

# Reranker model name (cache path under storage/models). 2026-08-04: switched from
# BAAI's bge-reranker-v2-m3 (Chinese) to hotchpotch/japanese-reranker-xsmall-v2
# (MIT, Japanese lineage only: cl-nagoya <- sbintuitions).
# Accuracy: 27/30 vs 27/30 on the 30-question eval (same-condition A/B, 3 runs
#   each, identical per-question). NOT an improvement - it is a tie. Do not
#   quote "26/30 -> 27/30"; that comparison was withdrawn (the 26/30 came from a
#   different condition, before sessionId was introduced).
# Rerank time: median ~4,400ms -> ~500ms (measured, about 1/9).
# See docs/RERANKER_SWAP_2026-08-04.md and out/reranker-ab-2026-08-04/.
# NOTE: the bundled config.json must have model_type rewritten to xlm-roberta
#   because the bundled @xenova/transformers 2.17.2 does not know modernbert.
$RerankerModelName = "hotchpotch/japanese-reranker-xsmall-v2"

# Models to bundle: model name -> manifest relative path
#
# 2026-08-04: switched LLM to granite4.1:8b (IBM, Apache-2.0, official Ollama library)
#   for the Windows / VRAM 8GB target. gemma4:12b measures 8.4GB VRAM at ctx 8192,
#   which does not fit in 8GB once bge-m3 (0.6GB) is resident. granite4.1:8b measures
#   6.7GB under the identical condition.
#   Accuracy is a TIE, not an improvement: 27/30 vs 27/30 on the 30-question eval
#   (same-condition A/B, 3 runs each, identical per question). The category mix does
#   differ - granite is +1 on direct facts and +1 on numeric discrimination but -2 on
#   definitions, and those 2 losses are keyword-matching artifacts (it paraphrases
#   instead of reproducing the set phrases). See docs/LLM_8GB_AB_2026-08-04.md.
#
#   The system prompt is still the one tuned for gemma4. It was deliberately NOT
#   retuned for granite, so that the measurement isolated the model change.
#
# 2026-07-14 (superseded): gemma4:12b replaced qwen3:8b (Chinese).
#   docs/MODEL_SELECTION_NON_CHINESE_2026-07-14.md
#
# NOTE: the build machine must have granite4.1:8b pulled into ModelsDir before running
#   this (ollama pull granite4.1:8b). Embedding stays bge-m3.
$BundleModels = @{
    "granite4.1:8b"   = "manifests\registry.ollama.ai\library\granite4.1\8b";
    "granite-embedding:278m" = "manifests\registry.ollama.ai\library\granite-embedding\278m";
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
# frontend\.env の開発値 (VITE_API_BASE='http://localhost:3001/api') のままビルドすると、
# 絶対URLが配布バンドルに焼き込まれ、顧客環境でAPIに到達できなくなる。
# .env ではなくビルド成果物そのものを検査する（.env を直しても再ビルドし忘れれば同じ事故になるため）。
$bundleJs = Get-ChildItem -Path $publicDir -Filter "*.js" -Recurse -ErrorAction SilentlyContinue
$devApiHit = $bundleJs | Where-Object { Select-String -Path $_.FullName -Pattern "localhost:3001" -Quiet -ErrorAction SilentlyContinue }
if ($devApiHit) {
    Write-Host "ERROR: built frontend contains 'localhost:3001' - it was built with the dev VITE_API_BASE."
    Write-Host "       Set frontend\.env to VITE_API_BASE='/api', rebuild the frontend, recopy dist to server\public."
    Write-Host "       Offending file(s): $($devApiHit.FullName -join ', ')"
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
# 空ディレクトリは zip に残らない。中身のあるファイルを置いて確実に配布物へ含める。
# これが欠けると collector が起動時に落ち続ける(v1.2.9 で発生)。
New-Item -ItemType Directory -Path (Join-Path $Pkg "app\collector\storage\tmp") -Force | Out-Null
Set-Content -Path (Join-Path $Pkg "app\collector\storage\tmp\.placeholder") -Value ""
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
Write-Host "  bundling: $RerankerModelName ONNX int8"
# Build the path segment by segment. Avoid -replace here: its replacement string
# treats backslash as an escape character, which is easy to get wrong and would
# only fail on the build machine.
$rerankerOut = Join-Path $Pkg "app\server\storage\models"
foreach ($seg in $RerankerModelName.Split('/')) { $rerankerOut = Join-Path $rerankerOut $seg }
robocopy $RerankerModelDir $rerankerOut /E /NFL /NDL /NJH /NJS | Out-Null
if ($LASTEXITCODE -ge 8) { Write-Host "ERROR: robocopy reranker failed ($LASTEXITCODE)"; exit 1 }
$global:LASTEXITCODE = 0

# OCR言語データ。tesseract.js は langPath 未指定だと jsdelivr の CDN から
# 取得するため、完全オフライン環境ではスキャンPDFの取り込みが失敗する。
# OCRLoader の cacheDir (=STORAGE_DIR\models\tesseract) へ同梱する。
# gzip:false で読むので拡張子は .traineddata（.gz ではない）。
Write-Host "  bundling: tesseract OCR language data (jpn, eng)"
$tessSrc = Join-Path $PSScriptRoot "assets\tesseract"
$tessOut = Join-Path $Pkg "app\server\storage\models\tesseract"
foreach ($tessFile in @("jpn.traineddata", "eng.traineddata")) {
    Assert-Path (Join-Path $tessSrc $tessFile) "OCR language data $tessFile"
}
robocopy $tessSrc $tessOut /E /NFL /NDL /NJH /NJS | Out-Null
if ($LASTEXITCODE -ge 8) { Write-Host "ERROR: robocopy tesseract failed ($LASTEXITCODE)"; exit 1 }
$global:LASTEXITCODE = 0

# --- 5. scripts / config / fixtures / docs / licenses ---
Write-Host "[5/7] Copying install scripts, config templates, fixtures, docs, licenses..."
foreach ($f in @("Install-OTE-RAG.cmd", "install.ps1", "uninstall.ps1", "Uninstall-OTE-RAG.cmd", "start.ps1", "stop.ps1", "backup.ps1", "restore.ps1", "rag-e2e-test.ps1")) {
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
    # 🔴 顧客に配ってよいものだけを入れる。
    #   CODEX_ONEPAGER_BRIEF.md は Codex への作図指示書＝開発者向け。
    #   onepagers\*.svg は v1.1.0 / Qwen3-8B 時代の作図で、モデル名も VRAM 要件も
    #   現行と食い違う（2026-08-05 のレビューで検出）。作り直すまで同梱しない。
    #   v1.2.8 でも「開発者向け README が顧客に届く」同型の指摘を受けている。
    robocopy (Join-Path $repoRoot "docs\customer-windows") (Join-Path $Pkg "docs") /E /NFL /NDL /NJH /NJS `
        /XF CODEX_ONEPAGER_BRIEF.md /XD onepagers | Out-Null
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
    "reranker=$RerankerModelName (int8)",
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

