# start.ps1 - Start the LocalRAG services (dependencies first).
$ErrorActionPreference = "Stop"
foreach ($svc in @("LocalRAG-Ollama", "LocalRAG-Collector", "LocalRAG-Server")) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if (-not $s) { Write-Host "ERROR: service $svc not found. Run install.ps1 first."; exit 1 }
    if ($s.Status -ne "Running") {
        Write-Host "Starting $svc ..."
        Start-Service -Name $svc
    }
}
Get-Service -Name "LocalRAG-*" | Format-Table -AutoSize Name, Status
Write-Host "LocalRAG started. UI port: see SERVER_PORT in app\server\.env (default 3001)."
