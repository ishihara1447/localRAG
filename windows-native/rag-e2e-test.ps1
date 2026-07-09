# rag-e2e-test.ps1 - RAG パイプラインの End-to-End 検証 (Windows native 版)
#
# scripts/rag-e2e-test.sh の PowerShell 移植。検証項目・合否判定は bash 版と同一:
#   fixtures/test-policy.txt をアップロード → embedding → 出典付き回答 →
#   日本語CID PDF / DOCX の取り込み → 文書外質問で「不明」応答 →
#   外部LLM provider拒否 → Swagger docs 無効
#
# 使い方:
#   $env:LOCALRAG_API_KEY = "<APIキー>"
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\rag-e2e-test.ps1
#
# 前提: AnythingLLM(server/collector) と Ollama が Windows native で起動済み。
#       HTTP呼び出しは Windows 10+ 標準の curl.exe を使用 (bash版と挙動を揃えるため)。
#
# 注意: WORKSPACE_DELETION_PROTECTION=1 が有効な環境では、テスト後の
#       ワークスペース削除が失敗して残り続ける(仕様)。不要ならUIから手動削除。
#
# エンコーディング: このファイルは UTF-8 BOM 付きで保存すること。
#       BOM が無いと Windows PowerShell 5.1 が日本語を誤解釈し parser error になる
#       (PoC 2026-07-09 課題#1)。PowerShell 7 (pwsh) は BOM 無しでも動くが、
#       5.1 互換のため BOM を維持する。

$ErrorActionPreference = "Continue"
# $env:LOCALRAG_BASE_URL で上書き可能 (PoC環境=http://localhost:3002 等)
$BaseUrl = if ($env:LOCALRAG_BASE_URL) { $env:LOCALRAG_BASE_URL } else { "http://localhost:3001" }
$ApiKey = $env:LOCALRAG_API_KEY
$WsName = "localrag-smoketest"
$TimeoutSec = 180

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# fixture の場所 (windows-native\..\fixtures または カレント直下 fixtures)
function Find-Fixture([string]$name) {
    foreach ($cand in @(
        (Join-Path $ScriptDir "fixtures\$name"),
        (Join-Path $ScriptDir "..\fixtures\$name"),
        "C:\LocalRAG\fixtures\$name"
    )) {
        if (Test-Path $cand) { return (Resolve-Path $cand).Path }
    }
    return $null
}

$Fixture     = Find-Fixture "test-policy.txt"
$PdfFixture  = Find-Fixture "test-expense.pdf"
$DocxFixture = Find-Fixture "test-attendance.docx"

$script:PassCount = 0
$script:FailCount = 0
function Pass([string]$msg) { Write-Host "  [PASS] $msg"; $script:PassCount++ }
function Fail([string]$msg) { Write-Host "  [FAIL] $msg"; $script:FailCount++ }

function Invoke-Api {
    param([string[]]$CurlArgs)
    # curl.exe を使う (PowerShell の curl エイリアスではない点に注意)
    $out = & curl.exe -s @CurlArgs 2>$null
    if ($out -is [array]) { $out = $out -join "`n" }
    return [string]$out
}

function Parse-Json([string]$raw) {
    try { return $raw | ConvertFrom-Json } catch { return $null }
}

Write-Host "=== LocalRAG RAG E2E テスト (Windows native) ==="

# --- 前提チェック ---
if (-not $ApiKey) {
    Write-Host "エラー: LOCALRAG_API_KEY が未設定です。"
    Write-Host '  実行例: $env:LOCALRAG_API_KEY = "xxxx" のあと本スクリプトを実行'
    Write-Host "  API キー発行: http://localhost:3001 → Settings → API Keys"
    exit 2
}
if (-not $Fixture) {
    Write-Host "エラー: fixtures\test-policy.txt が見つかりません。"
    exit 2
}
$ping = Invoke-Api @("--max-time", "10", "$BaseUrl/api/ping")
if ($ping -notmatch '"online"\s*:\s*true') {
    Write-Host "エラー: $BaseUrl に到達できません。server が起動していません。"
    exit 2
}

$AuthHeader = @("-H", "Authorization: Bearer $ApiKey")
$WsSlug = ""

try {
    # --- 1. ワークスペース作成 ---
    Write-Host "[1/6] テスト用ワークスペースを作成中..."
    $wsRaw = Invoke-Api ($AuthHeader + @(
        "--max-time", "30", "-X", "POST",
        "-H", "Content-Type: application/json",
        "-d", "{`"name`":`"$WsName`"}",
        "$BaseUrl/api/v1/workspace/new"))
    $wsJson = Parse-Json $wsRaw
    if ($wsJson -and $wsJson.workspace -and $wsJson.workspace.slug) {
        $WsSlug = $wsJson.workspace.slug
        Pass "ワークスペース作成: slug=$WsSlug"
    } else {
        Fail "ワークスペース作成に失敗: $wsRaw"
        exit 1
    }

    # --- 2. 文書アップロード + embedding ---
    Write-Host "[2/6] fixture をアップロード・embedding 中..."
    $upRaw = Invoke-Api ($AuthHeader + @(
        "--max-time", "$TimeoutSec", "-X", "POST",
        "-F", "file=@$Fixture;type=text/plain",
        "-F", "addToWorkspaces=$WsSlug",
        "$BaseUrl/api/v1/document/upload"))
    if ($upRaw -match '"success"\s*:\s*true') {
        Pass "文書アップロード・embedding 完了"
    } else {
        Fail ("文書アップロードに失敗: " + $upRaw.Substring(0, [Math]::Min(200, $upRaw.Length)))
        exit 1
    }
    Start-Sleep -Seconds 3  # embedding 反映待ち

    # --- 3. 文書内質問 (出典付き回答) ---
    Write-Host "[3/6] 文書内質問（有給休暇は何日か）..."
    $q1Raw = Invoke-Api ($AuthHeader + @(
        "--max-time", "$TimeoutSec", "-X", "POST",
        "-H", "Content-Type: application/json",
        "-d", '{"message":"有給休暇は年間何日付与されますか？","mode":"query"}',
        "$BaseUrl/api/v1/workspace/$WsSlug/chat"))
    $q1 = Parse-Json $q1Raw
    $a1 = if ($q1) { [string]$q1.textResponse } else { "" }
    $src1 = if ($q1 -and $q1.sources) { @($q1.sources).Count } else { 0 }
    $a1Head = $a1.Substring(0, [Math]::Min(120, $a1.Length))
    Write-Host "      回答: $a1Head"
    if ($a1 -match "22") {
        Pass "文書内の固有値「22」を含む回答"
    } else {
        Fail "回答に「22」が含まれない（ハルシネーションまたは検索失敗の可能性）"
    }
    if ($src1 -gt 0) {
        Pass "出典 (sources) が $src1 件付与されている"
    } else {
        Fail "出典が付与されていない"
    }

    # --- 3b. 日本語(CIDフォント)PDF のパース + RAG検索 ---
    if ($PdfFixture) {
        Write-Host "[3b] 日本語PDF（CIDフォント）のアップロード・RAG検索..."
        $uppRaw = Invoke-Api ($AuthHeader + @(
            "--max-time", "$TimeoutSec", "-X", "POST",
            "-F", "file=@$PdfFixture;type=application/pdf",
            "-F", "addToWorkspaces=$WsSlug",
            "$BaseUrl/api/v1/document/upload"))
        if ($uppRaw -match '"success"\s*:\s*true') {
            Pass "日本語PDFアップロード・embedding 完了"
            Start-Sleep -Seconds 3
            $qpRaw = Invoke-Api ($AuthHeader + @(
                "--max-time", "$TimeoutSec", "-X", "POST",
                "-H", "Content-Type: application/json",
                "-d", '{"message":"国内出張の日当は1日あたりいくらですか？","mode":"query"}',
                "$BaseUrl/api/v1/workspace/$WsSlug/chat"))
            $qp = Parse-Json $qpRaw
            $ap = if ($qp) { [string]$qp.textResponse } else { "" }
            if ($ap -match "3,?400") {
                Pass "PDF内の固有値「3,400」を含む回答"
            } else {
                $apHead = $ap.Substring(0, [Math]::Min(120, $ap.Length))
                Fail "PDF由来の回答に「3,400」が含まれない: $apHead"
            }
        } else {
            Fail ("日本語PDFのアップロードに失敗: " + $uppRaw.Substring(0, [Math]::Min(200, $uppRaw.Length)))
        }
    } else {
        Write-Host "[3b] SKIP: fixtures\test-expense.pdf が見つからない"
    }

    # --- 3c. DOCX のパース + RAG検索 ---
    if ($DocxFixture) {
        Write-Host "[3c] DOCXのアップロード・RAG検索..."
        $updRaw = Invoke-Api ($AuthHeader + @(
            "--max-time", "$TimeoutSec", "-X", "POST",
            "-F", "file=@$DocxFixture;type=application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "-F", "addToWorkspaces=$WsSlug",
            "$BaseUrl/api/v1/document/upload"))
        if ($updRaw -match '"success"\s*:\s*true') {
            Pass "DOCXアップロード・embedding 完了"
            Start-Sleep -Seconds 3
            $qdRaw = Invoke-Api ($AuthHeader + @(
                "--max-time", "$TimeoutSec", "-X", "POST",
                "-H", "Content-Type: application/json",
                "-d", '{"message":"フレックスタイム制のコアタイムは何時から何時までですか？","mode":"query"}',
                "$BaseUrl/api/v1/workspace/$WsSlug/chat"))
            $qd = Parse-Json $qdRaw
            $ad = if ($qd) { [string]$qd.textResponse } else { "" }
            # 全角/半角スペース・表記ゆれ (10:20 / 10時20分 / 10 時 20 分) を許容
            if ($ad -match "10[ 　]*[:時][ 　]*20") {
                Pass "DOCX内の固有値「コアタイム10時20分」を含む回答"
            } else {
                $adHead = $ad.Substring(0, [Math]::Min(120, $ad.Length))
                Fail "DOCX由来の回答にコアタイム開始時刻が含まれない: $adHead"
            }
        } else {
            Fail ("DOCXのアップロードに失敗: " + $updRaw.Substring(0, [Math]::Min(200, $updRaw.Length)))
        }
    } else {
        Write-Host "[3c] SKIP: fixtures\test-attendance.docx が見つからない"
    }

    # --- 4. 文書外質問 (不明応答) ---
    Write-Host "[4/6] 文書外質問（文書に無い情報）..."
    $q2Raw = Invoke-Api ($AuthHeader + @(
        "--max-time", "$TimeoutSec", "-X", "POST",
        "-H", "Content-Type: application/json",
        "-d", '{"message":"本社の所在地の郵便番号を教えてください。","mode":"query"}',
        "$BaseUrl/api/v1/workspace/$WsSlug/chat"))
    $q2 = Parse-Json $q2Raw
    $a2 = if ($q2) { [string]$q2.textResponse } else { "" }
    $src2 = if ($q2 -and $q2.sources) { @($q2.sources).Count } else { 0 }
    $a2Head = $a2.Substring(0, [Math]::Min(120, $a2.Length))
    Write-Host "      回答: $a2Head"
    # query モードでは文書外質問は出典ゼロ または 明示的な不明応答になるべき
    $unknownPattern = "不明|見つかり|ありません|no relevant|don't have|情報がない|含まれて|記載されて|記載がない|わかりません|お答えできません"
    if (($src2 -eq 0) -or ($a2 -match $unknownPattern)) {
        Pass "文書外質問に対して出典なし／不明応答"
    } else {
        Fail "文書外質問に出典付きで回答した（ハルシネーションの疑い）"
    }

    # --- 5. 外部LLM provider が API側で拒否されること ---
    Write-Host "[5/6] 外部LLM provider(openai)拒否の確認..."
    $provRaw = Invoke-Api ($AuthHeader + @(
        "--max-time", "30", "-X", "POST",
        "-H", "Content-Type: application/json",
        "-d", '{"LLMProvider":"openai","OpenAiKey":"sk-e2e-test-dummy","OpenAiModelPref":"gpt-4o"}',
        "$BaseUrl/api/system/update-env"))
    if ($provRaw -match "not a permitted|not allowed|not supported") {
        Pass "外部provider(openai)はAPI側で拒否される"
    } else {
        Fail ("外部provider(openai)が拒否されなかった: " + $provRaw.Substring(0, [Math]::Min(200, $provRaw.Length)))
    }

    # --- 6. Swagger docs が無効であること ---
    Write-Host "[6/6] Swagger docs 無効の確認..."
    $docsBody = Invoke-Api @("--max-time", "10", "$BaseUrl/api/docs")
    if ($docsBody -match "swagger|Developer API Documentation") {
        Fail "Swagger docs が有効になっている（DISABLE_SWAGGER_DOCS を確認）"
    } else {
        Pass "Swagger docs は無効（/api/docs に Swagger UI が出ていない）"
    }
}
finally {
    # クリーンアップ (テスト用ワークスペースを削除)
    if ($WsSlug) {
        Write-Host "[後処理] テスト用ワークスペース ($WsSlug) を削除中..."
        Invoke-Api ($AuthHeader + @(
            "--max-time", "30", "-X", "DELETE",
            "$BaseUrl/api/v1/workspace/$WsSlug")) | Out-Null
    }
}

# --- 結果 ---
Write-Host ""
Write-Host "=== RAG E2E テスト結果: PASS=$($script:PassCount) FAIL=$($script:FailCount) ==="
if ($script:FailCount -eq 0) {
    Write-Host "OK: RAG パイプラインは正常に動作しています。"
    exit 0
}
Write-Host "NG: 失敗があります。server / collector のコンソールログを確認してください。"
exit 1
