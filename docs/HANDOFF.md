# 引き継ぎメモ（セッション間ハンドオフ）

最終更新: 2026-06-30 / 次セッション開始時にまずこれを読む。
権威ドキュメント: `CLAUDE.md`（制約集約） / `docs/WORK_PLAN.md`（作業計画） / `docs/ENVIRONMENT.md`（環境・既知問題） / `docs/anythingllm_customer_distribution_plan.md`（配布計画＝一次情報）。

---

## 1. プロジェクト一行説明

AnythingLLM(MIT) を fork 改修し、完全ローカルの日本語RAGを構築 → 顧客配布する。現在 **Phase 1（個人PC検証）**。

## 2. いま動いているもの / 確認コマンド

- **AnythingLLM**: 稼働中 `http://localhost:3001`（公式イメージ、healthy）。
- **vLLM(llm-jp/FP8)**: **停止中**（下記ブロッカーのため `docker compose stop vllm` 済み）。
- 起動定義: `runtime/docker-compose.yml`（AnythingLLM + vLLM。AnythingLLM は vLLM を `http://vllm:8000/v1` に事前配線）。

```bash
cd /home/ishihara1447/projects/localRAG/runtime
docker compose ps
docker ps --format '{{.Names}}\t{{.Status}}' | grep -E 'anythingllm|vllm'
docker logs vllm-llmjp 2>&1 | tail -40        # vLLMの状態
```

> 注意: バックグラウンドのウォッチャー等のタスクは Claude Code 再起動で消える。再開時は手動で状態確認すること。

## 3. ★最優先ブロッカー: vLLM が WSL2 で起動できない

- 症状: `RuntimeError: UVA is not available`（`UvaBuffer`/`StagedWriteTensor`）で **クラッシュループ**（RestartCount 211 まで到達 → stop 済み）。モデル重みDLにも到達していない（HFキャッシュ約13MB）。
- 原因: **vLLM 0.24.0 の新GPUランナー(V2)が UVA(Unified Virtual Addressing/pinned memory) を要求するが、WSL2 では非対応**。FP8 やネットワークとは無関係の WSL2 固有の非互換。
- 対処候補（次セッションで上から順に試す）:
  1. **古い安定版 vLLM イメージに固定**（V2ランナー以前）。例 `vllm/vllm-openai:v0.10.x` / `v0.9.x` などで起動可否を確認。RTX5090+WSL2 で動く構成例あり（下記Source）。
  2. **V2ランナー/非同期スケジューリングを無効化**してみる: 起動ログに "Asynchronous scheduling is enabled" が出ており、その直後に UvaBuffer で落ちる。`--no-enable-async-scheduling` や `VLLM_USE_V1=0` 等の環境変数で V1 経路に落とせないか確認。
  3. **フォールバック = Ollama + 量子化GGUF**（計画§4.3 案B、`docs/ENVIRONMENT.md`の保険）。WSL2で確実に動く。Phase1の「RAG配線検証」を最短で通すならこれが堅い。AnythingLLM 側は `LLM_PROVIDER=ollama` / `OLLAMA_BASE_PATH` に切替（compose の environment を変更）。
  - いずれでも VRAM 16GB のため量子化は必須（bf16=約17GBは収まらない）。

## 4. 既知の環境問題（`docs/ENVIRONMENT.md` に詳細）

- **github.com がコンテナ内DNSで不達**（`curl: (6) Could not resolve host: github.com`）。→ `anything-llm/docker` のソースビルド不可。host の git clone は可だが大容量DLは遅い（sharp の libvips DL失敗）。HF(huggingface.co)は到達OK。
  - Phase2 のカスタムビルド前に **Docker daemon.json に `"dns":["8.8.8.8","1.1.1.1"]` を設定して Docker 再起動**が必要。
- dev モード(`yarn dev`)は server/collector の **sharp ネイティブビルド失敗**中（frontend/env/prisma はOK）。当面 Docker 起動で回避。
- GPU は良好: RTX 5070 Ti 16GB / Driver 591.86 / CUDA 13.1 / Docker に nvidia ランタイム有り。
- ホスト port 8000 は他プロジェクトが使用中 → vLLM は **18000:8000** にマッピング。

## 5. 次のアクション（Phase 1 の残り）

1. 上記ブロッカーを解消し、llm-jp（または代替）を起動 → `curl http://localhost:18000/v1/models` で疎通。
2. AnythingLLM から llm-jp に疎通テスト（UI またはチャットAPI）。
3. サンプル PDF/DOCX を投入し RAG（取込→embed→検索→**出典付き回答**）を検証。
4. 日本語 embedding モデルの選定（標準 all-MiniLM は英語向け）。Phase1 は内蔵embedderで配線確認のみ。
5. （セキュリティ follow-up）`trust_remote_code` の取得コード(`llmjp4_harmony.py`等)をレビューし `--revision` でコミット固定（計画§4.2）。

## 6. Git 状態

- ローカルのみ（**push は当面後回し**、ローカルに細かくコミット）。ブランチ `main`、計10+コミット。
- AnythingLLM fork は `anything-llm/`（**独立 git リポ**、親からは追跡しない）。ブランチ `product/customer-rag-base`、upstream=Mintplex-Labs、v1.15.0 ベース。

## 7. Claude Code セッション運用

- ユーザー方針: **確認・プロンプトを極力減らす**。妥当なデフォルトは自分で決めて進め、事後報告。
- `.claude/settings.local.json` に広い許可リスト（git[push除外]/npm/yarn/docker/ファイル操作系を allow、push・sudo・rm -rf は deny）を記載済み。**起動中セッションが上書きしていたため未反映 → このメモ作成後にユーザーが Claude Code を再起動して反映する**。
- メモリ: `project-localrag` / `feedback-minimize-confirmations` に要点を保存済み。

---

Source（vLLM/WSL2 ブロッカー調査）:
- vLLM Forum: Project: vLLM docker for running smoothly on RTX 5090 + WSL2 — https://discuss.vllm.ai/t/project-vllm-docker-for-running-smoothly-on-rtx-5090-wsl2/1697
- Making vLLM work on WSL2 (DEV) — https://dev.to/docteurrs/making-vllm-work-on-wsl2-482e
- vLLM Troubleshooting — https://docs.vllm.ai/en/latest/usage/troubleshooting/
