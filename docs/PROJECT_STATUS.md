# LocalRAG プロジェクト ステータスまとめ

最終更新: 2026-06-30
位置づけ: プロジェクト全体の作業履歴・現在地・今後の方針を俯瞰するドキュメント。
（次セッションの即時引き継ぎは `docs/HANDOFF.md`、配布ハードニング計画は `docs/OFFLINE_DISTRIBUTION_HARDENING_PLAN.md` を参照）

---

## 1. プロジェクト概要

AnythingLLM(MIT) を fork して改修し、**完全ローカルで動作する日本語 RAG** を構築する。
最終目標は **顧客へオフライン配布可能なパッケージ** に仕上げること。

- 一次計画: `docs/anythingllm_customer_distribution_plan.md`
- 制約集約: `CLAUDE.md` / `AGENTS.md`
- 現フェーズ: **Phase 1（個人PC検証）進行中**

---

## 2. これまでの作業履歴

### Phase 0 — 足場構築（済）
- git / 環境 / Yarn のセットアップ
- AnythingLLM v1.15.0 を clone、`product/customer-rag-base` ブランチで改修開始

### Phase 1 — 検証（進行中）

**(A) 起動とRAG疎通**
- 公式イメージ `mintplexlabs/anythingllm` で `http://localhost:3001` 起動成功
- Ollama を Docker サービス化し、`rag-internal` / `rag-public` でネットワーク分離
  （Ollama は外部非公開、UI ポート 3001 のみ公開）
- RAG パイプライン疎通確認済み:
  - mxbai-embed-large による日本語 embedding
  - LanceDB ベクター検索（正しいチャンクを取得）
  - 出典付き回答、文書外クエリには「不明」応答

**(B) セキュリティ・ハードニング（コード実装）**
- バックエンドに**ローカルプロバイダ allowlist** を実装
  （`getLLMProvider()` / `supportedLLM()` で外部クラウドLLMを拒否）
  ※ 現状は公式イメージ起動のため**実行イメージには未反映**（後述ブロッカー [B3]）
- compose のセキュリティ既定値:
  `DISABLE_TELEMETRY` / `DISABLE_SWAGGER_DOCS` / `WORKSPACE_DELETION_PROTECTION` /
  Community Hub ダウンロードの意図的未設定（完全拒否）/ `HF_HUB_OFFLINE=1`

**(C) オフライン配布パッケージ化**
- `scripts/export.sh` — オンライン環境でパッケージ生成（イメージ save、モデル取得、
  バージョン引数化、digest・git commit 記録、checksum manifest 生成）
- `scripts/install.sh` — オフライン環境で導入（前提チェック、checksum 強制検証、
  ロード後のイメージ実在＆アーキテクチャ検証、ヘルスチェック、外部接続試行の警告）
- `scripts/uninstall.sh` — `--keep-data` 対応の安全な削除
- `scripts/start.sh` / `stop.sh` — 起動・停止
- `scripts/backup.sh` / `restore.sh` — データのバックアップ・復元（整合性確保）
- `scripts/smoke-test.sh` — API/Ollama/GPU/認証/推論の基本確認
- `scripts/rag-e2e-test.sh` — 文書投入→出典付き回答→文書外で不明応答 の自動検証
- `fixtures/test-policy.txt` — 固有値入りの RAG 検証用サンプル文書
- `LICENSES/` + `NOTICE` — 法務情報の雛形（AnythingLLM の MIT 実体を同梱）

---

## 3. 既知のブロッカー

| ID | 内容 | 影響 | 対処方針 |
|----|------|------|----------|
| **[B1]** | vLLM が WSL2 で `UVA is not available` クラッシュ | 高速 LLM 推論が使えない | 回避策で Ollama 採用。Phase2 で UVA パッチ独自イメージ |
| **[B2]** | llm-jp-4-8b-thinking が3分超で実用外 | 本命 LLM が使えない | `OLLAMA_RESPONSE_TIMEOUT` 延長 / 非thinking版 / qwen3 |
| **[B3]** | コンテナ内 DNS 失敗でソースビルド不可 | **allowlist 改修が実行イメージ未反映＝配布不可** | `daemon.json` DNS 修正 → カスタムイメージ化 |

---

## 4. 今後の方針（優先度付き）

判断軸: **配布可否を左右するか > Phase 1 完了に必要か > 品質向上**

### 🔴 P0 — 配布の前提（必須）
- **[B3] Docker DNS 修正 → カスタム AnythingLLM イメージ化**
  これが終わるまで「外部プロバイダをAPI側で拒否」という配布必須要件が満たされない。
  公式 `latest` を独自タグへ差し替え、`latest` 依存を排除する。

### 🟠 P1 — Phase 1 完了に必須
- **[B2] LLM の実用化**（タイムアウト対処、モデル確定）
- **PDF/DOCX の RAG 検証**（実文書パースの確認）
- **日本語 embedding 正式選定**（mxbai 評価 → 不十分なら plamo-embedding-1b。
  変更時は全文書の再 embedding が必須なので「配布モデル凍結」の節目）

### 🟡 P2 — 配布品質
- 既定 system prompt の強制（出典必須・文書外は「不明」）
- `trust_remote_code` のコードレビューとコミットハッシュ固定
- 作成済みスクリプトの実機通しテスト（export→install→smoke→rag-e2e）

### 🟢 P3 — 仕上げ
- 顧客向けドキュメント5点（README/INSTALL/OPERATIONS/SECURITY/TROUBLESHOOTING）
- LICENSES の実ライセンス全文差し替え（配布モデル確定後）
- 完全オフライン実機検証 / Windows PowerShell 版スクリプト

### 着手順の推奨
```
P0[B3] に着手（GUI操作で詰まれば待ち時間に P1[B2] を並行）
 → P1: LLM確定 → RAG品質 → embedding凍結
 → P2: 配布品質 → P3: 仕上げ
```

---

## 5. Git / 運用メモ
- リモート: `git@github.com:ishihara1447/localRAG.git`（SSH、`origin/main`）
- `anything-llm/` は独立リポとして親から追跡しない（`.gitignore`）
- `runtime/anythingllm-storage/`・`runtime/ollama-models/` はコミット禁止（顧客文書・モデル）
