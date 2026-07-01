# LocalRAG プロジェクト ステータスまとめ

最終更新: 2026-07-02
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

**(B) セキュリティ・ハードニング（実行イメージに反映済み）**
- バックエンドに**ローカルプロバイダ allowlist** を実装
  （`getLLMProvider()` / `supportedLLM()` で外部クラウドLLMを拒否）
  → `anything-llm/`(`product/customer-rag-base`)からカスタム image
  `localrag-anythingllm:1.0.0` をビルドし、**実行イメージに反映済み**。
  実機確認: API 経由で `LLMProvider=openai` を指定 →
  `"openai is not a permitted LLM provider in this build"` で拒否を確認。
- compose のセキュリティ既定値:
  `DISABLE_TELEMETRY` / `DISABLE_SWAGGER_DOCS` / `WORKSPACE_DELETION_PROTECTION` /
  Community Hub ダウンロードの意図的未設定（完全拒否）/ `HF_HUB_OFFLINE=1`
  実機確認: `/api/docs` に Swagger UI が出ないことを確認済み。

**(C) オフライン配布パッケージ化**
- `scripts/export.sh` — オンライン環境でパッケージ生成（イメージ save、モデル取得、
  バージョン引数化、digest・git commit 記録、checksum manifest 生成）。
  カスタム image はレジストリに存在しないため pull せずローカル image を
  使う設計に対応済み。相対パス出力先・ollama root所有ファイルの権限問題を
  修正済み。実機で export→checksum検証まで完走確認済み（9.3GBパッケージ）。
- `scripts/install.sh` — オフライン環境で導入（前提チェック、checksum **強制**検証
  ＝欠落・不一致で停止、イメージ読込、ヘルスチェック）。
- `scripts/uninstall.sh` — `--keep-data` 対応の安全な削除。versions.lock から
  実際の image 名を読み取って削除（image 名変更に追従）。
- `scripts/start.sh` / `stop.sh` — 起動・停止
- `scripts/backup.sh` / `restore.sh` — データのバックアップ・復元（整合性確保）
- `scripts/smoke-test.sh` — API/Ollama/GPU/認証/推論の基本確認
- `scripts/rag-e2e-test.sh` — 文書投入→出典付き回答→文書外で不明応答→
  外部provider拒否→Swagger無効、までの自動検証（実機で全項目PASS確認済み）
- `fixtures/test-policy.txt` — 固有値入りの RAG 検証用サンプル文書
- `LICENSES/` + `NOTICE` — AnythingLLM(MIT)・Ollama(MIT)・Apache-2.0
  (llm-jp/mxbai-embed-large)・Llama 3.1 Community License の**実ライセンス
  全文**を公式配布元から取得して同梱済み。
- `docs/customer/` — README / INSTALL_GUIDE / OPERATIONS_GUIDE /
  SECURITY_GUIDE / TROUBLESHOOTING の5点を作成済み（`export.sh`が
  自動でパッケージ直下にコピーする）。
- `scripts/*.ps1` — Windows PowerShell版
  (install/start/stop/backup/restore/uninstall) を作成済み。
  ※ 開発環境にPowerShell処理系が無いため目視レビューのみ、Windows実機
  未検証。

---

## 3. 既知のブロッカー

| ID | 内容 | 影響 | 対処方針 | 状態 |
|----|------|------|----------|------|
| **[B1]** | vLLM が WSL2 で `UVA is not available` クラッシュ | 高速 LLM 推論が使えない | 回避策で Ollama 採用。Phase2 で UVA パッチ独自イメージ | 未解決 |
| **[B2]** | llm-jp-4-8b-thinking が3分超で実用外 | 本命 LLM が使えない | `OLLAMA_RESPONSE_TIMEOUT` 延長 / 非thinking版 / qwen3 | 未解決 |
| **[B3]** | コンテナ内 DNS 失敗でソースビルド不可 | allowlist 改修が実行イメージ未反映＝配布不可 | `docker build --network=host` でビルド。追加で `release-assets.githubusercontent.com` へのDNS解決がWSL2側で断続的に失敗する問題があり、`--add-host` で回避 | **解決済み(2026-07-02)**。`localrag-anythingllm:1.0.0` ビルド・切替・実機確認済み |

---

## 4. 今後の方針（優先度付き）

判断軸: **配布可否を左右するか > Phase 1 完了に必要か > 品質向上**

### 🔴 P0 — 配布の前提（必須） → **完了(2026-07-02)**
- ~~[B3] Docker DNS 修正 → カスタム AnythingLLM イメージ化~~ 完了。
  `runtime/docker-compose.yml` / `scripts/export.sh` とも
  `localrag-anythingllm:1.0.0` に切替済み、`mintplexlabs/anythingllm:latest`
  への依存は解消。外部provider拒否を実機確認済み。

### 🟠 P1 — Phase 1 完了に必須（未着手）
- **[B2] LLM の実用化**（タイムアウト対処、モデル確定）
- **PDF/DOCX の RAG 検証**（実文書パースの確認）
- **日本語 embedding 正式選定**（mxbai 評価 → 不十分なら plamo-embedding-1b。
  変更時は全文書の再 embedding が必須なので「配布モデル凍結」の節目）

### 🟡 P2 — 配布品質
- 既定 system prompt の強制（出典必須・文書外は「不明」）— 未着手
- `trust_remote_code` のコードレビューとコミットハッシュ固定 — 未着手
- 作成済みスクリプトの実機通しテスト（export→install→smoke→rag-e2e）
  — **export→checksum検証・smoke-test・rag-e2e-testは実機確認済み**。
  install.sh のフルサイクル（新規マシン相当でのゼロからの導入）は未検証。

### 🟢 P3 — 仕上げ
- ~~顧客向けドキュメント5点~~ 完了 (`docs/customer/`)
- ~~LICENSES の実ライセンス全文差し替え~~ 完了
  （AnythingLLM/Ollama/Apache-2.0/Llama 3.1 Community License）
- ~~Windows PowerShell 版スクリプト~~ 完了（Windows実機未検証、目視レビューのみ）
- 完全オフライン実機検証（P4、ネットワーク遮断環境での通し確認）— 未着手
- SBOM・MODEL_CARDS の作成 — 未着手

### 着手順の推奨（次セッション）
```
P1: LLM確定([B2]) → RAG品質(PDF/DOCX検証) → embedding凍結
 → P2: system prompt強制 → trust_remote_codeレビュー → install.shフルサイクル実機検証
 → P3: 完全オフライン実機検証 → SBOM/MODEL_CARDS
```

---

## 5. Git / 運用メモ
- リモート: `git@github.com:ishihara1447/localRAG.git`（SSH、`origin/main`）
- `anything-llm/` は独立リポとして親から追跡しない（`.gitignore`）
- `runtime/anythingllm-storage/`・`runtime/ollama-models/` はコミット禁止（顧客文書・モデル）
