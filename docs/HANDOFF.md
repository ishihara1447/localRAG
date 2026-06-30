# 引き継ぎメモ（セッション間ハンドオフ）

最終更新: 2026-06-30 / 次セッション開始時にまずこれを読む。
権威ドキュメント: `CLAUDE.md`（制約集約） / `docs/WORK_PLAN.md`（作業計画） / `docs/ENVIRONMENT.md`（環境・既知問題） / `docs/anythingllm_customer_distribution_plan.md`（配布計画＝一次情報）。

---

## 1. プロジェクト一行説明

AnythingLLM(MIT) を fork 改修し、完全ローカルの日本語RAGを構築 → 顧客配布する。現在 **Phase 1（個人PC検証）進行中、RAGパイプライン疎通確認済み**。

## 2. いま動いているもの / 確認コマンド

- **AnythingLLM**: `http://localhost:3001`（healthy）。
  - LLM: `llama3.1:8b` via ホスト Ollama（Phase1 検証用、後述の理由でテンポラリ）。
  - Embedding: `mxbai-embed-large:latest` via ホスト Ollama（Japanese 対応, 334MB F16）。
  - VectorDB: LanceDB（内蔵）。
- **Ollama**: ホストプロセス (root, PID ~2293, 127.0.0.1:11434)。
  - 搭載モデル: `hf.co/mmnga-o/llm-jp-4-8b-thinking-gguf:Q4_K_M`, `llama3.1:8b`, `mxbai-embed-large:latest`, `qwen3:8b`, `qwen3:14b`。
- **vLLM**: 停止中（下記ブロッカー参照）。

```bash
cd /home/ishihara1447/projects/localRAG/runtime
docker compose ps
curl -s http://localhost:3001/api/ping           # {"online":true}
curl -s http://localhost:11434/api/tags | python3 -c "import sys,json; [print(m['name']) for m in json.load(sys.stdin)['models']]"
```

## 3. Phase 1 RAGパイプライン検証結果（今セッションで確認済み）

### ✅ 疎通確認済み項目

| 項目 | 結果 |
|------|------|
| Ollama ↔ AnythingLLM 接続 | OK（`network_mode:host` で 127.0.0.1 到達）|
| mxbai-embed-large で日本語 embed | OK（2チャンクに分割してベクター化）|
| LanceDB ベクター検索 | OK（スコア 0.77 / 0.74 で正しいチャンク取得）|
| 出典付き RAG 回答 | OK（「第3条パスワード管理: 12文字以上、90日ごと」を正確に回答）|
| 文書外クエリ → 不明応答 | OK（「文書に含まれていないため分かりません」）|

### 確認方法（REST API キー: `ZDFAHSS-KRA4P6P-GB1GH33-9J34J3D`）

```bash
# ワークスペースへ文書アップロード・embed
curl -X POST http://localhost:3001/api/v1/document/upload \
  -H "Authorization: Bearer ZDFAHSS-KRA4P6P-GB1GH33-9J34J3D" \
  -F "file=@/path/to/doc.txt;type=text/plain" \
  -F "addToWorkspaces=rag"

# RAG チャット
curl -X POST http://localhost:3001/api/v1/workspace/rag/chat \
  -H "Authorization: Bearer ZDFAHSS-KRA4P6P-GB1GH33-9J34J3D" \
  -H "Content-Type: application/json" \
  -d '{"message": "質問内容", "mode": "query"}'
```

## 4. ★ブロッカー・既知問題

### [B1] vLLM が WSL2 で起動できない（未解決）

- 症状: `RuntimeError: UVA is not available` (GPUModelRunnerV2, WSL2 非対応)。
- 試したこと: `VLLM_USE_V1=0`（0.24.0 では V0 エンジン削除済みで無効）、`--enforce-eager`（V2 ランナー選択は compile 前で無効）。
- **現在の回避策**: ホスト Ollama + llama3.1:8b (Phase1 検証用)。
- **本番対応**: Phase2 で Docker DNS 修正後、Dockerfile で GPUModelRunnerV2 の UVA チェックをパッチした独自 vLLM イメージをビルド。
  - 参考: https://discuss.vllm.ai/t/project-vllm-docker-for-running-smoothly-on-rtx-5090-wsl2/1697

### [B2] llm-jp-4-8b-thinking が実用速度で使えない（未解決）

- 症状: 単純な質問でも 3分13秒（thinking フェーズで大量トークン生成）。AnythingLLM のデフォルト HTTP タイムアウト（5分未満）を超えてしまう。
- **対処方法（次セッション）**: compose に `OLLAMA_RESPONSE_TIMEOUT=1200000`（20分）を追加し、`OLLAMA_MODEL_PREF=hf.co/mmnga-o/llm-jp-4-8b-thinking-gguf:Q4_K_M` に戻す。また thinking OFF (`/no_think` システムプロンプト) も試す。
- **代替**: llm-jp-4 の非 thinking 版 GGUF があれば最善。または qwen3:8b（高速, 日本語対応）で継続。

### [B3] コンテナ内 github.com DNS 失敗（未解決、Phase2 課題）

- Docker ビルド内で `github.com` が解決できないため `anything-llm/docker` のソースビルド不可。
- **対処**: Docker Desktop daemon.json に `"dns":["8.8.8.8","1.1.1.1"]` を設定して再起動（要 Docker Desktop GUI）。

### [W1] 現在のネットワーク構成が配布向きでない（要改修）

- 問題: AnythingLLM は `network_mode:host` でホスト Ollama (127.0.0.1:11434) に接続中。
  - これは「ホスト 11434 がすでに使用中（ホスト Ollama）」のためのワークアップ。
- **配布向け正しい構成**: Ollama も Docker サービスとして compose に含め、Docker 内部ネットワーク (`http://ollama:11434`) で接続する。`network_mode:host` は不要になる。
- ホスト Ollama と port 競合する場合は `docker compose stop` してホスト Ollama を一時停止するか、`ports: "11435:11434"` で別ポートに出す。

## 5. 次のアクション

### 即座に取り組む（次セッション優先）

1. **[W1] 配布向けネットワーク構成に修正**: compose の Ollama サービスを復活、`network_mode:host` を撤廃、`depends_on: ollama` を追加。ホスト Ollama と競合しないよう `ports: "11435:11434"` にする。
2. **[B2] llm-jp-4-8b-thinking タイムアウト対処**: `OLLAMA_RESPONSE_TIMEOUT=1200000` を追加し、llm-jp-4 に戻してテスト。
3. **PDF/DOCX テスト**: サンプル PDF をアップロードして RAG が動くか確認。
4. **日本語 embedding 正式選定**: mxbai-embed-large で実用水準か評価。不十分なら multilingual-e5-large 等に変更。

### Phase 1 残タスク（B1, B2 解消後）

5. `trust_remote_code` コードレビュー（llm-jp-4-8b-thinking のモデルコード）とコミットハッシュ固定。
6. RAG 回答の「出典必須・文書外は不明」を既定プロンプトで強制（ワークスペースの system prompt 設定）。
7. Phase 2 準備: Docker DNS 修正 → anything-llm/docker ソースビルド。

## 6. 現在のファイル構成

- `runtime/docker-compose.yml`: AnythingLLM + Ollama サービス定義（現在は Ollama がコメントアウト、`network_mode:host` で代用中）。
- `runtime/anythingllm-storage/`: データ永続化ボリューム（DB, ベクター, 設定）。
- `anything-llm/`: AnythingLLM fork（branch: `product/customer-rag-base`）。

## 7. 配布環境について（ユーザー確認事項 2026-06-30）

**配布は Docker コンテナ前提で正しい方向。** ただし現在は開発ワークアラウンドが混在：

| コンポーネント | 現状 | 配布向け正解 |
|---|---|---|
| AnythingLLM | Docker (`mintplexlabs/anythingllm`) ✅ | そのまま |
| LLM (Ollama) | ホストプロセス (root, 127.0.0.1:11434) ❌ | Docker サービス `ollama/ollama` |
| LLM (vLLM) | 停止中 ❌ | Docker サービス（要 WSL2 パッチ）|
| Embedding | ホスト Ollama 経由 (mxbai-embed-large) ❌ | Docker Ollama 経由 |
| VectorDB | AnythingLLM 内蔵 (LanceDB) ✅ | そのまま |

配布時は `docker compose up -d` 一発で全コンポーネントが起動し、ホスト環境に依存しない構成にすること（Phase 2 の課題）。

## 8. Git 状態

- ローカルのみ（**push は当面後回し**）。ブランチ `main`。
- 今セッションのコミット対象: `runtime/docker-compose.yml`（Ollama フォールバック構成）。

## 9. Claude Code セッション運用

- ユーザー方針: **確認・プロンプトを極力減らす**。妥当なデフォルトは自分で決めて進め、事後報告。
- `.claude/settings.local.json` に広い許可リスト済み（`Bash(curl *)` を今セッションで追加）。
- メモリ: `~/.claude/projects/-home-ishihara1447-projects-localRAG/memory/` に保存済み。

---

Source（vLLM/WSL2 ブロッカー調査）:
- vLLM Forum: Project: vLLM docker for running smoothly on RTX 5090 + WSL2 — https://discuss.vllm.ai/t/project-vllm-docker-for-running-smoothly-on-rtx-5090-wsl2/1697
- Making vLLM work on WSL2 (DEV) — https://dev.to/docteurrs/making-vllm-work-on-wsl2-482e
- vLLM Troubleshooting — https://docs.vllm.ai/en/latest/usage/troubleshooting/
