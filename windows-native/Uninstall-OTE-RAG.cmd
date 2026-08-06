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

:: --- 完全削除は破壊的なので二段確認する ---
echo.
echo [警告] 文書・ベクトル・モデルをすべて削除します。この操作は元に戻せません。
choice /C YN /N /M "本当に文書・ベクトル・モデルまで削除しますか? [Y/N]: "
if errorlevel 2 goto keepdata

echo.
echo [完全削除] データ・モデルも含めて削除しています...
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -RemoveData
set "RC=%errorlevel%"
goto check

:keepdata
echo.
echo [データ保持] 文書/ベクトルは C:\ProgramData\LocalRAG\uninstalled-^<日付^> に退避します...
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
set "RC=%errorlevel%"
goto check

:check
echo.
rem 終了コード 4 = サービスの削除が Windows 側で保留されている。
rem 再実行しても同じ結果になるので「もう一度実行」と案内してはいけない。
if "%RC%"=="4" (
    echo アンインストールは完了しましたが、サービスの削除が Windows 側で保留されています。
    echo PC を再起動すると削除が完了します。
    echo 再インストールする場合は、再起動してから実行してください。
) else if not "%RC%"=="0" (
    echo [エラー] アンインストール中に問題が発生しました^(終了コード %RC%^)。
    echo         ログ: C:\ProgramData\LocalRAG\logs
    echo         お手数ですが、もう一度実行するか、サポートにお問い合わせください。
) else (
    echo アンインストールが完了しました。このウィンドウを閉じてください。
)
pause
