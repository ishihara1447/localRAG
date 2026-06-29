# CLAUDE.md

ローカル RAG 開発プロジェクト。AnythingLLM(OSS) を fork して改修し、完全ローカルで動く日本語 RAG を構築、最終的に**顧客配布可能な形**に仕上げる。詳細計画は `docs/anythingllm_customer_distribution_plan.md`（配布計画書）が一次情報。本ファイルと矛盾したら計画書を正とし、本ファイルを更新する。

## 現在地

- フェーズ: **Phase 1（個人PC検証）進行中**。**セッション開始時はまず `docs/HANDOFF.md` を読む**（最新状態・ブロッカー・次手）。
- 済: Phase0 足場一式（git/env/yarn）、AnythingLLM v1.15.0 clone、**公式イメージで起動（`http://localhost:3001` healthy）**。
- ★ブロッカー: **vLLM が WSL2 の `UVA is not available` でクラッシュ→停止中**（vLLM 0.24.0 V2ランナー非対応）。対処候補=古いvLLM版/V1経路/Ollama-GGUF（`docs/HANDOFF.md`）。
- 次: vLLM起動の解消 → llm-jp 疎通 → PDF/DOCX の RAG 検証 → 日本語 embedding 選定。
- 既知の制約: コンテナ内 github.com DNS 失敗でソースビルド不可（Phase2前に Docker DNS 修正が必要）。dev モードは sharp ビルド失敗中。
- 起動は公式イメージ＝`runtime/docker-compose.yml`。push は当面後回し、ローカルに細かくコミット。

## 技術スタック / 構成（予定）

- 改修元: `Mintplex-Labs/anything-llm`（MIT）の **GitHub ソース版**。Desktop 配布バイナリは使わない。
- monorepo: `frontend`(Vite+React) / `server`(Node+Express, LLM・VectorDB・Workspace管理) / `collector`(文書パース) / `docker` / `embed`。
- LLM: `llm-jp/llm-jp-4-8b-thinking`（Apache-2.0, ctx 65536）。16GB VRAM に bf16(≈17GB)は収まらないため **vLLM + FP8 量子化**で OpenAI 互換 API 提供（GGUF/Ollama は保険）。`--trust-remote-code` 必須＝コミット固定が前提。
- Vector DB: LanceDB（既定）。Embedding は日本語対応モデルを別途選定（標準の `all-MiniLM-L6-v2` は英語向け）。
- 開発環境: Windows 11 + WSL2 Ubuntu + Docker Desktop。Node >= 18（推奨20）、Yarn は Corepack 経由。

## コマンド（fork 取得後）

```bash
yarn setup                 # 初回。frontend/server/collector の .env を生成
yarn dev                   # 3プロセス一括起動（不可なら dev:server / dev:frontend / dev:collector を別端末で）
cd docker && docker compose up -d --build   # self-hosted 版ビルド起動 → http://localhost:3001
yarn lint && yarn test     # CI 相当
```

- 永続化: `server/storage` をボリュームに残さないと再作成でデータ消失。
- Docker からホストの LLM へは `localhost` でなく `host.docker.internal`（環境により `172.17.0.1`）。

## 絶対に守るルール（顧客配布前提の制約）

- 顧客文書を**外部に送信しない**。OpenAI/Anthropic/Gemini 等の外部 LLM・embedding プロバイダを有効化しない。制限は UI 非表示だけでなく**バックエンド API 側で provider を allowlist 化**する。
- Desktop 配布バイナリを改造・再配布しない。配布物は必ず**ソースからビルドした Docker/self-hosted 版**を基にする。
- ライセンス表示・著作権表示を削除しない（AnythingLLM=MIT, llm-jp=Apache-2.0, Ollama=MIT, embedding=要確認）。配布時は `LICENSES/` と NOTICE を同梱。
- embedding モデルを途中で変えない。変える場合は**全文書の再 embed が必須**。
- `trust_remote_code` 必須のモデルは、コードを事前レビューし**コミットハッシュを固定**。本番で Hugging Face から動的取得しない。
- Telemetry は既定 OFF（`DISABLE_TELEMETRY="true"`）。Swagger docs・Community Hub/Agent Skill download・Web/SQL/FileSystem 系 Agent は既定で無効。
- バージョンは固定。旧版は使わない（Desktop の XSS→RCE 系、旧 Qdrant の APIキー露出など既知脆弱性があるため）。
- RAG 回答は**出典必須・文書外は「不明」**を既定プロンプトで強制し、ハルシネーションを抑える。

## Git / ブランチ運用

- `upstream`(Mintplex-Labs) を追跡。同期用ブランチと製品改修ブランチを分離する。
- 製品ベース: `product/customer-rag-base`。改修は **1改修1ブランチ**（`feature/*`, `hardening/*`, `docs/*`）。
- 配布タグは `customer-rag-vX.Y.Z`。`git notes` に基にした upstream バージョン/コミットを記録。
- コミット/プッシュはユーザーが明示的に依頼したときのみ。

## 作業方針

- 改修範囲は小さく保ち、upstream 追従できるよう patch 化を意識する。
- コード調査の起点は計画書 §8 の grep 一覧（`LLM_PROVIDER` / `EMBEDDING_ENGINE` / `Telemetry` / `SWAGGER` / `AGENT` など）。
- 改修項目の優先度（S/A/B）は計画書 §7 に従う。S は配布前必須。
