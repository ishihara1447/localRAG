# stop.ps1 - Stop the LocalRAG services (server first, then dependencies).
$ErrorActionPreference = "Stop"
foreach ($svc in @("LocalRAG-Server", "LocalRAG-Collector", "LocalRAG-Ollama")) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($s -and $s.Status -eq "Running") {
        Write-Host "Stopping $svc ..."
        Stop-Service -Name $svc -Force
    }
}
Get-Service -Name "LocalRAG-*" -ErrorAction SilentlyContinue | Format-Table -AutoSize Name, Status
Write-Host "LocalRAG stopped."
