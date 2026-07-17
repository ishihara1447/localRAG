# build-setup.ps1 - Build the OTE-RAG GUI bootstrapper without external tools.

param(
    [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $OutputPath) {
    $OutputPath = Join-Path $ScriptDir "OTE-RAG-Setup.exe"
}

$cscCandidates = @(
    "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "$env:SystemRoot\Microsoft.NET\Framework\v4.0.30319\csc.exe"
)
$csc = $cscCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $csc) {
    throw "Windows .NET Framework C# compiler was not found."
}

$source = Join-Path $ScriptDir "OTE-RAG-Setup.cs"
$icon = Join-Path (Split-Path -Parent $ScriptDir) "launcher\LocalRAG.ico"
if (-not (Test-Path $source)) { throw "Setup source not found: $source" }
if (-not (Test-Path $icon)) { throw "Setup icon not found: $icon" }

$parent = Split-Path -Parent ([System.IO.Path]::GetFullPath($OutputPath))
New-Item -ItemType Directory -Path $parent -Force | Out-Null
if (Test-Path $OutputPath) { Remove-Item -LiteralPath $OutputPath -Force }

$compilerArgs = @(
    "/nologo",
    "/target:winexe",
    "/platform:anycpu",
    "/optimize+",
    "/debug-",
    "/out:$OutputPath",
    "/win32icon:$icon",
    "/reference:System.dll",
    "/reference:System.Core.dll",
    "/reference:System.Drawing.dll",
    "/reference:System.Windows.Forms.dll",
    $source
)

& $csc @compilerArgs
if ($LASTEXITCODE -ne 0) {
    throw "OTE-RAG Setup compilation failed with exit code $LASTEXITCODE."
}

$built = Get-Item -LiteralPath $OutputPath
Write-Host "Setup built: $($built.FullName) ($($built.Length) bytes)"
