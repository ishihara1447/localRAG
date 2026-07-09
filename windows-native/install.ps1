# install.ps1 - Install LocalRAG (Windows native, fully offline) from this package.
#
# Run from the extracted package root, in an elevated (Administrator) PowerShell:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -InstallRoot D:\LocalRAG -ServerPort 3001
#
# What it does:
#   preflight checks -> checksum verification -> copy files -> generate .env ->
#   prisma migrate -> register+start Windows services -> ping check.
# Data layout after install:
#   <InstallRoot>\app\server\storage   (documents, vectors, sqlite DB)
#   <InstallRoot>\app\collector\hotdir (upload staging)
#   C:\ProgramData\LocalRAG\models     (LLM/embedding models)
#   C:\ProgramData\LocalRAG\logs       (service logs)

param(
    [string]$InstallRoot = "C:\LocalRAG",
    [int]$ServerPort = 3001,
    [switch]$SkipChecksum,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$PkgRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataRoot = "C:\ProgramData\LocalRAG"

function Fail([string]$msg) { Write-Host "ERROR: $msg"; exit 1 }
function Info([string]$msg) { Write-Host $msg }

Write-Host "=== LocalRAG Windows native installer ==="

# =====================================================================
# Preflight
# =====================================================================
Info "[preflight] Checking environment..."

# Admin
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail "run this script from an elevated (Administrator) PowerShell."
}

# OS version (Windows 10 21H2+ / 11)
$build = [System.Environment]::OSVersion.Version.Build
if ($build -lt 19044) { Fail "Windows build $build is too old. Windows 11 (or Windows 10 21H2+) is required." }

# GPU via nvidia-smi
$nvidiaSmi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if (-not $nvidiaSmi) {
    $default = "$env:SystemRoot\System32\nvidia-smi.exe"
    if (Test-Path $default) { $nvidiaSmi = $default } else {
        Fail "nvidia-smi not found. An NVIDIA GPU with a recent driver is required."
    }
} else { $nvidiaSmi = $nvidiaSmi.Source }
try {
    $vramMiB = [int]((& $nvidiaSmi --query-gpu=memory.total --format=csv,noheader,nounits | Select-Object -First 1).Trim())
} catch { Fail "nvidia-smi failed. Check the NVIDIA driver installation." }
Info "  GPU VRAM: $vramMiB MiB"
if ($vramMiB -lt 15000) {
    Write-Host "WARN: less than 16GB VRAM detected. LocalRAG is validated on RTX 5070 Ti (16GB) class GPUs."
    if (-not $Force) { Fail "re-run with -Force to install anyway (unsupported configuration)." }
}

# Disk space (>= 20GB free on the InstallRoot drive)
$drive = (Split-Path -Qualifier ([System.IO.Path]::GetFullPath($InstallRoot))).TrimEnd(":")
$freeGB = [math]::Round((Get-PSDrive $drive).Free / 1GB, 1)
Info "  Free space on drive ${drive}: $freeGB GB"
if ($freeGB -lt 20) { Fail "at least 20GB free disk space is required on drive $drive." }

# Ports (server / collector / dedicated ollama)
foreach ($port in @($ServerPort, 8888, 11435)) {
    $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    if ($conn) {
        $owner = "unknown"
        try { $owner = (Get-Process -Id $conn[0].OwningProcess -ErrorAction SilentlyContinue).ProcessName } catch {}
        if ($owner -eq "wslrelay") {
            Fail "port $port is held by wslrelay.exe (a WSL2 service is forwarding it). Stop the WSL-side service (e.g. 'wsl --shutdown') or choose another port with -ServerPort."
        }
        Fail "port $port is already in use by process '$owner'. Stop it or choose another port with -ServerPort."
    }
}
Info "  Ports $ServerPort/8888/11435: free"

# Existing installation
if ((Test-Path (Join-Path $InstallRoot "app")) -and -not $Force) {
    Fail "$InstallRoot\app already exists. Uninstall first (uninstall.ps1) or re-run with -Force to overwrite the app (data under app\server\storage is preserved only by backup.ps1 - take a backup first)."
}
$existingSvc = Get-Service -Name "LocalRAG-*" -ErrorAction SilentlyContinue
if ($existingSvc -and -not $Force) {
    Fail "LocalRAG services already exist. Run uninstall.ps1 first."
}

# =====================================================================
# Checksum verification
# =====================================================================
if (-not $SkipChecksum) {
    $checksumFile = Join-Path $PkgRoot "checksums\package.sha256"
    if (-not (Test-Path $checksumFile)) { Fail "checksums\package.sha256 missing. The package is incomplete (use -SkipChecksum only for development)." }
    Info "[checksum] Verifying package integrity (this can take a while)..."
    $bad = 0; $count = 0
    foreach ($line in Get-Content $checksumFile) {
        if ($line -notmatch "^([0-9a-f]{64})\s+(.+)$") { continue }
        $expected = $Matches[1]; $rel = $Matches[2] -replace "/", "\"
        $path = Join-Path $PkgRoot $rel
        if (-not (Test-Path $path)) { Write-Host "  MISSING: $rel"; $bad++; continue }
        $actual = (Get-FileHash -Algorithm SHA256 -Path $path).Hash.ToLower()
        if ($actual -ne $expected) { Write-Host "  MISMATCH: $rel"; $bad++ }
        $count++
    }
    if ($bad -gt 0) { Fail "$bad file(s) failed checksum verification. The package is corrupted." }
    Info "  $count files verified."
}

# =====================================================================
# Copy files
# =====================================================================
Info "[install] Copying application files to $InstallRoot ..."
foreach ($d in @("app", "runtime", "winsw")) {
    robocopy (Join-Path $PkgRoot $d) (Join-Path $InstallRoot $d) /E /NFL /NDL /NJH /NJS | Out-Null
    if ($LASTEXITCODE -ge 8) { Fail "robocopy $d failed ($LASTEXITCODE)" }
}
Copy-Item (Join-Path $PkgRoot "rag-e2e-test.ps1") $InstallRoot -Force
if (Test-Path (Join-Path $PkgRoot "fixtures")) {
    robocopy (Join-Path $PkgRoot "fixtures") (Join-Path $InstallRoot "fixtures") /E /NFL /NDL /NJH /NJS | Out-Null
}
foreach ($f in @("uninstall.ps1", "start.ps1", "stop.ps1", "backup.ps1", "restore.ps1")) {
    Copy-Item (Join-Path $PkgRoot $f) $InstallRoot -Force
}
if (Test-Path (Join-Path $PkgRoot "LICENSES")) {
    robocopy (Join-Path $PkgRoot "LICENSES") (Join-Path $InstallRoot "LICENSES") /E /NFL /NDL /NJH /NJS | Out-Null
}
if (Test-Path (Join-Path $PkgRoot "NOTICE")) { Copy-Item (Join-Path $PkgRoot "NOTICE") $InstallRoot -Force }
if (Test-Path (Join-Path $PkgRoot "docs")) {
    robocopy (Join-Path $PkgRoot "docs") (Join-Path $InstallRoot "docs") /E /NFL /NDL /NJH /NJS | Out-Null
}
if (Test-Path (Join-Path $PkgRoot "versions.lock")) { Copy-Item (Join-Path $PkgRoot "versions.lock") $InstallRoot -Force }
$global:LASTEXITCODE = 0

Info "[install] Copying models to $DataRoot\models ..."
New-Item -ItemType Directory -Path "$DataRoot\models" -Force | Out-Null
New-Item -ItemType Directory -Path "$DataRoot\logs" -Force | Out-Null
robocopy (Join-Path $PkgRoot "models") "$DataRoot\models" /E /NFL /NDL /NJH /NJS | Out-Null
if ($LASTEXITCODE -ge 8) { Fail "robocopy models failed" }
$global:LASTEXITCODE = 0

# Runtime data dirs
New-Item -ItemType Directory -Path (Join-Path $InstallRoot "app\server\storage") -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $InstallRoot "app\collector\hotdir") -Force | Out-Null

# =====================================================================
# Generate .env files from templates
# =====================================================================
Info "[install] Generating .env files..."
function Render-Template([string]$templatePath, [string]$outPath) {
    $content = Get-Content $templatePath -Raw
    $content = $content -replace "\{\{INSTALL_ROOT\}\}", $InstallRoot
    $content = $content -replace "\{\{SERVER_PORT\}\}", "$ServerPort"
    Set-Content -Path $outPath -Value $content -Encoding ascii
}
Render-Template (Join-Path $PkgRoot "config\server.env.template") (Join-Path $InstallRoot "app\server\.env")
Render-Template (Join-Path $PkgRoot "config\collector.env.template") (Join-Path $InstallRoot "app\collector\.env")

# =====================================================================
# Prisma migrate (creates the SQLite DB)
# =====================================================================
Info "[install] Running prisma migrate deploy..."
$node = Join-Path $InstallRoot "runtime\node\node.exe"
$serverDir = Join-Path $InstallRoot "app\server"
$prismaCli = Join-Path $serverDir "node_modules\prisma\build\index.js"
if (-not (Test-Path $prismaCli)) { Fail "prisma CLI not found at $prismaCli" }
Push-Location $serverDir
try {
    & $node $prismaCli migrate deploy --schema=.\prisma\schema.prisma
    if ($LASTEXITCODE -ne 0) { Fail "prisma migrate deploy failed ($LASTEXITCODE)" }
} finally { Pop-Location }

# =====================================================================
# Register + start services
# =====================================================================
Info "[install] Registering Windows services..."
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $InstallRoot "winsw\register-services.ps1")
if ($LASTEXITCODE -ne 0) { Fail "service registration failed" }

# =====================================================================
# Ping check
# =====================================================================
Info "[install] Waiting for the server to come online (max 120s)..."
$ok = $false
for ($i = 0; $i -lt 24; $i++) {
    Start-Sleep -Seconds 5
    try {
        $ping = & curl.exe -s --max-time 5 "http://localhost:$ServerPort/api/ping"
        if ($ping -match '"online"\s*:\s*true') { $ok = $true; break }
    } catch {}
}
if (-not $ok) {
    Write-Host "WARN: server did not respond on http://localhost:$ServerPort/api/ping within 120s."
    Write-Host "      Check service state (Get-Service LocalRAG-*) and logs under $DataRoot\logs"
    exit 1
}

Write-Host ""
Write-Host "=== Install complete ==="
Write-Host "UI:            http://localhost:$ServerPort"
Write-Host "Services:      LocalRAG-Server / LocalRAG-Collector / LocalRAG-Ollama (automatic start)"
Write-Host "Data:          $InstallRoot\app\server\storage"
Write-Host "Logs:          $DataRoot\logs"
Write-Host "E2E test:      set LOCALRAG_API_KEY and run rag-e2e-test.ps1 (see docs)"
