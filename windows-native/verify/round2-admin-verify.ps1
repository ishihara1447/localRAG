# round2-admin-verify.ps1 - Round 2 admin verification runner (docs/CODEX_WINDOWS_NATIVE_VERIFY_ROUND2_2026-07-10.md).
# Authored by Codex (2026-07-10), reviewed and version-controlled by Claude Code.
# MUST run elevated. Use Run-Round2-Verify.cmd for one-click UAC elevation.
# Does the whole B2 flow end to end: tar extract -> install -> ping/logs ->
# API key -> GPU state (before/after E2E) -> E2E (PS5.1, pwsh fallback) ->
# backup/stop/start -> uninstall (data-preserve check) -> cleanup.
# Outputs: C:\Temp\localrag-round2-logs\round2-admin-*.{transcript.txt,summary.json}
#          and a copy of the service logs.
# -KeepProgramData keeps C:\ProgramData\LocalRAG (models/logs/preserved data) after the run.
param(
    [string]$ZipPath = "C:\LocalRAG\dist\LocalRAG-win64-v1.0.0.zip",
    [string]$VerifyRoot = "C:\Temp\localrag-verify",
    [string]$InstallRoot = "C:\LocalRAGProd",
    [int]$ServerPort = 3005,
    [switch]$KeepProgramData
)

$ErrorActionPreference = "Continue"
$LogRoot = "C:\Temp\localrag-round2-logs"
New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$TranscriptPath = Join-Path $LogRoot "round2-admin-$Stamp.transcript.txt"
$SummaryPath = Join-Path $LogRoot "round2-admin-$Stamp.summary.json"
$ServiceLogCopy = Join-Path $LogRoot "service-logs-$Stamp"
$StepResults = New-Object System.Collections.Generic.List[object]

function Add-StepResult([string]$Name, [string]$Status, [string]$Detail = "") {
    $StepResults.Add([pscustomobject]@{
        name = $Name
        status = $Status
        detail = $Detail
        at = (Get-Date).ToString("s")
    }) | Out-Null
    Write-Host "STEP[$Status] $Name $Detail"
}

function Run-External([string]$Name, [scriptblock]$Block, [switch]$ContinueOnError) {
    Write-Host ""
    Write-Host "==== $Name ===="
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & $Block
        $code = if ($global:LASTEXITCODE -is [int]) { $global:LASTEXITCODE } else { 0 }
        $sw.Stop()
        if ($code -eq 0) {
            Add-StepResult $Name "OK" "elapsed=$($sw.Elapsed)"
            return $true
        }
        Add-StepResult $Name "NG" "exit=$code elapsed=$($sw.Elapsed)"
        if (-not $ContinueOnError) { throw "$Name failed with exit $code" }
        return $false
    } catch {
        $sw.Stop()
        Add-StepResult $Name "NG" "error=$($_.Exception.Message) elapsed=$($sw.Elapsed)"
        if (-not $ContinueOnError) { throw }
        return $false
    } finally {
        $global:LASTEXITCODE = 0
    }
}

function CurlText([string[]]$Args) {
    $out = & curl.exe -s @Args 2>$null
    if ($out -is [array]) { return ($out -join "`n") }
    return [string]$out
}

function Write-Section([string]$Title) {
    Write-Host ""
    Write-Host "######## $Title ########"
}

Start-Transcript -Path $TranscriptPath -Force | Out-Null
try {
    Write-Section "B2 Round2 Admin Verification"
    Write-Host "started=$(Get-Date -Format o)"
    Write-Host "ZipPath=$ZipPath"
    Write-Host "VerifyRoot=$VerifyRoot"
    Write-Host "InstallRoot=$InstallRoot"
    Write-Host "ServerPort=$ServerPort"
    Write-Host "LogRoot=$LogRoot"

    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Write-Host "admin=$admin user=$([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    if (-not $admin) { throw "This runner must be executed from an elevated Administrator PowerShell." }
    Add-StepResult "B2-0 admin" "OK" "administrator=True"

    if (-not (Test-Path $ZipPath)) { throw "zip not found: $ZipPath" }
    Write-Host "zip_bytes=$((Get-Item $ZipPath).Length)"

    Write-Section "Initial State"
    Get-Service -Name "LocalRAG-*" -ErrorAction SilentlyContinue | Format-Table -AutoSize Name,Status,StartType
    Get-NetTCPConnection -LocalPort $ServerPort,8888,11435 -State Listen -ErrorAction SilentlyContinue | ForEach-Object {
        $owner = "unknown"
        try { $owner = (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName } catch {}
        Write-Host ("port {0} -> {1}({2})" -f $_.LocalPort, $owner, $_.OwningProcess)
    }

    Write-Section "B2-1 cleanup and tar extraction"
    if (Test-Path (Join-Path $InstallRoot "uninstall.ps1")) {
        Run-External "pre-clean existing uninstall" { powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $InstallRoot "uninstall.ps1") } -ContinueOnError | Out-Null
    }
    Remove-Item -Recurse -Force "C:\Temp\localrag-install" -ErrorAction Continue
    Remove-Item -Recurse -Force $VerifyRoot -ErrorAction Continue
    Remove-Item -Recurse -Force $InstallRoot -ErrorAction Continue
    New-Item -ItemType Directory -Path $VerifyRoot -Force | Out-Null
    Push-Location $VerifyRoot
    $extractSw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & tar.exe -xf $ZipPath
        if ($LASTEXITCODE -ne 0) { throw "tar.exe failed with exit $LASTEXITCODE" }
    } finally {
        Pop-Location
        $extractSw.Stop()
        $global:LASTEXITCODE = 0
    }
    $PkgRoot = Join-Path $VerifyRoot "LocalRAG-win64-v1.0.0"
    if (-not (Test-Path (Join-Path $PkgRoot "install.ps1"))) { throw "install.ps1 not found after extract: $PkgRoot" }
    Add-StepResult "B2-1 tar extract" "OK" "elapsed=$($extractSw.Elapsed)"

    Write-Section "B2-2 install"
    Push-Location $PkgRoot
    $installSw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -InstallRoot $InstallRoot -ServerPort $ServerPort
        if ($LASTEXITCODE -ne 0) { throw "install.ps1 failed with exit $LASTEXITCODE" }
    } finally {
        Pop-Location
        $installSw.Stop()
        $global:LASTEXITCODE = 0
    }
    Add-StepResult "B2-2 install" "OK" "elapsed=$($installSw.Elapsed)"

    Write-Section "Post-install service and UI checks"
    Get-Service -Name "LocalRAG-*" | Format-Table -AutoSize Name,Status,StartType
    $ping = CurlText @("--max-time", "10", "http://localhost:$ServerPort/api/ping")
    Write-Host "ping=$ping"
    if ($ping -match '"online"\s*:\s*true') { Add-StepResult "B2-2 api ping" "OK" $ping } else { Add-StepResult "B2-2 api ping" "NG" $ping }
    Get-ChildItem "C:\ProgramData\LocalRAG\logs" -ErrorAction SilentlyContinue | Select-Object Name,Length,LastWriteTime | Format-Table -AutoSize

    Write-Section "API key generation"
    $BaseUrl = "http://localhost:$ServerPort"
    $keyRaw = CurlText @("--max-time", "30", "-X", "POST", "-H", "Content-Type: application/json", "-d", '{"name":"codex-round2"}', "$BaseUrl/api/system/generate-api-key")
    Write-Host "generate_api_key_raw=$keyRaw"
    $apiKeyJson = $null
    try { $apiKeyJson = $keyRaw | ConvertFrom-Json } catch {}
    $ApiKey = if ($apiKeyJson -and $apiKeyJson.apiKey) { [string]$apiKeyJson.apiKey.secret } else { "" }
    $ApiKeyId = if ($apiKeyJson -and $apiKeyJson.apiKey) { [string]$apiKeyJson.apiKey.id } else { "" }
    if (-not $ApiKey) { Add-StepResult "API key generation" "NG" "secret missing"; throw "API key generation failed" }
    Add-StepResult "API key generation" "OK" "id=$ApiKeyId"

    Write-Section "B2-3 GPU state before E2E"
    $ollamaBefore = CurlText @("--max-time", "10", "http://127.0.0.1:11435/api/ps")
    Write-Host "ollama_api_ps_before=$ollamaBefore"

    Write-Section "B2-4 E2E with Windows PowerShell 5.1"
    Push-Location $InstallRoot
    $env:LOCALRAG_API_KEY = $ApiKey
    $env:LOCALRAG_BASE_URL = $BaseUrl
    $e2eSw = [System.Diagnostics.Stopwatch]::StartNew()
    $e2eOk = $false
    try {
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\rag-e2e-test.ps1
        $e2eExit = $LASTEXITCODE
        $e2eSw.Stop()
        if ($e2eExit -eq 0) { $e2eOk = $true; Add-StepResult "B2-4 E2E PS5.1" "OK" "elapsed=$($e2eSw.Elapsed)" }
        else { Add-StepResult "B2-4 E2E PS5.1" "NG" "exit=$e2eExit elapsed=$($e2eSw.Elapsed)" }
    } finally {
        Pop-Location
        $global:LASTEXITCODE = 0
    }
    if (-not $e2eOk) {
        Write-Section "B2-4 E2E fallback with pwsh"
        Push-Location $InstallRoot
        $e2ePwshSw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            & "C:\Program Files\PowerShell\7\pwsh.exe" -NoProfile -ExecutionPolicy Bypass -File .\rag-e2e-test.ps1
            $pwshExit = $LASTEXITCODE
            $e2ePwshSw.Stop()
            if ($pwshExit -eq 0) { Add-StepResult "B2-4 E2E pwsh fallback" "OK" "elapsed=$($e2ePwshSw.Elapsed)" }
            else { Add-StepResult "B2-4 E2E pwsh fallback" "NG" "exit=$pwshExit elapsed=$($e2ePwshSw.Elapsed)" }
        } finally {
            Pop-Location
            $global:LASTEXITCODE = 0
        }
    }

    Write-Section "B2-3 GPU state after E2E"
    $ollamaAfter = CurlText @("--max-time", "10", "http://127.0.0.1:11435/api/ps")
    Write-Host "ollama_api_ps_after=$ollamaAfter"
    if ($ollamaAfter -match "GPU") { Add-StepResult "B2-3 GPU" "OK" "api/ps mentions GPU" } else { Add-StepResult "B2-3 GPU" "WARN" "api/ps did not mention GPU" }

    Write-Section "Delete generated API key"
    if ($ApiKeyId) {
        $deleteRaw = CurlText @("--max-time", "30", "-X", "DELETE", "$BaseUrl/api/system/api-key/$ApiKeyId")
        Write-Host "delete_api_key_raw=$deleteRaw"
    }

    Write-Section "B2-5 backup / stop / start"
    Push-Location $InstallRoot
    try {
        Run-External "B2-5 backup" { powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\backup.ps1 } -ContinueOnError | Out-Null
        Get-ChildItem "C:\ProgramData\LocalRAG\backups" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 3 Name,Length,LastWriteTime | Format-Table -AutoSize
        Run-External "B2-5 stop" { powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\stop.ps1 } -ContinueOnError | Out-Null
        Run-External "B2-5 start" { powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\start.ps1 } -ContinueOnError | Out-Null
    } finally {
        Pop-Location
        $global:LASTEXITCODE = 0
    }
    Start-Sleep -Seconds 5
    $pingAfterRestart = CurlText @("--max-time", "10", "http://localhost:$ServerPort/api/ping")
    Write-Host "ping_after_restart=$pingAfterRestart"
    if ($pingAfterRestart -match '"online"\s*:\s*true') { Add-StepResult "B2-5 ping after restart" "OK" $pingAfterRestart } else { Add-StepResult "B2-5 ping after restart" "NG" $pingAfterRestart }

    Write-Section "B2-6 reboot resilience"
    Add-StepResult "B2-6 reboot resilience" "SKIP" "Windows reboot not performed by runner"

    Write-Section "Copy service logs before uninstall"
    if (Test-Path "C:\ProgramData\LocalRAG\logs") {
        New-Item -ItemType Directory -Path $ServiceLogCopy -Force | Out-Null
        Copy-Item "C:\ProgramData\LocalRAG\logs\*" $ServiceLogCopy -Force -ErrorAction Continue
        Get-ChildItem $ServiceLogCopy -ErrorAction SilentlyContinue | Select-Object Name,Length,LastWriteTime | Format-Table -AutoSize
    }

    Write-Section "B2-7 uninstall"
    Push-Location $InstallRoot
    try {
        Run-External "B2-7 uninstall" { powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1 } -ContinueOnError | Out-Null
    } finally {
        Pop-Location
        $global:LASTEXITCODE = 0
    }
    $remainingServices = @(Get-Service -Name "LocalRAG-*" -ErrorAction SilentlyContinue)
    Write-Host "remaining_services_count=$($remainingServices.Count)"
    $preserved = Get-ChildItem "C:\ProgramData\LocalRAG" -Directory -Filter "uninstalled-*" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($preserved) { Write-Host "preserved_data=$($preserved.FullName)" }
    if ($remainingServices.Count -eq 0 -and $preserved) { Add-StepResult "B2-7 uninstall state" "OK" "preserved=$($preserved.FullName)" } else { Add-StepResult "B2-7 uninstall state" "NG" "services=$($remainingServices.Count) preserved=$($preserved.FullName)" }

    Write-Section "B2-8 cleanup"
    Remove-Item -Recurse -Force $VerifyRoot -ErrorAction Continue
    Remove-Item -Recurse -Force "C:\Temp\localrag-install" -ErrorAction Continue
    if (-not $KeepProgramData) {
        Remove-Item -Recurse -Force "C:\ProgramData\LocalRAG" -ErrorAction Continue
    }
    Add-StepResult "B2-8 cleanup" "OK" "verify removed; ProgramData kept=$KeepProgramData"
}
catch {
    Write-Host "FATAL: $($_.Exception.Message)"
    Add-StepResult "fatal" "NG" $_.Exception.Message
}
finally {
    Write-Section "Final state"
    Get-Service -Name "LocalRAG-*" -ErrorAction SilentlyContinue | Format-Table -AutoSize Name,Status,StartType
    Write-Host "InstallRootExists=$(Test-Path $InstallRoot)"
    Write-Host "ProgramDataExists=$(Test-Path 'C:\ProgramData\LocalRAG')"
    $summary = [pscustomobject]@{
        startedAt = $Stamp
        finishedAt = (Get-Date).ToString("s")
        transcript = $TranscriptPath
        serviceLogCopy = $ServiceLogCopy
        steps = @($StepResults)
    }
    $summary | ConvertTo-Json -Depth 6 | Set-Content -Path $SummaryPath -Encoding UTF8
    Write-Host "summary=$SummaryPath"
    Write-Host "transcript=$TranscriptPath"
    Stop-Transcript | Out-Null
}
