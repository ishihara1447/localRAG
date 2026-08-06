# install.ps1 の文書引き継ぎ処理の回帰テスト。
#   powershell -NoProfile -ExecutionPolicy Bypass -File windows-native\tests\carry-forward.test.ps1
#
# なぜ要るか: この処理は最初「storage が空か」で判定しており、**一度も発火しな
# かった**。導入時点で app はコピー済みで、配布物の storage には同梱リランカーと
# OCR 言語データが入っているため常に非空だったため。静的レビューでは見落としやすく、
# 実際にファイルを置いて通してみないと分からない。
#
# install.ps1 のロジックを変えたら、このテストも合わせて直すこと。
# 実機には一切触れない。install.ps1 と同じロジックを、パスだけ差し替えて実行する。
$ErrorActionPreference = "Stop"
$root = Join-Path $env:TEMP ("carrysim-" + (Get-Date -Format "HHmmss"))
$pass = 0
$total = 0

function New-Storage([string]$dir, [bool]$withData, [string]$rerankerVer) {
    New-Item -ItemType Directory -Path (Join-Path $dir "models\hotchpotch") -Force | Out-Null
    Set-Content -Path (Join-Path $dir "models\hotchpotch\model.onnx") -Value $rerankerVer
    New-Item -ItemType Directory -Path (Join-Path $dir "models\tesseract") -Force | Out-Null
    Set-Content -Path (Join-Path $dir "models\tesseract\jpn.traineddata") -Value $rerankerVer
    if ($withData) {
        New-Item -ItemType Directory -Path (Join-Path $dir "documents\custom-documents") -Force | Out-Null
        Set-Content -Path (Join-Path $dir "documents\custom-documents\doc1.json") -Value '{"title":"顧客の文書"}'
        New-Item -ItemType Directory -Path (Join-Path $dir "lancedb\ws.lance") -Force | Out-Null
        Set-Content -Path (Join-Path $dir "lancedb\ws.lance\data.bin") -Value "vectors"
        Set-Content -Path (Join-Path $dir "anythingllm.db") -Value "sqlite"
    }
}

# install.ps1 と同じ判定
function Test-HasData([string]$storageDir) {
    foreach ($m in @("documents", "lancedb", "anythingllm.db", "vector-cache")) {
        $mp = Join-Path $storageDir $m
        if ((Test-Path $mp) -and (Get-ChildItem -Path $mp -Force -ErrorAction SilentlyContinue)) { return $true }
        if ((Test-Path $mp) -and (Get-Item $mp -ErrorAction SilentlyContinue).PSIsContainer -eq $false) { return $true }
    }
    return $false
}

function Invoke-Carry([string]$pendingPath, [string]$storageDir, [bool]$embedChanged) {
    $exclude = @("/XD", (Join-Path $pendingPath "models"))
    if ($embedChanged) {
        $exclude += @("/XD", (Join-Path $pendingPath "lancedb"), (Join-Path $pendingPath "vector-cache"))
    }
    robocopy $pendingPath $storageDir /E /R:1 /W:1 @exclude /NFL /NDL /NJH /NJS | Out-Null
    $global:LASTEXITCODE = 0
}

function Check([string]$name, [bool]$cond) {
    $script:total++
    if ($cond) { $script:pass++ }
    Write-Output ("  {0}  {1}" -f $(if ($cond) { "PASS" } else { "FAIL" }), $name)
}

# --- ケース1: 通常のアップグレード（埋め込みモデル同じ） ---
Write-Output "=== ケース1: 通常のアップグレード ==="
$old1 = Join-Path $root "c1\old"; $new1 = Join-Path $root "c1\new"
New-Storage $old1 $true "OLD"      # 旧版の退避データ（文書＋ベクトル＋旧リランカー）
New-Storage $new1 $false "NEW"     # インストール直後（同梱モデルのみ）
Check "引き継ぎ前: 新storageは『データなし』と判定" (-not (Test-HasData $new1))
Check "退避データは『データあり』と判定" (Test-HasData $old1)
Invoke-Carry $old1 $new1 $false
Check "文書が引き継がれた" (Test-Path (Join-Path $new1 "documents\custom-documents\doc1.json"))
Check "ベクトルが引き継がれた" (Test-Path (Join-Path $new1 "lancedb\ws.lance\data.bin"))
Check "DBが引き継がれた" (Test-Path (Join-Path $new1 "anythingllm.db"))
Check "同梱リランカーが新版のまま(旧版で上書きされない)" ((Get-Content (Join-Path $new1 "models\hotchpotch\model.onnx")) -eq "NEW")
Check "OCR言語データが新版のまま" ((Get-Content (Join-Path $new1 "models\tesseract\jpn.traineddata")) -eq "NEW")

# --- ケース2: 埋め込みモデルが変わった場合 ---
Write-Output "=== ケース2: 埋め込みモデルが変わった ==="
$old2 = Join-Path $root "c2\old"; $new2 = Join-Path $root "c2\new"
New-Storage $old2 $true "OLD"
New-Storage $new2 $false "NEW"
Invoke-Carry $old2 $new2 $true
Check "文書は引き継がれた" (Test-Path (Join-Path $new2 "documents\custom-documents\doc1.json"))
Check "ベクトルは引き継がれない(次元が違うため)" (-not (Test-Path (Join-Path $new2 "lancedb\ws.lance\data.bin")))
Check "同梱リランカーが新版のまま" ((Get-Content (Join-Path $new2 "models\hotchpotch\model.onnx")) -eq "NEW")

# --- ケース3: 既にデータがある場所には引き継がない ---
Write-Output "=== ケース3: 既存データがある ==="
$new3 = Join-Path $root "c3\new"
New-Storage $new3 $true "NEW"
Check "『データあり』と判定され引き継ぎをしない" (Test-HasData $new3)

Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
Write-Output ""
Write-Output "$pass/$total passed"
