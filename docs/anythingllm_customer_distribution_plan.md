# AnythingLLM 改修・顧客配布に向けた環境構築手順と改修項目整理

作成日: 2026-06-29  
対象: 個人PC上で AnythingLLM を構築し、将来的に顧客配布可能な形へ改修するための初期計画  
前提モデル: `llm-jp/llm-jp-4-8b-thinking`  
前提OS: Windows 11 + WSL2 + Docker Desktop を推奨

---

## 0. 結論

顧客配布を見据えて AnythingLLM を改修する場合、**AnythingLLM Desktop の配布済みバイナリを直接改造する方針は避ける**べきです。

推奨方針は以下です。

```text
推奨:
- AnythingLLM の GitHub ソースコードを fork
- Docker / self-hosted 版をベースに改修
- ローカルLLM推論基盤は Ollama / vLLM / llama.cpp 等に分離
- 顧客配布時は Docker Compose + 自社カスタムイメージ + LICENSE/NOTICE 一式で提供
```

理由は以下です。

- AnythingLLM の GitHub ソースは MIT License で、改変・配布・商用利用に向く。
- Desktop App Terms は、配布済みDesktopアプリの利用に関する制約が強く、改変・再配布・SaaS提供などに注意が必要。
- Docker版は multi-user mode、RBAC、環境変数、永続ボリューム、ネットワーク制御を扱いやすい。
- 顧客配布では、アップデート、脆弱性対応、ログ、データ保存先、外部通信制御を明確にできる構成が必要。

---

## 1. 対象ソフトウェア・ライセンス整理

| 対象 | 利用予定 | ライセンス / 条件 | 商用利用 | 注意 |
|---|---|---|---:|---|
| AnythingLLM GitHubソース | アプリ本体の改修元 | MIT License | 可 | 著作権表示・ライセンス表示を保持 |
| AnythingLLM Desktop配布バイナリ | 個人検証用 | Desktop App Terms | 内部業務利用は可 | 改変・再配布用途では慎重に扱う |
| AnythingLLM Docker/self-hosted | 改修・顧客配布の本命 | MIT Licenseベース | 可 | 顧客配布時は依存物含めてライセンス整理 |
| llm-jp-4-8b-thinking | LLMモデル | Apache-2.0 | 可 | NOTICE/ライセンス表示、出力品質・安全性評価が必要 |
| Ollama | 推論ランタイム候補 | MIT License | 可 | 利用するモデル自体のライセンスは別途確認 |
| Embeddingモデル | RAG検索用 | 未確定 | 要確認 | 日本語RAGでは英語向け標準embedderのままにしない |

---

## 2. 推奨アーキテクチャ

### 2.1 個人PCでの開発・検証構成

```text
Windows 11
└─ WSL2 Ubuntu
   ├─ Git
   ├─ Node.js >= 18
   ├─ Yarn
   ├─ Docker Desktop / Docker Compose
   ├─ AnythingLLM fork
   │  ├─ frontend: Vite + React
   │  ├─ server: Node.js + Express
   │  ├─ collector: Node.js + Express
   │  └─ docker: Docker build / compose
   └─ LLM推論
      ├─ Ollama または
      ├─ vLLM OpenAI-compatible server または
      └─ llama.cpp / GGUF
```

### 2.2 顧客配布時の推奨構成

```text
顧客PC / 顧客サーバ
├─ docker-compose.yml
├─ .env
├─ custom-anythingllm image
├─ storage volume
│  ├─ SQLite DB
│  ├─ parsed documents
│  ├─ vector-cache
│  ├─ logs
│  └─ LanceDB / Vector DB
├─ local LLM runtime
│  ├─ Ollama / vLLM / llama.cpp
│  └─ llm-jp-4-8b-thinking or quantized model
└─ LICENSES/
   ├─ AnythingLLM MIT License
   ├─ llm-jp Apache-2.0 License
   ├─ Ollama MIT License
   ├─ embedding model license
   └─ third-party dependency notices
```

---

## 3. 開発環境構築手順

### 3.1 Windows側の前提

推奨:

```text
- Windows 11
- WSL2 有効化済み
- Ubuntu 22.04 / 24.04
- Docker Desktop + WSL integration
- Git
- VS Code + Remote WSL
- NVIDIA GPUがある場合は最新ドライバ
```

GPUは必須ではないが、ローカルLLMを快適に使うなら NVIDIA RTX系 GPU と VRAM 8GB以上、できれば12GB以上を推奨。

---

### 3.2 WSL2 Ubuntu側の基本セットアップ

```bash
sudo apt update
sudo apt install -y git curl ca-certificates build-essential
```

Node.js は `>=18` が必要。  
nvm を使う場合の例:

```bash
curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
source ~/.bashrc

nvm install 20
nvm use 20
node -v
npm -v
```

Yarn は Corepack 経由を推奨。

```bash
corepack enable
yarn -v
```

---

### 3.3 AnythingLLM fork作成

GitHubで自分または社内Organization配下に fork を作成する。

```bash
git clone https://github.com/<your-org-or-user>/anything-llm.git
cd anything-llm

git remote -v
git remote add upstream https://github.com/Mintplex-Labs/anything-llm.git
```

運用上は、必ず upstream を追跡できるようにしておく。

```bash
git fetch upstream
git checkout master
git merge upstream/master
```

本格改修前に、顧客配布用の安定ブランチを切る。

```bash
git checkout -b product/customer-rag-base
```

---

### 3.4 開発モードで起動する

AnythingLLM の公式READMEでは、開発時に以下の3プロセスを起動する構成が示されている。

- `frontend`
- `server`
- `collector`

初回セットアップ:

```bash
yarn setup
```

生成される `.env` を確認する。

```bash
ls frontend/.env
ls server/.env.development
ls collector/.env
ls docker/.env
```

重要: `server/.env.development` が未設定だと正しく動かない。

3つのプロセスを別ターミナルで起動する。

```bash
# terminal 1
yarn dev:server
```

```bash
# terminal 2
yarn dev:frontend
```

```bash
# terminal 3
yarn dev:collector
```

または、concurrentlyでまとめて起動できる場合:

```bash
yarn dev
```

---

### 3.5 Docker版をソースからビルドする

顧客配布を見据えるなら、開発モードだけでなく Docker版のビルド確認を早めに実施する。

```bash
git clone https://github.com/<your-org-or-user>/anything-llm.git
cd anything-llm

touch server/storage/anythingllm.db

cd docker
cp .env.example .env

docker compose up -d --build
```

起動後、ブラウザで開く。

```text
http://localhost:3001
```

注意:

- `server/storage` を永続化しないと、コンテナ再起動・再作成時にデータを失う。
- Docker版からホスト側の Ollama 等へ接続する場合、`localhost` ではなく `host.docker.internal` を使う。
- Linuxでは環境によって `172.17.0.1` が必要になることがある。

---

## 4. LLMモデル連携方針

### 4.1 前提モデル

対象モデル:

```text
llm-jp/llm-jp-4-8b-thinking
```

基本情報:

| 項目 | 内容 |
|---|---|
| 開発 | 国立情報学研究所 LLM-jp系 |
| モデルサイズ | 約8.59B parameters |
| コンテキスト長 | 65,536 |
| ライセンス | Apache-2.0 |
| 実行候補 | Transformers / vLLM / SGLang / llama.cpp / GGUF互換環境 |

### 4.2 注意: `trust_remote_code`

LLM-jp-4系は、正しく動かすために `trust_remote_code` が必要とされている。  
顧客配布では以下を必須にする。

```text
- モデルリポジトリのコードを事前レビュー
- 使うコミットハッシュを固定
- 本番環境で毎回Hugging Faceから動的取得しない
- Dockerイメージまたは社内ミラーに固定
- SBOM / ライセンス一覧に含める
```

### 4.3 実行方法の選択肢

#### 案A: vLLMでOpenAI-compatible APIとして起動

モデルカードでは vLLM による起動例が示されている。  
AnythingLLM側からは Generic OpenAI-compatible provider として接続するのが現実的。

```bash
pip install vllm
vllm serve "llm-jp/llm-jp-4-8b-thinking"
```

接続先例:

```text
http://localhost:8000/v1
```

Docker版 AnythingLLM からホストの vLLM に接続する場合:

```text
http://host.docker.internal:8000/v1
```

#### 案B: GGUF / llama.cpp / Ollama互換モデルを使う

Hugging Face上には量子化モデルの導線がある。  
GGUFを利用できる場合、AnythingLLMの custom GGUF import または Ollama / LM Studio / llama.cpp を利用する。

注意:

```text
- 公式モデルそのものではなく、第三者の量子化モデルになる可能性がある
- 量子化版のライセンス、作成者、変換条件を別途確認
- 顧客配布するなら、量子化モデルの出所とハッシュを固定
```

---

## 5. RAG / Embedding 方針

AnythingLLMの標準embedderは `all-MiniLM-L6-v2` 系で、主に英語向けである。  
日本語文書RAGでは、標準embedderのまま本番判断しない。

推奨:

```text
初期検証:
- AnythingLLM標準embedderで動作確認のみ

精度検証:
- 日本語対応embeddingモデルを別途選定
- Ollama / LocalAI / LM Studio / Generic OpenAI-compatible embedding endpointで接続

本番前:
- embeddingモデルを固定
- 途中でembeddingモデルを変える場合は全文書の再embedを前提にする
```

注意: AnythingLLM公式ドキュメントでも、embedding provider を変更すると文書の再embedが必要になる旨が説明されている。

---

## 6. `.env` 設定方針

### 6.1 開発・検証用

Docker版 `.env` の最低限の方向性:

```env
SERVER_PORT=3001
STORAGE_DIR="/app/server/storage"

# Telemetry
DISABLE_TELEMETRY="true"

# Security
WORKSPACE_DELETION_PROTECTION=1
DISABLE_SWAGGER_DOCS="true"

# Session
JWT_EXPIRY="1d"
```

### 6.2 Ollamaを使う場合

```env
LLM_PROVIDER='ollama'
OLLAMA_BASE_PATH='http://host.docker.internal:11434'
OLLAMA_MODEL_PREF='<your-model-name>'
OLLAMA_MODEL_TOKEN_LIMIT=4096

EMBEDDING_ENGINE='ollama'
EMBEDDING_BASE_PATH='http://host.docker.internal:11434'
EMBEDDING_MODEL_PREF='<your-embedding-model-name>'
EMBEDDING_MODEL_MAX_CHUNK_LENGTH=8192
```

### 6.3 vLLM / Generic OpenAI互換APIを使う場合

```env
LLM_PROVIDER='generic-openai'
GENERIC_OPEN_AI_BASE_PATH='http://host.docker.internal:8000/v1'
GENERIC_OPEN_AI_MODEL_PREF='llm-jp/llm-jp-4-8b-thinking'
GENERIC_OPEN_AI_MODEL_TOKEN_LIMIT=65536
GENERIC_OPEN_AI_API_KEY='dummy'
```

注意:

- Generic OpenAI-compatible endpoint のストリーミング挙動が合わない場合は `GENERIC_OPENAI_STREAMING_DISABLED="true"` を検討する。
- 外部APIを禁止したい場合、UI非表示だけでなく、バックエンドAPI側でも provider を allowlist 化する。

---

## 7. 顧客配布に向けた改修項目

### 7.1 優先度S: 顧客配布前に必須

| No | 改修項目 | 目的 | 対象層 |
|---:|---|---|---|
| S-01 | 外部LLMプロバイダの無効化 | 顧客文書の外部送信リスクを排除 | frontend / server |
| S-02 | ローカルLLM接続先の固定 | 誤設定・外部接続を防止 | server / env |
| S-03 | Telemetryの既定OFF化 | 顧客環境からの不要な通信を抑制 | server / frontend |
| S-04 | Community Hub / Agent Skill download無効化 | 未検証コード導入を防止 | server / env |
| S-05 | Web browsing / scraping / SQL / File System Agent制限 | RAG用途外の危険操作を排除 | frontend / server / agent |
| S-06 | Swagger API docs無効化 | API構造の露出を減らす | env / server |
| S-07 | ファイルアップロード種別制限 | PDF/DOCX/TXT/MD等に限定 | collector / server / frontend |
| S-08 | ファイルサイズ・ページ数制限 | DoS・メモリ不足を防ぐ | collector / server |
| S-09 | ライセンス表示画面・同梱LICENSES | MIT/Apache等の条件充足 | frontend / 配布物 |
| S-10 | バージョン固定・更新手順 | 顧客環境で再現可能性を確保 | release process |
| S-11 | 脆弱性スキャン導入 | 既知CVE混入を防ぐ | CI/CD |
| S-12 | ログ・保存データ削除手順 | 顧客監査・運用に対応 | docs / server |

---

### 7.2 優先度A: PoC後すぐ検討

| No | 改修項目 | 目的 | 対象層 |
|---:|---|---|---|
| A-01 | UIロゴ・色・文言変更 | 顧客向け製品化 | frontend |
| A-02 | 初期設定ウィザード簡素化 | 非エンジニア顧客でも使えるようにする | frontend |
| A-03 | 管理者以外の文書追加制限 | ナレッジ汚染を防ぐ | server / frontend |
| A-04 | Workspace削除禁止の既定ON化 | 誤削除防止 | env / server |
| A-05 | 出典必須プロンプトの標準化 | RAG回答の信頼性向上 | workspace default |
| A-06 | 「文書外なら不明」回答ルール固定 | ハルシネーション抑制 | prompt / server |
| A-07 | Event Logsの強化 | 顧客監査対応 | server |
| A-08 | バックアップ/リストアコマンド整備 | 運用性向上 | scripts |
| A-09 | 日本語embeddingモデル選定 | 日本語検索精度向上 | model / env |
| A-10 | インストール手順書整備 | 顧客配布に必須 | docs |

---

### 7.3 優先度B: 製品化段階で検討

| No | 改修項目 | 目的 |
|---:|---|---|
| B-01 | 顧客別ライセンスキー / 利用期限 | 契約管理 |
| B-02 | オフラインアップデート機構 | 閉域環境対応 |
| B-03 | 自動バックアップスケジューラ | 運用負荷低減 |
| B-04 | 管理者向け診断画面 | 問い合わせ対応 |
| B-05 | モデル・embeddingのベンチマーク画面 | 導入時検証 |
| B-06 | RAG精度評価用テストセット投入機能 | 品質保証 |
| B-07 | 部署・プロジェクト別ナレッジ分離 | エンタープライズ利用 |
| B-08 | 監査ログのエクスポート | 顧客監査対応 |
| B-09 | 暗号化・秘密情報管理強化 | セキュリティ強化 |
| B-10 | SBOM自動生成 | サプライチェーン管理 |

---

## 8. 改修調査で最初に見るべきコード領域

AnythingLLM monorepo の主な構成:

```text
frontend   : Vite + React UI
server     : Node.js + Express, LLM/VectorDB/Workspace/API管理
collector  : 文書のパース・処理
docker     : Docker build / compose
embed      : Web embed widget
browser-extension : ブラウザ拡張
```

最初に確認する検索コマンド:

```bash
# 外部LLMプロバイダ表示・設定箇所
grep -R "LLM_PROVIDER" -n frontend server collector
grep -R "OpenAI" -n frontend server collector
grep -R "Anthropic" -n frontend server collector
grep -R "Gemini" -n frontend server collector
grep -R "Ollama" -n frontend server collector

# embedding関連
grep -R "EMBEDDING_ENGINE" -n frontend server collector
grep -R "embedder" -n frontend server collector

# telemetry
grep -R "Telemetry" -n .
grep -R "DISABLE_TELEMETRY" -n .

# upload / collector
grep -R "upload" -n server collector frontend
grep -R "mime" -n server collector frontend
grep -R "file type" -n server collector frontend

# agent / tools
grep -R "AGENT" -n server frontend
grep -R "skill" -n server frontend collector
grep -R "COMMUNITY_HUB_BUNDLE_DOWNLOADS_ENABLED" -n .

# API docs / swagger
grep -R "SWAGGER" -n server docker
```

---

## 9. 開発ブランチ戦略

```text
master/upstream
└─ product/customer-rag-base
   ├─ feature/disable-cloud-providers
   ├─ feature/customer-branding
   ├─ feature/upload-policy
   ├─ feature/default-local-model
   ├─ feature/license-screen
   ├─ hardening/security-defaults
   └─ docs/customer-installation-guide
```

推奨ルール:

- upstream同期用ブランチと製品改修ブランチを分離。
- 1改修1ブランチ。
- 顧客配布タグは `customer-rag-vX.Y.Z` のように独自タグを切る。
- upstreamのタグ・コミットも記録する。

例:

```bash
git tag customer-rag-v0.1.0
git notes add -m "Based on upstream AnythingLLM v1.15.0 / commit <hash>"
```

---

## 10. 検証項目

### 10.1 動作検証

| 項目 | 確認内容 |
|---|---|
| 起動 | Docker Composeで起動できる |
| 永続化 | コンテナ再作成後もデータが残る |
| LLM接続 | ローカルLLMだけに接続できる |
| 外部API遮断 | OpenAI等の外部API設定が使えない |
| PDF | テキストPDFをRAG化できる |
| DOCX | Word文書をRAG化できる |
| スキャンPDF | OCRが必要な場合の挙動を確認 |
| 出典 | 回答に根拠文書が表示される |
| 削除 | 文書削除・再embeddingの挙動を確認 |
| 権限 | Defaultユーザーが設定変更できない |

### 10.2 セキュリティ検証

| 項目 | 確認内容 |
|---|---|
| バージョン | 既知脆弱性のある旧版を使っていない |
| API docs | `/api/docs` が無効化されている |
| Agent | Web/SQL/File System系Agentが無効 |
| 外部通信 | 通信先がローカル・許可先に限定されている |
| Telemetry | 送信されない |
| APIキー | 画面・API・ログに漏れない |
| storage | 顧客文書・ログの保存場所が明確 |
| 権限 | multi-user modeでRBACが有効 |
| CORS | 不要な公開がない |
| ポート | 3001等が必要範囲だけに公開されている |

### 10.3 品質検証

| 項目 | 確認内容 |
|---|---|
| 日本語検索 | 日本語質問で該当文書を拾える |
| 日本語回答 | 読みやすく、過度な英語混在がない |
| 不明回答 | 文書内にない場合に捏造しない |
| 長文PDF | 20〜100ページ程度でも破綻しない |
| 表 | Word/PDF内の表がどこまで読めるか |
| 更新 | 文書差し替え時の再embedding手順が明確 |
| 処理時間 | 顧客PCスペックで許容範囲か |

---

## 11. CI/CD・配布物

### 11.1 最低限のCI

```bash
yarn lint
yarn test
docker compose build
```

追加推奨:

```text
- dependency vulnerability scan
- container image scan
- license scan
- SBOM生成
- secret scan
```

候補ツール:

```text
- Trivy
- Grype
- Syft
- Gitleaks
- GitHub Dependabot
- GitHub CodeQL
```

### 11.2 顧客配布パッケージ案

```text
customer-rag-package/
├─ docker-compose.yml
├─ .env.example
├─ install.ps1
├─ start.ps1
├─ stop.ps1
├─ backup.ps1
├─ restore.ps1
├─ README.md
├─ CUSTOMER_INSTALL_GUIDE.md
├─ OPERATIONS_GUIDE.md
├─ SECURITY_GUIDE.md
├─ LICENSES/
│  ├─ AnythingLLM_LICENSE.txt
│  ├─ llm-jp_LICENSE.txt
│  ├─ Ollama_LICENSE.txt
│  ├─ embedding_model_LICENSE.txt
│  └─ THIRD_PARTY_NOTICES.txt
└─ checksums/
   ├─ images.sha256
   ├─ models.sha256
   └─ package.sha256
```

---

## 12. 顧客配布時の法務・ライセンス注意

### 12.1 AnythingLLM

- GitHubソースはMIT License。
- MITは改変・配布・商用利用に向く。
- 著作権表示とライセンス表示を削除しない。
- Desktop配布版のTermsは内部利用に主眼があり、改変・再配布では注意。
- 顧客配布では、配布済みDesktopバイナリではなく、ソースから作成したDocker/self-hosted版をベースにする。

### 12.2 llm-jp-4-8b-thinking

- Apache-2.0。
- 商用利用可能。
- 再配布時はApache-2.0ライセンス文を同梱。
- 改変・量子化・派生モデルを配布する場合は改変表示が必要。
- モデルカード上、出力の安全性・人間意図への整合は十分保証されていない旨があるため、業務利用では人間レビューが必要。

### 12.3 Embeddingモデル

- 未選定。
- RAG精度に直結する。
- 商用利用可能・日本語対応・ローカル実行可能なモデルを別途選定する。
- 顧客配布するなら、embeddingモデルのライセンス・取得元・ハッシュを固定する。

---

## 13. 既知リスク

| リスク | 内容 | 対策 |
|---|---|---|
| Desktop版RCE系脆弱性 | 過去にElectron DesktopでXSS→RCE系の脆弱性が報告 | Desktop配布を避け、最新版Docker/self-hosted版を軸にする |
| Qdrant APIキー漏洩 | 旧版でQdrant APIキー露出の脆弱性 | 旧版禁止、最新版利用、LanceDB既定利用またはキー管理徹底 |
| 外部API誤送信 | 顧客文書が外部LLMへ送信される | provider allowlist化、UI/API両方で制限 |
| Agent暴走 | Web/SQL/File System Agentが顧客環境で危険操作 | 初期無効、必要時のみ許可制 |
| RAGハルシネーション | 文書外の推測を混ぜる | 出典必須、不明回答、プロンプト固定、評価セット |
| embedding不一致 | embeddingモデル変更で過去ベクトルが使えない | モデル固定、変更時は全文書再embed |
| ライセンス漏れ | 依存物・モデル・OCR等の表示漏れ | LICENSES/NOTICE/SBOM整備 |
| アップデート困難 | forkがupstream追従できなくなる | 改修範囲を小さくし、patch化する |

---

## 14. 初期ロードマップ

### Phase 1: 個人PC検証

```text
目的:
- AnythingLLMの開発・Docker起動に慣れる
- PDF/DOCXのRAG精度を確認
- llm-jpモデル接続方式を確定

成果物:
- fork済みリポジトリ
- Docker起動確認
- サンプルPDF/DOCXのRAG結果
- モデル接続メモ
```

### Phase 2: 制限付き社内PoC版

```text
目的:
- 外部APIを使えないようにする
- ローカルLLM固定
- UIを最低限カスタマイズ
- 文書アップロード制限を入れる

成果物:
- custom Docker image
- .env.example
- インストール手順
- 運用手順
```

### Phase 3: 顧客配布候補版

```text
目的:
- 顧客環境で再現可能にする
- ライセンス・セキュリティ・運用手順を整備
- バックアップ/リストアを整備

成果物:
- 配布パッケージ
- LICENSES/NOTICE
- SECURITY_GUIDE
- OPERATIONS_GUIDE
- SBOM
- 検証済みモデル・embedding情報
```

---

## 15. 参考情報

### AnythingLLM

- GitHub: https://github.com/Mintplex-Labs/anything-llm
- LICENSE: https://github.com/Mintplex-Labs/anything-llm/blob/master/LICENSE
- Docker Local Installation: https://docs.anythingllm.com/installation-docker/local-docker
- Docker Overview: https://docs.anythingllm.com/installation-docker/overview
- Configuration: https://docs.anythingllm.com/configuration
- Desktop Terms: https://docs.anythingllm.com/installation-desktop/terms
- Desktop Privacy: https://docs.anythingllm.com/installation-desktop/privacy
- Desktop Storage: https://docs.anythingllm.com/installation-desktop/storage
- Security & Access: https://docs.anythingllm.com/features/security-and-access
- Documents / RAG: https://docs.anythingllm.com/chatting-with-documents/introduction
- Ollama connection troubleshooting: https://docs.anythingllm.com/ollama-connection-troubleshooting
- Connecting to localhost in Docker: https://docs.anythingllm.com/installation-docker/localhost
- Import custom LLMs: https://docs.anythingllm.com/import-custom-models

### llm-jp

- llm-jp-4-8b-thinking model card: https://huggingface.co/llm-jp/llm-jp-4-8b-thinking
- LLM-jp-4 cookbook: https://github.com/llm-jp/llm-jp-4-cookbook
- Apache License 2.0: https://www.apache.org/licenses/LICENSE-2.0

### Ollama

- Ollama LICENSE: https://github.com/ollama/ollama/blob/main/LICENSE
- Ollama GPU support: https://docs.ollama.com/gpu

---

## 16. 次アクション

最初に着手すべき順番:

```text
1. AnythingLLMをfork
2. WSL2 + Node.js + Yarn + Docker環境を整備
3. yarn setupで開発起動
4. Docker compose buildでself-hosted版起動
5. PDF/DOCXのRAG動作確認
6. llm-jp-4-8b-thinkingをvLLMまたはGGUF経由で接続
7. 外部LLMプロバイダ無効化のコード調査
8. 顧客配布用の最小改修ブランチを作成
```
