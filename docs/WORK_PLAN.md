# 作業計画（ざっくり版）

作成日: 2026-06-29
一次情報: `anythingllm_customer_distribution_plan.md`（配布計画書）。本計画はその実作業への落とし込み。

進め方の原則: **動くものを早く → 制限をかける → 配布物に固める** の3段階。各フェーズの終わりに「検証(計画書§10)」を回してから次へ。

---

## Phase 0: 足場づくり（今すぐ・半日）

- [x] `git init`(main) し本リポジトリを初期化、`.gitignore` 整備
- [x] 環境確認（Node v22 / Docker 29 / Compose v5 / Ubuntu22.04・WSL2 / **GPU: RTX 5070 Ti 16GB**）→ `docs/ENVIRONMENT.md`
- [x] yarn 導入（classic 1.22.22、`~/.npm-global/bin`）
- [ ] AnythingLLM を `anything-llm/` に clone、`upstream` remote 追加（**fork/push は後回し**のため当面 upstream を直接 clone、origin は後で fork に差し替え）
- [ ] `product/customer-rag-base` ブランチを作成

**完了条件**: clone 済み・upstream 追従可能・ベースブランチがある

> 構成メモ: 本 `localRAG` リポを「製品リポ（docs/packaging/overrides）」、`anything-llm/`（独立 git）を「fork 本体」とする2層構成。`anything-llm/` は親リポからは追跡しない（.gitignore 済）。

---

## Phase 1: 個人PC検証（動かす）

- [ ] `yarn setup` → `yarn dev` で開発起動（frontend/server/collector）
- [ ] `docker compose up -d --build` で self-hosted 版起動、`http://localhost:3001` 確認
- [ ] `server/storage` 永続化を確認（コンテナ再作成でデータが残る）
- [ ] llm-jp-4-8b-thinking を **vLLM(OpenAI互換)** で起動し Generic OpenAI provider で接続（GGUF/Ollama 案も比較）
- [ ] 日本語 embedding モデルを1つ仮選定して接続
- [ ] サンプル PDF/DOCX を投入し RAG 精度・出典表示・日本語回答品質を確認

**成果物**: 起動確認メモ、モデル接続方式の確定、RAG サンプル結果
**検証**: 計画書§10.1（動作）+ §10.3（品質）

---

## Phase 2: 制限付き社内PoC版（締める＝優先度S）

セキュリティ既定値のハードニング。1改修1ブランチ（`hardening/*`, `feature/*`）。

- [ ] S-01/02 外部LLMプロバイダ無効化 + ローカルLLM接続先固定（**API側で provider allowlist**）
- [ ] S-03 Telemetry 既定OFF / S-06 Swagger docs 無効化
- [ ] S-04 Community Hub・Agent Skill download 無効化
- [ ] S-05 Web/SQL/FileSystem 系 Agent を既定無効
- [ ] S-07/08 アップロード種別（PDF/DOCX/TXT/MD）・サイズ/ページ数制限
- [ ] S-09 ライセンス画面 + `LICENSES/` 同梱 / S-10 バージョン固定
- [ ] custom Docker image 化、`.env.example` 整備

**成果物**: custom Docker image、`.env.example`、インストール/運用手順の下書き
**検証**: 計画書§10.2（セキュリティ）— 外部API遮断・Agent無効・Telemetry無送信を実機確認

---

## Phase 3: 顧客配布候補版（固める＝優先度A中心）

- [ ] A-01/02 ブランディング・初期設定ウィザード簡素化
- [ ] A-05/06 出典必須・「文書外は不明」プロンプトを既定化
- [ ] A-09 日本語 embedding モデルを正式選定・固定（ライセンス/取得元/ハッシュ）
- [ ] A-07/08 Event Logs 強化・バックアップ/リストアスクリプト
- [ ] CI: lint/test/build + 脆弱性/ライセンス/secret スキャン（Trivy/Grype/Syft/Gitleaks）+ SBOM
- [ ] 配布パッケージ一式（計画書§11.2）+ 各ガイド（INSTALL/OPERATIONS/SECURITY）

**成果物**: 配布パッケージ、LICENSES/NOTICE/SBOM、各ガイド、検証済みモデル情報

---

## 後回し（優先度B・製品化段階）

ライセンスキー、オフライン更新、自動バックアップ、診断画面、ベンチ画面、部署別ナレッジ分離、監査ログエクスポート、暗号化強化 — 計画書§7.3 参照。

---

## 直近の一手

Phase 0 の `git init` → fork/clone から着手する。GPU の有無で llm-jp の実行方式（vLLM か量子化GGUF か）が変わるため、Phase 1 で接続方式を早めに確定させるのが最重要マイルストーン。
