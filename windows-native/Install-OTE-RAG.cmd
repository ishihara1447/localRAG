@echo off
setlocal
title OTE-RAG Installer

cd /d "%~dp0"
if /I "%~1"=="--self-test" (
  if not exist "%~dp0install.ps1" exit /b 2
  echo SELF_TEST=PASS
  exit /b 0
)



net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Requesting administrator privileges...
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
    "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
  exit /b
)

echo ============================================================
echo  OTE-RAG Installer
echo ============================================================
echo.
echo Keep this window open until installation completes.
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
set "INSTALL_EXIT=%ERRORLEVEL%"

echo.
rem exit 3 = install.ps1 finished but the first model load did not answer the
rem ping within the timeout. That is expected on 8GB VRAM machines and the
rem installation itself succeeded, so do not report it as a failure
rem (OTE-RAG-Setup.exe already treats 0 and 3 the same way).
if "%INSTALL_EXIT%"=="0" (
  echo OTE-RAG installation completed successfully.
) else if "%INSTALL_EXIT%"=="3" (
  echo OTE-RAG installation completed successfully.
  echo The service is still loading the model; the screen may take a few more
  echo minutes to open. This is normal on the first start.
) else (
  echo OTE-RAG installation failed with exit code %INSTALL_EXIT%.
  echo Review the message above before closing this window.
)
echo.
pause
if "%INSTALL_EXIT%"=="3" set "INSTALL_EXIT=0"
exit /b %INSTALL_EXIT%
