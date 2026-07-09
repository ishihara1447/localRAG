# Windows Native PoC 結果

作成日: 2026-07-09
担当: Codex
対象手順: `docs/CODEX_WINDOWS_NATIVE_POC_INSTRUCTIONS_2026-07-09.md`

## 結論

**PoC は合格。**

Docker / WSL2 を使わず、Windows ホスト上の native Node.js + Windows native Ollama で
AnythingLLM fork を起動し、RAG E2E が **11/11 PASS** した。

ただし、いくつか製品化前に直すべき実装・手順上の課題が見つかった。

## 実行環境

- Windows 11
- GPU: NVIDIA GeForce RTX 5070 Ti
- NVIDIA driver: 591.86
- CUDA version reported by `nvidia-smi`: 13.1
- Node.js: Codex 同梱 Windows runtime `v24.14.0`
  - system PATH には Node.js / Corepack / Yarn は未導入だった
  - PoC では `C:\Users\ms_is\AppData\Local\OpenAI\Codex\runtimes\cua_node\...\bin` を PATH に追加して実行
- Yarn: Corepack 経由 `1.22.22`
- Ollama for Windows: winget で `Ollama.Ollama 0.31.2` を導入

## Phase 1: Windows native 起動

### 結果

**PASS**

実施内容:

- WSL 側 `anything-llm/` を `C:\LocalRAG\src` にコピー
  - `.git` / `node_modules` は除外
- `windows-native/` を `C:\LocalRAG\windows-native` にコピー
- `fixtures/` を `C:\LocalRAG\fixtures` にコピー
- `server` / `collector` / `frontend` で `yarn install`
- frontend build
- `server/public` に build 済み frontend を配置
- Prisma generate / migrate
- server / collector を Windows native process として起動

確認結果:

- `server`: `http://localhost:3002/api/ping` が `{"online":true}` を返した
- `collector`: port `8888` で起動
- `@lancedb/lancedb-win32-x64-msvc`: resolved
- `@img/sharp-win32-x64`: resolved
- frontend build: success
- Prisma generate / migrate: success
- Swagger disabled log: confirmed
- Telemetry disabled log: confirmed
- puppeteer/Chromium download: skipped by env

注意:

- 既存 WSL/Docker 版が `wslrelay.exe` 経由で `localhost:3001` を使用中だったため、PoC は `SERVER_PORT=3002` で実施した。
- `powershell.exe` (Windows PowerShell 5.1) では `rag-e2e-test.ps1` の日本語文字列が UTF-8 として解釈されず parser error になった。PoC では `pwsh` (PowerShell 7.5.5) で実行した。

## Phase 2: Ollama for Windows + オフラインモデル投入

### 結果

**PASS**

実施内容:

- `winget install --id Ollama.Ollama -e --source winget --accept-package-agreements --accept-source-agreements`
- WSL 側モデルを Windows 側へコピー:
  - from: `\\wsl.localhost\Ubuntu-22.04\home\ishihara1447\projects\fukugyo\repos\localRAG\runtime\ollama-models\models`
  - to: `%USERPROFILE%\.ollama\models`
- Windows native Ollama を別ポート `127.0.0.1:11435` で起動:
  - `OLLAMA_HOST=127.0.0.1:11435`
  - `OLLAMA_LLM_LIBRARY=cuda_v13`
  - `OLLAMA_MODELS=%USERPROFILE%\.ollama\models`

確認結果:

`ollama list` on `11435`:

```text
hf.co/mmnga-o/llm-jp-4-8b-thinking-gguf:Q4_K_M
llama3.1:8b
mxbai-embed-large:latest
qwen3:14b
qwen3:8b
```

`ollama ps` after E2E:

```text
hf.co/mmnga-o/llm-jp-4-8b-thinking-gguf:Q4_K_M    100% GPU
mxbai-embed-large:latest                          100% GPU
```

重要な発見:

- `localhost:11434` は Windows Ollama ではなく、既存 WSL/Docker 側の `wslrelay.exe` だった。
- そのため `11434` の Ollama は `version 0.23.0` かつ CPU 実行として見えていた。
- Windows native Ollama 0.31.2 を `11435` に明示起動すると RTX 5070 Ti を CUDA GPU として認識した。
- 製品化時は、既存 WSL relay / 他 Ollama とのポート競合を検出する preflight が必要。

## Phase 3: RAG E2E

### 結果

**PASS: 11/11**

実行条件:

- `BaseUrl`: `http://localhost:3002`
- `TimeoutSec`: `600`
- `OLLAMA_BASE_PATH`: `http://127.0.0.1:11435`
- `EMBEDDING_BASE_PATH`: `http://127.0.0.1:11435`
- 実行シェル: `pwsh`

E2E 結果:

```text
[1/6] workspace create                          PASS
[2/6] TXT upload + embedding                    PASS
[3/6] TXT RAG answer includes 22 + source       PASS
[3b] Japanese CID PDF upload + RAG answer       PASS
[3c] DOCX upload + RAG answer                   PASS
[4/6] out-of-document unknown answer            PASS
[5/6] external provider(openai) rejected         PASS
[6/6] Swagger docs disabled                     PASS

RAG E2E result: PASS=11 FAIL=0
```

Observed answer behavior:

- TXT/PDF/DOCX の取り込みは成功
- sources 付与あり
- 文書外質問は「提供された文書には該当する情報がありません」系の応答
- 外部 provider `openai` は API 側で拒否
- `/api/docs` は Swagger UI を返さない

## 発見した課題

### 1. Windows PowerShell 5.1 で `rag-e2e-test.ps1` が文字化けして parser error

症状:

- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\rag-e2e-test.ps1`
- 日本語文字列が mojibake し、`[3b]` などを array index expression と誤解して parser error

暫定回避:

- `pwsh` (PowerShell 7) で実行すると成功

製品化前対応案:

- `.ps1` を UTF-8 BOM 付きで出力する
- またはテスト・ランチャーは PowerShell 7 前提にする
- 顧客環境で PowerShell 7 を同梱/導入するかは別途判断

### 2. `STORAGE_DIR=C:\LocalRAG\storage` だと server 側 hotdir が `C:\collector\hotdir` に解決される

症状:

```text
Invalid file upload. ENOENT: no such file or directory, open 'C:\collector\hotdir\test-policy.txt'
```

原因:

- `server/utils/files/index.js` / `server/utils/files/multer.js` が
  `path.resolve(process.env.STORAGE_DIR, "../../collector/hotdir")` で hotdir を計算している。
- Windows で `STORAGE_DIR=C:\LocalRAG\storage` にすると `C:\collector\hotdir` へ解決される。

暫定回避:

- `STORAGE_DIR=C:\LocalRAG\src\server\storage` に変更
- これにより `../../collector/hotdir` が `C:\LocalRAG\src\collector\hotdir` へ解決され、E2E が通った

製品化前対応案:

- `COLLECTOR_HOTDIR_PATH` のような明示 env を追加する
- または server / collector の配置を固定し、storage 位置と hotdir 位置を installer 側で矛盾なく生成する
- `C:\ProgramData\LocalRAG\storage` を使うならコード修正が必要

### 3. `11434` が WSL relay に取られていると Windows native Ollama 判定が混ざる

症状:

- `curl http://127.0.0.1:11434/api/version` が `0.23.0`
- owner process は `wslrelay.exe`
- Windows Ollama 0.31.2 は `11434` に bind できない

暫定回避:

- Windows native Ollama を `11435` で起動
- AnythingLLM env を `http://127.0.0.1:11435` に変更

製品化前対応案:

- installer / preflight で `11434` owner process を確認
- WSL relay / 他 Ollama がいる場合は停止案内、または LocalRAG 専用 port を使う
- LocalRAG 専用 Ollama process を service 管理する

### 4. Node.js / Yarn / Git 証明書まわり

発見:

- Windows PATH に Node.js / Corepack / Yarn は未導入だった
- Codex 同梱 Node では `NODE_OPTIONS=--use-system-ca` がないと Corepack の Yarn 取得で証明書エラー
- `collector` の `epub2-static` GitHub 取得で Git SSL 証明書エラー

暫定対応:

- `NODE_OPTIONS=--use-system-ca`
- `git config --global http.sslBackend schannel`

製品化前対応案:

- 顧客 PC で `yarn install` させない
- Windows 用 `node_modules` / Node runtime / frontend build 済み成果物を同梱する
- GitHub 依存を install 時に取りに行かない

## 追加で実施した環境変更

Windows ホストに以下を実施した:

- `C:\LocalRAG\` 作成
- Ollama for Windows 0.31.2 を winget でインストール
- `%USERPROFILE%\.ollama\models` に WSL 側モデルをコピー
- Git global config:
  - `http.sslBackend=schannel`

## PoC 用に起動したプロセス

- AnythingLLM server: `localhost:3002`
- collector: `localhost:8888`
- Ollama native PoC: `127.0.0.1:11435`

PoC 終了時に停止すること。

## Go / No-Go 判断材料

Windows native 方式は **Go と判断してよい**。

理由:

- Windows native の dependency install / frontend build / Prisma / server / collector 起動が通った
- Ollama for Windows 0.31.2 が RTX 5070 Ti を CUDA GPU として認識した
- WSL 側モデルを `ollama pull` なしで Windows native Ollama に投入できた
- RAG E2E が Docker 版と同等に 11/11 PASS した

ただし Phase 4 に進む前に、最低限以下の修正・設計が必要:

1. `STORAGE_DIR` と collector hotdir の Windows 配置設計
2. PowerShell 5.1 互換または PowerShell 7 同梱方針
3. LocalRAG 専用 Ollama port / service 管理
4. Node.js / node_modules / frontend build 済み配布物の同梱方式
5. installer preflight: 3001/3002/11434/11435 port owner、GPU、driver、モデル存在確認

