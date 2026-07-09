# Codex 作業依頼: Windows Native PoC（Phase 1〜3）実行手順

作成日: 2026-07-09（Claude Code）
対象計画: `docs/WINDOWS_NATIVE_OFFLINE_INSTALL_WORKPLAN_2026-07-09.md`
背景メモ: `docs/CLAUDE_CODE_MEMO_WINDOWS_NATIVE_DISTRIBUTION_2026-07-09.md`

## 目的

Docker / WSL2 を使わず、Windows ホスト上でネイティブに AnythingLLM fork + Ollama を起動し、
RAG E2E が Docker 版と同等に通るかを確認する（PoC）。**installer はまだ作らない。**

## Claude Code側で準備済みのもの（fork commit / ファイル）

| 準備物 | 場所 |
|---|---|
| `DISABLE_WEB_SCRAPING` フラグ + puppeteer遅延ロード化 | fork commit `cdd1c292` |
| prisma `binaryTargets = ["native", "windows"]` | fork commit `1f5658b6` |
| server用 .env テンプレート | `windows-native/server.env.example` |
| collector用 .env テンプレート | `windows-native/collector.env.example` |
| PowerShell版 RAG E2E テスト | `windows-native/rag-e2e-test.ps1` |

## 結果の報告先

各 Phase の結果（成功/失敗・エラーログ・気づき）を
`docs/WINDOWS_NATIVE_POC_RESULT_2026-07-09.md` （新規作成）に記録してください。
失敗した場合もそのまま記録すれば、Claude Code が fork 側を修正して再依頼します。

---

## Phase 1: Windows native 起動確認

### 1-0. ソースコードを Windows 側へコピー

**注意: `node_modules` と `.git` は絶対にコピーしないこと**（node_modules には Linux 用バイナリが入っており、混入すると原因不明のエラーになる）。

```powershell
# 管理者不要。作業ディレクトリは C:\LocalRAG を想定（変更可、以降読み替え）
mkdir C:\LocalRAG
robocopy \\wsl.localhost\Ubuntu-22.04\home\ishihara1447\projects\fukugyo\repos\localRAG\anything-llm C:\LocalRAG\src /E /XD node_modules .git /XF .env
robocopy \\wsl.localhost\Ubuntu-22.04\home\ishihara1447\projects\fukugyo\repos\localRAG\windows-native C:\LocalRAG\windows-native /E
robocopy \\wsl.localhost\Ubuntu-22.04\home\ishihara1447\projects\fukugyo\repos\localRAG\fixtures C:\LocalRAG\fixtures /E
```

### 1-1. Node.js / Yarn の導入

```powershell
node --version   # v18.12.1 以上（v20/v22 LTS 推奨）。無ければ nodejs.org のLTSインストーラで導入
corepack enable  # yarn を使えるようにする（管理者PowerShellが必要な場合あり）
yarn --version
```

### 1-2. 依存インストール（prebuilt バイナリ解決の確認ポイント）

```powershell
# Chromium のダウンロードをスキップ（puppeteer 本体は package.json に残っているため）
$env:PUPPETEER_SKIP_DOWNLOAD = "true"
$env:PUPPETEER_SKIP_CHROMIUM_DOWNLOAD = "true"

cd C:\LocalRAG\src\server ; yarn install
cd C:\LocalRAG\src\collector ; yarn install
cd C:\LocalRAG\src\frontend ; yarn install
```

**確認ポイント（結果報告に含めること）**:

```powershell
# Windows用prebuiltが解決されているか
Test-Path C:\LocalRAG\src\server\node_modules\@lancedb\lancedb-win32-x64-msvc
Test-Path C:\LocalRAG\src\collector\node_modules\@img\sharp-win32-x64
# Chromiumがダウンロードされていないか（数百MBの .cache や chrome ディレクトリが無いこと）
```

### 1-3. frontend ビルドと配置

```powershell
cd C:\LocalRAG\src\frontend
# .env に VITE_API_BASE='/api' を設定（.env.example 参照）
Set-Content -Path .env -Value "VITE_API_BASE='/api'"
yarn build
# dist を server/public へ
Copy-Item -Recurse -Force C:\LocalRAG\src\frontend\dist C:\LocalRAG\src\server\public
```

### 1-4. .env 配置と prisma

```powershell
mkdir C:\LocalRAG\storage
Copy-Item C:\LocalRAG\windows-native\server.env.example C:\LocalRAG\src\server\.env
Copy-Item C:\LocalRAG\windows-native\collector.env.example C:\LocalRAG\src\collector\.env
# STORAGE_DIR等は既定で C:\LocalRAG\storage を指すので、パスを変えた場合のみ編集

cd C:\LocalRAG\src\server
npx prisma generate --schema=./prisma/schema.prisma
npx prisma migrate deploy --schema=./prisma/schema.prisma
```

### 1-5. 起動

```powershell
# 別々のPowerShellウィンドウで:
cd C:\LocalRAG\src\server    ; $env:NODE_ENV="production" ; node index.js
cd C:\LocalRAG\src\collector ; $env:NODE_ENV="production" ; node index.js
```

**確認ポイント**:
- ブラウザで `http://localhost:3001` が開き、AnythingLLM のUIが表示される
- server / collector 両方のコンソールにモジュール読み込みエラー（特に puppeteer / sharp / lancedb / prisma 関連）が出ていない

### 1-6. puppeteer 無効化の確認

collector のログにエラーが出ずに起動していること（`DISABLE_WEB_SCRAPING=true` は collector/.env に設定済み）。
UI からリンク取り込みを試すと「Web link scraping is disabled in this build」で拒否されれば正常。

---

## Phase 2: Ollama for Windows + オフラインモデル投入

### 2-1. Ollama for Windows のインストール

ollama.com から `OllamaSetup.exe` を取得してインストール（PoC ではオンライン取得可。
配布時のオフライン同梱方式は Phase 4 で設計する）。

```powershell
ollama --version
# サービスが 127.0.0.1:11434 で待ち受けているか
curl.exe -s http://127.0.0.1:11434/api/version
```

### 2-2. WSL2 側の既存モデルをコピー（`ollama pull` を使わない）

```powershell
# Ollamaを一旦終了（タスクトレイから Quit）してからコピー
robocopy \\wsl.localhost\Ubuntu-22.04\home\ishihara1447\projects\fukugyo\repos\localRAG\runtime\ollama-models $env:USERPROFILE\.ollama\models /E
# Ollamaを再起動して認識確認
ollama list
# → hf.co/mmnga-o/llm-jp-4-8b-thinking-gguf:Q4_K_M と mxbai-embed-large:latest が出ればOK
```

### 2-3. 動作・GPU確認

```powershell
ollama run hf.co/mmnga-o/llm-jp-4-8b-thinking-gguf:Q4_K_M "こんにちは。1文で自己紹介して。"
ollama ps   # GPU にロードされているか（100% GPU 表示）と応答時間を記録
```

### 2-4. AnythingLLM → Ollama 接続

server/.env の既定値（`OLLAMA_BASE_PATH=http://127.0.0.1:11434` 等）で接続される。
`http://localhost:3001` の初期セットアップで LLM に Ollama / 上記モデルが選択できることを確認。

---

## Phase 3: RAG E2E 検証

### 3-1. APIキー発行

ブラウザ `http://localhost:3001` → Settings → API Keys で発行（または Docker 版で使った
`POST /api/system/generate-api-key` 直叩きでも可）。

### 3-2. E2E テスト実行

```powershell
cd C:\LocalRAG\windows-native
$env:LOCALRAG_API_KEY = "<発行したキー>"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\rag-e2e-test.ps1
```

**合格ライン**: Docker 版と同じ 11 項目（TXT/PDF/DOCX の出典付き回答・文書外の不明応答・
外部 provider 拒否・Swagger 無効）がすべて PASS し、タイムアウトしないこと。

### 3-3. 結果報告

`docs/WINDOWS_NATIVE_POC_RESULT_2026-07-09.md` に以下を記録:

- 各 Phase の成否と所要時間
- E2E テストの PASS/FAIL 全出力
- LLM 応答速度の体感（Docker 版との差）
- ハマった点・手順書の誤り・Claude Code への修正依頼事項
