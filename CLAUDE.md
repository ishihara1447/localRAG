# CLAUDE.md

ローカル RAG 開発プロジェクト。AnythingLLM(OSS) を fork して改修し、完全ローカルで動く日本語 RAG を構築、最終的に**顧客配布可能な形**に仕上げる。詳細計画は `docs/anythingllm_customer_distribution_plan.md`（配布計画書）が一次情報。本ファイルと矛盾したら計画書を正とし、本ファイルを更新する。

## 現在地

- フェーズ: **Phase 1（個人PC検証）の技術タスクは全完了**。製品名は **OTE-RAG（おてらぐ）**（2026-07-13リブランド、日の丸アイコン）。**セッション開始時はまず `docs/HANDOFF.md` を読む**（最新状態・ブロッカー・次手。本ファイルと矛盾したらHANDOFFが正）。
- **対象プラットフォーム（2026-07-08確定）**: Windows（GPU搭載機、RTX 5070 Ti相当以上を想定）。当初のApple Silicon Mac限定戦略は撤回。macOS向け実装は行わない。この変更は当初の批判リスク「士業事務所PCはほぼGPU非搭載」と矛盾するため、対象顧客のGPU保有実態が未検証の新規リスクとして残っている（`fukugyo/ideas/2026-06-29_local-rag-pro.md`の批判・懸念点参照）。
- 済: ハルシネーション対策・日本語CIDフォントPDF対応（upstream未修正のバグをfork側で修正）・日本語PDF字間空白の正規化・APIキー未認証露出の修正（127.0.0.1バインド化）。
- **モデル構成確定（2026-07-16）**: LLM=`gemma4:12b`（Google, Apache-2.0, 非中国系）・Embedding=`bge-m3`（MIT）・Reranker=`bge-reranker-v2-m3`（MIT, ONNX int8。ハイブリッド検索後の「文抽出クッション」で使用）・topN既定8・日本語セパレータ・ハイブリッド検索（dense+BM25+RRF）既定ON。旧LLMの変遷: llm-jp GGUF（テンプレート破損で空回答）→ qwen3:8b（中国系のため2026-07-14に切替）→ gemma4:12b。Phi-4 14Bは架空引用の捏造で不採用。詳細は `docs/HANDOFF.md` および `docs/MODEL_CARDS.md`。
- **配布形態（2026-07-17）**: Windows native v1.2.0。顧客は `OTE-RAG-Setup.exe`（.NET Framework製GUI、`windows-native/setup/OTE-RAG-Setup.cs`）のダブルクリックでインストール（外側zipのSHA-256検証→展開→`install.ps1`実行→ブラウザ起動を自動化）。実機管理者インストールで基本動作確認PASS済み（`docs/WINDOWS_DOUBLE_CLICK_INSTALLER_V1.2.0_2026-07-17.md`）。
- 次（技術）: Setup.exeのコード署名・再起動耐性・完全オフライン・文書投入込みRAG E2E。次（事業・最優先）: 士業へのヒアリングでコア仮説とGPU保有実態を検証（撤退基準期限2026-08-15）。
- 開発用の起動は自前ビルドイメージ＝`runtime/docker-compose.yml`（image 1.0.x）。コミット/pushはユーザーが明示依頼したときのみ。

## 技術スタック / 構成（予定）

- 改修元: `Mintplex-Labs/anything-llm`（MIT）の **GitHub ソース版**。Desktop 配布バイナリは使わない。
- monorepo: `frontend`(Vite+React) / `server`(Node+Express, LLM・VectorDB・Workspace管理) / `collector`(文書パース) / `docker` / `embed`。
- LLM: **`gemma4:12b`**（Google, Apache-2.0, Ollama公式・非中国系）。2026-07-14確定。旧採用のqwen3:8b（中国系）から切替。llm-jp系はコミュニティGGUFのテンプレート破損（本文が生成されない）により撤回。Ollama公式配布モデルのみを使う方針（`trust_remote_code`不要）。
- Vector DB: LanceDB（既定）。Embedding: **`bge-m3`**（MIT, 多言語）。2026-07-11確定。mxbaiは日本語の言い換え検索で正解文書をtop8にも入れられず撤回。**embedding変更時は全文書の再embedが必須**。
- Reranker: **`bge-reranker-v2-m3`**（BAAI, MIT, ONNX int8, 約571MB）。2026-07-16採用。ハイブリッド検索（dense+BM25+RRF, 既定ON）の結果を文単位で再順位付けする「文抽出クッション」で使用（`LANCE_SENTENCE_CUSHION=true` / `RERANKER_QUANTIZED=true`）。
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
