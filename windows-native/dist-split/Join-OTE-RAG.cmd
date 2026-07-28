@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul
title OTE-RAG 分割ファイルの結合

rem ============================================================
rem  OTE-RAG 分割配布ファイルの結合ツール
rem
rem  このフォルダに揃っているべきもの:
rem    OTE-RAG-win64-vX.Y.Z.zip.001 〜 .00N
rem    MANIFEST.txt
rem    OTE-RAG-Setup.exe
rem    このファイル (Join-OTE-RAG.cmd)
rem
rem  ダブルクリックで実行してください。管理者権限は不要です。
rem  Windows標準機能のみで動くため、7-Zipが無くても使えます。
rem
rem  7-Zipが入っている場合は、.001 を右クリック > 7-Zip > 展開 でも
rem  結合できます（.001形式は7-Zipが分割書庫として自動認識します）。
rem ============================================================

echo.
echo   OTE-RAG 分割ファイルの結合
echo   ==========================
echo.

rem --- パートを探す -------------------------------------------------
set "ZIPNAME="
for %%F in ("%~dp0*.zip.001") do (
    set "ZIPNAME=%%~nF"
)
if not defined ZIPNAME (
    echo   [エラー] 分割ファイル ^(*.zip.001^) が見つかりません。
    echo.
    echo   すべてのパートをこのフォルダに置いてから、もう一度実行してください。
    echo.
    pause
    exit /b 1
)

echo   対象: %ZIPNAME%
echo.

rem --- パート数を数える ---------------------------------------------
set /a COUNT=0
for %%F in ("%~dp0%ZIPNAME%.[0-9][0-9][0-9]") do set /a COUNT+=1
echo   見つかったパート: %COUNT% 個
echo.

rem --- 結合リストを作る（part00 から順に）---------------------------
set "LIST="
for /f "delims=" %%F in ('dir /b /on "%~dp0%ZIPNAME%.[0-9][0-9][0-9]"') do (
    if defined LIST (set "LIST=!LIST!+%%F") else (set "LIST=%%F")
)

echo   結合しています。10GB前後あるため数分かかります...
echo.
pushd "%~dp0"
copy /b %LIST% "%ZIPNAME%" >nul
set RC=%ERRORLEVEL%
popd

if not "%RC%"=="0" (
    echo   [エラー] 結合に失敗しました ^(コード %RC%^)。
    echo   ディスクの空き容量を確認してください ^(結合後の分だけ追加で必要です^)。
    echo.
    pause
    exit /b 1
)

echo   結合できました: %ZIPNAME%
echo.

rem --- SHA-256 で検証 ------------------------------------------------
echo   ファイルが壊れていないか確認しています...
echo.
for /f "tokens=2 delims=:" %%H in ('findstr /c:"# 元SHA-256" "%~dp0MANIFEST.txt"') do (
    set "EXPECTED=%%H"
)
set "EXPECTED=%EXPECTED: =%"

for /f "skip=1 tokens=1" %%H in ('certutil -hashfile "%~dp0%ZIPNAME%" SHA256 ^| findstr /v ":"') do (
    if not defined ACTUAL set "ACTUAL=%%H"
)

if /i "%ACTUAL%"=="%EXPECTED%" (
    echo   [OK] ハッシュが一致しました。ファイルは正常です。
    echo.
    echo   ------------------------------------------------------
    echo    次の手順:
    echo      1. このフォルダの OTE-RAG-Setup.exe を
    echo         右クリック ^> 管理者として実行
    echo      2. 「WindowsによってPCが保護されました」と出たら
    echo         「詳細情報」^> 「実行」を押してください
    echo         ^(コード署名証明書が無いため出ます^)
    echo   ------------------------------------------------------
    echo.
    echo   結合前の分割ファイルは削除して構いません。
) else (
    echo   [エラー] ハッシュが一致しません。ダウンロードが不完全な可能性があります。
    echo.
    echo     期待値: %EXPECTED%
    echo     実際  : %ACTUAL%
    echo.
    echo   すべてのパートを再ダウンロードして、もう一度実行してください。
    echo   ^(MANIFEST.txt に各パートのハッシュもあります^)
    del "%~dp0%ZIPNAME%" 2>nul
)

echo.
pause
