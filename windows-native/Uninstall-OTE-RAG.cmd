@echo off
chcp 65001 >nul
title OTE-RAG Uninstall
:: =====================================================================
:: OTE-RAG double-click uninstaller (self-elevating)
::
:: uninstall.ps1 と同じフォルダに置いて使う。サービスの登録解除には管理者権限が
:: 必要なため、非管理者で起動された場合は UAC で自動的に昇格して再実行する。
:: ダブルクリックだけでアンインストールできる(ユーザー向け)。
:: =====================================================================

:: --- 管理者権限チェック → 非管理者なら自己昇格(UAC) ---
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo 管理者権限が必要です。UAC の確認画面で「はい」を選択してください...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

set "PS1=%~dp0uninstall.ps1"
if not exist "%PS1%" (
    echo [ERROR] uninstall.ps1 が見つかりません: %PS1%
    echo このファイルは OTE-RAG のインストール先フォルダに置いて実行してください。
    echo.
    pause
    exit /b 1
)

echo ============================================================
echo   OTE-RAG アンインストール
echo   インストール先: %~dp0
echo ============================================================
echo.
echo   Y = 完全削除(文書・ベクトル・モデルも削除)
echo   N = データを残す(文書/ベクトルは ProgramData に退避)
echo.
choice /C YN /N /M "完全に削除しますか? [Y/N]: "
if errorlevel 2 goto keepdata

echo.
echo [完全削除] データ・モデルも含めて削除します...
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -RemoveData
goto done

:keepdata
echo.
echo [データ保持] 文書/ベクトルは C:\ProgramData\LocalRAG\uninstalled-^<日付^> に退避します...
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
goto done

:done
echo.
echo アンインストールが完了しました。このウィンドウを閉じてください。
pause
