@echo off
REM Run-Round2-Verify.cmd - one double-click launcher for the Round 2 admin verification.
REM Self-elevates via UAC, then runs round2-admin-verify.ps1 sitting next to it.
REM Any extra args are forwarded to the ps1 (e.g. -KeepProgramData, -ServerPort 3006).

net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Requesting administrator privileges...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
  exit /b
)

echo Running as administrator.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0round2-admin-verify.ps1" %*
echo.
echo ==== Verification finished. Results are under C:\Temp\localrag-round2-logs ====
pause
