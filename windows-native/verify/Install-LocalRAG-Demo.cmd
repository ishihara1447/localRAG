@echo off
REM Install-LocalRAG-Demo.cmd - one double-click launcher for a hands-on install.
REM Self-elevates via UAC, then extracts + installs v1.1.0 and LEAVES IT RUNNING
REM (does NOT uninstall, unlike Run-Round2-Verify.cmd).
REM Extra args are forwarded (e.g. -ServerPort 3006, -Force).

net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Requesting administrator privileges...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
  exit /b
)

echo Running as administrator.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-demo.ps1" %*
echo.
echo ==== Done. If it succeeded, open http://localhost:3005 in your browser. ====
pause
