@echo off
REM Join-And-Install.cmd - company-PC one double-click launcher.
REM Self-elevates via UAC, then joins the downloaded parts, verifies, and installs.
REM Run this from the folder that also contains join-and-install.ps1, OR pass
REM -PartsDir to point at where you downloaded the LocalRAG-win64-v1.1.0.zip.part* files.
REM   Example: Join-And-Install.cmd -PartsDir C:\Users\me\Downloads

net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Requesting administrator privileges...
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
  exit /b
)

echo Running as administrator.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0join-and-install.ps1" %*
echo.
pause
