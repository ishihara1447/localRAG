# Codex 作業依頼: 配布パッケージのビルド（4-2）と実機インストール検証（4-5）

作成日: 2026-07-09（Claude Code）
前提ドキュメント: `docs/WINDOWS_NATIVE_PHASE4_DESIGN_2026-07-09.md`（設計）、`docs/WINDOWS_NATIVE_POC_RESULT_2026-07-09.md`（前回PoC）

## 依頼の全体像

前回PoCの合格を受け、Claude Code側でPhase 4の成果物（配布パッケージ生成スクリプト・インストーラ・サービス定義・運用スクリプト一式）を実装した。
今回の依頼は2つ:

1. **Part A（ビルド）**: Windows実機で配布パッケージ `LocalRAG-win64-v1.0.0.zip` を生成する
2. **Part B（検証）**: 生成したパッケージを使い、顧客と同じ手順でインストール→E2E→バックアップ→アンインストールまで通す

すべてのスクリプトはPowerShell 7のparserで構文チェック済みだが、**実行は今回が初**。
エラーが出たら止まって構わない。エラーメッセージ・ログを結果ファイルに貼ってくれれば、Claude Code側でforkやスクリプトを修正して再依頼する。

## 結果の報告先

`docs/WINDOWS_NATIVE_BUILD_VERIFY_RESULT_2026-07-09.md`（新規作成）に、末尾の「報告テンプレート」の形式で記録すること。

---

## Part A: 配布パッケージのビルド

### A-0. 【重要】ソースの再取得（前回PoCのC:\LocalRAG\srcは古い）

前回PoC後にfork側へ新コミットが入っている（**`fd67e830`: hotdir修正 = 前回PoCで踏んだ課題#2の恒久対応**）。
`C:\LocalRAG\src` を削除して取り直すこと。

```powershell
# 既存PoCのserver/collector/ollamaプロセスが動いていたら先に止める（Part B-0参照）
Remove-Item -Recurse -Force C:\LocalRAG\src
robocopy \\wsl.localhost\Ubuntu-22.04\home\ishihara1447\projects\fukugyo\repos\localRAG\anything-llm C:\LocalRAG\src /E /XD node_modules .git /XF .env
# windows-native も最新化（今回の新規スクリプト群が入っている）
robocopy \\wsl.localhost\Ubuntu-22.04\home\ishihara1447\projects\fukugyo\repos\localRAG\windows-native C:\LocalRAG\windows-native /MIR
robocopy \\wsl.localhost\Ubuntu-22.04\home\ishihara1447\projects\fukugyo\repos\localRAG\fixtures C:\LocalRAG\fixtures /MIR
```

取得後、fork側に今回の修正が入っていることを確認:

```powershell
Select-String -Path C:\LocalRAG\src\server\utils\files\index.js -Pattern "COLLECTOR_HOTDIR_PATH" -Quiet
# → True が出ればOK。False なら報告して中断
```

### A-1. 依存インストールとビルド（前回PoCと同じ手順）

```powershell
$env:PUPPETEER_SKIP_DOWNLOAD = "true"
$env:PUPPETEER_SKIP_CHROMIUM_DOWNLOAD = "true"
# 前回証明書エラーが出た環境なら: $env:NODE_OPTIONS = "--use-system-ca"

cd C:\LocalRAG\src\server    ; yarn install
cd C:\LocalRAG\src\collector ; yarn install
cd C:\LocalRAG\src\frontend  ; yarn install

# frontend build → server/public へ
cd C:\LocalRAG\src\frontend
Set-Content -Path .env -Value "VITE_API_BASE='/api'"
yarn build
Copy-Item -Recurse -Force C:\LocalRAG\src\frontend\dist C:\LocalRAG\src\server\public

# prisma generate（binaryTargetsにwindowsが入ったので、windows用engineが生成される）
cd C:\LocalRAG\src\server
node node_modules\prisma\build\index.js generate --schema=.\prisma\schema.prisma
# 確認: windows用query engineの存在
Get-ChildItem C:\LocalRAG\src\server\node_modules\.prisma\client -Filter "query_engine-windows*"
```

### A-2. ビルド用外部依存のダウンロード

`C:\LocalRAG\build-deps\` に以下を用意する（ビルドマシンはオンラインでOK。オフライン制約は顧客インストール時のみ）:

| 依存 | 取得元 | 配置 |
|---|---|---|
| Node.js portable | nodejs.org/dist から **v22系LTSの win-x64 zip**（例: `node-v22.20.0-win-x64.zip`）をDLして展開 | `C:\LocalRAG\build-deps\node-v22.x.x-win-x64\`（直下にnode.exe） |
| Ollama standalone | github.com/ollama/ollama/releases から `ollama-windows-amd64.zip`（前回インストールした0.31.2と同系の最新でよい）をDLして展開 | `C:\LocalRAG\build-deps\ollama\`（直下にollama.exe） |
| WinSW | github.com/winsw/winsw/releases から `WinSW-x64.exe`（v2系最新、MIT） | `C:\LocalRAG\build-deps\WinSW-x64.exe` |

注意: winget版Ollama（前回インストール済み）はビルドには使わない。配布物には**standalone zip版**を同梱する（顧客PCにインストーラを走らせないため）。

### A-3. パッケージ生成

モデルは前回PoCで `%USERPROFILE%\.ollama\models` にコピー済みのものを使う（manifest解析で必要な2モデル分のblobだけが同梱される。qwen3等の余分は入らない）:

```powershell
cd C:\LocalRAG\windows-native
powershell -NoProfile -ExecutionPolicy Bypass -File .\export-windows.ps1 `
  -Version 1.0.0 `
  -SourceDir C:\LocalRAG\src `
  -NodeDir C:\LocalRAG\build-deps\node-v22.20.0-win-x64 `
  -OllamaDir C:\LocalRAG\build-deps\ollama `
  -WinSWExe C:\LocalRAG\build-deps\WinSW-x64.exe `
  -ModelsDir $env:USERPROFILE\.ollama\models `
  -OutputDir C:\LocalRAG\dist
```

期待結果: `C:\LocalRAG\dist\LocalRAG-win64-v1.0.0\`（フォルダ）と `LocalRAG-win64-v1.0.0.zip`。
サイズ目安: モデル約5.6GiB + node_modules/ランタイムで**合計7〜9GB程度**。
記録すること: 所要時間、最終サイズ、`versions.lock` の内容。

---

## Part B: 実機インストール検証（顧客手順の通し）

### B-0. 【重要】クリーンな状態を作る

前回PoCの残骸が検証を汚染するため、以下を確認・停止する:

```powershell
# 1. PoCで手動起動したプロセス（server:3002 / collector:8888 / ollama:11435）が残っていないか
Get-NetTCPConnection -LocalPort 3001,3002,8888,11435 -State Listen -ErrorAction SilentlyContinue |
  ForEach-Object { "{0} -> {1}" -f $_.LocalPort, (Get-Process -Id $_.OwningProcess).ProcessName }
# node / ollama が出たら該当プロセスを停止する

# 2. winget版Ollama（タスクトレイ常駐、11434）を終了する
#    ※検証の主旨: 同梱standalone版だけでLocalRAGが完結することの証明。
#    トレイアイコンから Quit（アンインストールまでは不要）

# 3. WSL側Docker版が3001を掴んでいる場合（wslrelay.exe）
wsl --shutdown
# ※検証後にWSL側を使うときは docker compose up -d で復帰させる
```

### B-1. インストール（顧客手順そのまま）

**インストール先は `C:\LocalRAGProd` を指定すること**（既定の`C:\LocalRAG`はビルド作業ディレクトリと同居してしまい、アンインストール検証でsrcごと消えるため）。

```powershell
# 顧客になったつもりで、zipを別の場所に展開してそこから実行する
Expand-Archive C:\LocalRAG\dist\LocalRAG-win64-v1.0.0.zip -DestinationPath C:\Temp\localrag-install
cd C:\Temp\localrag-install\LocalRAG-win64-v1.0.0
# 管理者PowerShellで:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -InstallRoot C:\LocalRAGProd
```

install.ps1 は preflight（管理者・OS・GPU/VRAM・ディスク・ポート3001/8888/11435）→ checksum検証 →
展開 → .env生成 → prisma migrate → サービス登録・起動 → `/api/ping` 待機、まで自動で行う。

**確認ポイント**:
- preflightの各判定の出力（そのまま報告に貼る）
- `Get-Service LocalRAG-*` が3本とも Running
- ブラウザで `http://localhost:3001` が開く（オンボーディングでOllama/llm-jpが選択可能）
- `C:\ProgramData\LocalRAG\logs\` にサービスログが出ている

### B-2. RAG E2E（11項目）

```powershell
# APIキー発行: ブラウザ Settings → API Keys（またはPoCと同じAPI直叩き）
cd C:\LocalRAGProd
$env:LOCALRAG_API_KEY = "<発行したキー>"
$env:LOCALRAG_BASE_URL = "http://localhost:3001"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\rag-e2e-test.ps1
```

合格ライン: **11/11 PASS**（前回PoCと同一項目）。
既知の仕様: 本番envは `WORKSPACE_DELETION_PROTECTION=1` のため、テスト後のワークスペース自動削除が失敗して`localrag-smoketest`が残る。**これは正常**（UIから手動削除してよい）。
今回はPowerShell 5.1（`powershell.exe`）での実行も確認したい（BOM付き化の検証）。**まず5.1で実行し、ダメならpwshで再実行して両方の結果を報告**。

### B-3. 運用スクリプトの動作確認

```powershell
cd C:\LocalRAGProd
# バックアップ（サービス停止→スナップショット→再開、が自動で行われる）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\backup.ps1
# → C:\ProgramData\LocalRAG\backups\localrag-backup-*.zip ができること、サービスがRunningに戻ること

# 停止・起動
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\stop.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\start.ps1
# → 再起動後も http://localhost:3001/api/ping が {"online":true}
```

### B-4. アンインストール（データ温存の確認）

```powershell
cd C:\LocalRAGProd
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

**確認ポイント**:
- `Get-Service LocalRAG-*` が空になる
- `C:\LocalRAGProd` がほぼ空になる（uninstall.ps1自身は残る仕様）
- **データが `C:\ProgramData\LocalRAG\uninstalled-<日時>\storage` に温存されている**
- `C:\ProgramData\LocalRAG\models` は残っている（-RemoveData未指定のため）

検証がすべて終わったら、後片付けとして `C:\ProgramData\LocalRAG` と `C:\Temp\localrag-install` は削除してよい（ビルド成果物 `C:\LocalRAG\dist\*.zip` は**残すこと**）。

### B-5. （余力があれば）完全オフライン検証の準備調査

今回は必須ではない。Wi-Fi/LANを切った状態でB-1〜B-2が通るかの確認は次回4-6で行う予定。
もし今回試せた場合は結果を報告に含めること。

---

## 報告テンプレート（docs/WINDOWS_NATIVE_BUILD_VERIFY_RESULT_2026-07-09.md）

```markdown
# Windows Native ビルド・検証結果
作成日: / 担当: Codex

## Part A: ビルド
- A-0 ソース再取得・COLLECTOR_HOTDIR_PATH確認: OK/NG
- A-1 yarn install / frontend build / prisma generate: OK/NG（所要時間）
- A-2 依存DL（node/ollama/winswの正確なバージョン）:
- A-3 export-windows.ps1: OK/NG（所要時間・zipサイズ・versions.lockの内容）
- 発生したエラーと暫定対処:

## Part B: 検証
- B-0 クリーン化で停止したもの:
- B-1 install.ps1: preflight出力（貼付）/ サービス状態 / UI表示: OK/NG
- B-2 E2E: PS5.1での結果(11項目) / pwshでの結果（5.1がNGだった場合）
- B-3 backup/stop/start: OK/NG（backupのzipサイズ）
- B-4 uninstall: OK/NG（データ温存パスの確認結果）
- B-5 オフライン検証（任意）:

## Claude Codeへの修正依頼・気づき
-
```
