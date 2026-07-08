# 引き継ぎメモ（セッション間ハンドオフ）

最終更新: 2026-07-08（Claude・P1全項目完了: ハルシネーション対策/日本語PDF修正/embedding選定。image 1.0.2） / 次セッション開始時にまずこれを読む。

> **P1完了（2026-07-08）**: Phase 1完了に必須の技術タスクはすべて消化した。残るPhase 1タスクは
> **士業ヒアリング（核心仮説「士業はローカルAIに金を払うか」の検証）のみ**で、これはユーザー自身の作業。
> 技術側の次はP2（配布品質: trust_remote_codeレビュー・install.shフルサイクル検証）。
権威ドキュメント: `AGENTS.md`/`CLAUDE.md`（制約集約） → 本ファイル → `docs/OFFLINE_DISTRIBUTION_HARDENING_PLAN.md`（配布ハードニング計画） → `docs/PROJECT_STATUS.md`（俯瞰） → `docs/anythingllm_customer_distribution_plan.md`（配布計画＝一次情報）。

---

## 1. プロジェクト一行説明

AnythingLLM(MIT) を fork 改修し、完全ローカルの日本語RAGを構築 → 顧客配布する。**Phase 1（個人PC検証）進行中**。オフライン配布パッケージの P0（配布必須要件）は完了し、P1（LLM/embedding確定）が次の焦点。

## 2. いま動いているもの / 確認コマンド

- **AnythingLLM**: `http://localhost:3001`（healthy）。
  - image: **`localrag-anythingllm:1.0.0`**（`anything-llm/`(`product/customer-rag-base`)からカスタムビルド。外部LLM provider allowlist改修が反映済み。公式 `mintplexlabs/anythingllm:latest` は使用していない）。
  - LLM: `hf.co/mmnga-o/llm-jp-4-8b-thinking-gguf:Q4_K_M`（2026-07-04にClaudeが切替。[B2]参照）。
  - Embedding: `mxbai-embed-large:latest`（Apache-2.0, 日本語対応）。
  - VectorDB: LanceDB（内蔵）。
- **Ollama**: Docker サービス（`rag-ollama`, `rag-internal` ネットワーク、外部非公開）。ホストプロセスは使っていない。

```bash
cd /home/ishihara1447/projects/fukugyo/repos/localRAG/runtime
docker compose ps
curl -s http://localhost:3001/api/ping           # {"online":true}
```

## 3. 今セッションでの主な作業（2026-07-02）

前回セッションの「Codexレビュー」(`docs/OFFLINE_DISTRIBUTION_HARDENING_PLAN.md`)への対応が不十分だったとの追加指摘(`docs/CLAUDE_CODE_REVIEW_FEEDBACK_2026-07-02.md`)を受け、優先度順に対応。**全項目コミット・push済み**。

1. **P0: カスタム AnythingLLM image 化**（最重要・完了）
   - DNS問題の根本原因判明: WSL2のDNSプロキシが特定ホスト（`release-assets.githubusercontent.com`、GitHub releaseアセット配信）への断続的な解決失敗を起こす。`getent hosts`は成功するのに`curl`は失敗する再現性のある症状。
   - 対処: `docker build --network=host --add-host=release-assets.githubusercontent.com:185.199.108.133 ...` でビルド成功。
   - `runtime/docker-compose.yml` / `scripts/export.sh` の既定imageを `localrag-anythingllm:1.0.0` に切替。
   - 実機確認: 外部provider(openai)指定 → API側で拒否、Swagger docs無効、smoke-test・rag-e2e-test全PASS。
2. **export.sh/install.sh/backup.shのバグ修正**
   - `package.sha256`/`ollama-models.sha256`生成が`xargs`にシェル関数を渡していて不安定 → `while read`に統一。
   - `install.sh`のchecksum検証が欠落時に「スキップ」していた → 3種のchecksum必須化、欠落・不一致で停止。
   - `versions.lock`に`unknown`が残り得た → git commit/image digest取得失敗時にexportを失敗させる。ローカルビルドimageはRepoDigestを持たないためimage IDにフォールバック。
   - `backup.sh`のtar追記バグ（`.tar.gz`作成後に別名`.tar`へ追記しようとして失敗）を修正。
   - **実機で発見した追加バグ**（当初のレビュー指摘には無かったもの）:
     - `export.sh`: `--output`に相対パスを渡すと`cd`後に意図しない場所へ書き込む → 絶対パスへ正規化。
     - `export.sh`: ollamaコンテナがroot権限で`/root/.ollama`配下(`id_ed25519`等)をroot所有・600権限で作成し、ホスト側非rootユーザーがchecksum生成時に読めず失敗 → コンテナ経由でchownして解決。
     - `uninstall.sh`: image名が`mintplexlabs/anythingllm`のままハードコードされ、カスタムimage化後は削除対象を見つけられなかった → `versions.lock`から実際のimage名を読み取るよう修正。
     - `smoke-test.sh`: Ollama疎通確認が`wget`依存だったが、カスタムimageのベース(Ubuntu 24.04)には`wget`が無く`curl`のみ存在 → `curl`ベースに変更。
3. **rag-e2e-test.shの拡充**: 外部provider拒否・Swagger無効の検証を追加（計画§10.4の未実装項目）。文書外質問の「不明」判定パターンがLLM応答の表現ゆれで誤FAILすることも発見・パターン拡張。
4. **LICENSES/NOTICE**: AnythingLLM(MIT)/Ollama(MIT)/Apache-2.0(llm-jp・mxbai-embed-large)/Llama 3.1 Community Licenseの実ライセンス全文を公式配布元から取得して同梱。
5. **顧客向けドキュメント5点**: `docs/customer/`にREADME/INSTALL_GUIDE/OPERATIONS_GUIDE/SECURITY_GUIDE/TROUBLESHOOTINGを作成（`export.sh`が自動でパッケージ直下にコピー）。
6. **Windows PowerShell版スクリプト**: install/start/stop/backup/restore/uninstallの6本を作成。

### 追加作業（Windows 11 + WSL2 + Docker Engine 方針の検証 / 2026-07-02）

- Docker Desktop を使わない方針を現環境で検証。
  - WSL2 `Ubuntu-22.04` 上の Docker Engine (`unix:///var/run/docker.sock`) が使われていることを確認。
  - Windows 側 Docker context は `desktop-linux` を指しており、PowerShell から Docker を直接叩く実装は方針に合わないことを確認。
  - Docker service は `active` / `enabled`。
  - NVIDIA GPU (`NVIDIA GeForce RTX 5070 Ti`, 16GB級VRAM) が WSL2 と `rag-ollama` コンテナ内の両方で認識されることを確認。
  - `nvidia-container-toolkit` (`1.19.0`) と Docker runtime `nvidia` を確認。
- `scripts/*.ps1` を Docker Desktop 前提の直接 Docker 操作から、WSL2 内の既存 bash スクリプトを呼ぶ薄いランチャーへ変更。
  - 共通ヘルパー: `scripts/localrag-wsl-launcher.ps1`
  - `export.sh` は `.ps1` ランチャーも配布パッケージへ同梱する。
  - PowerShell → WSL2 → bash → Docker 経路で `smoke-test.sh` 実行成功。
- `docs/customer/INSTALL_GUIDE.md` に Windows 11 + WSL2 手順を追記。
- 検証詳細は `docs/WINDOWS_WSL2_VALIDATION_REPORT_2026-07-02.md`。

注意: UNC 上の `.ps1` は既定 ExecutionPolicy でブロックされた。顧客手順では `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1` を明記する。

### 実機検証で確認できたこと（今セッション）

- `bash scripts/export.sh --version 1.0.0 --output ./dist/localrag-1.0.0` が成功し、9.3GBのパッケージを生成。
- `checksums/{images,ollama-models,package}.sha256` すべて `sha256sum -c` で検証OK。
- `versions.lock` に `unknown` が残らないことを確認。
- `rag-e2e-test.sh`・`fixtures/`・`LICENSES/`・`NOTICE`・顧客向けdocsがすべて正しくパッケージに同梱されることを確認。
- 検証後、`dist/`は削除済み（`.gitignore`対象、ローカルにも残していない）。

### まだ検証していないこと

- `install.sh`のフルサイクル（今回生成した`dist/localrag-1.0.0/`を使って実際にゼロから`bash install.sh`を実行する検証）。現在稼働中のコンテナと名前・ポートが衝突するため、このセッションでは実施しなかった。
- 生成済み配布パッケージ上での PowerShell ランチャー動作確認（共通ランチャー経由の `smoke-test.sh` は現環境で確認済み）。
- 完全オフライン（ネットワーク遮断）環境での通し検証（計画のP4）。
- APIキー未設定のため、今回の Windows/WSL2 再検証では `rag-e2e-test.sh` は未実行。

## 4. ★未解決ブロッカー

### [B1] vLLM が WSL2 で起動できない（未解決）

- 症状: `RuntimeError: UVA is not available` (GPUModelRunnerV2, WSL2 非対応)。
- **現在の回避策**: Docker Ollama + `llama3.1:8b`。
- **本番対応（未着手）**: Dockerfile で GPUModelRunnerV2 の UVA チェックをパッチした独自 vLLM イメージをビルド。
  - 参考: https://discuss.vllm.ai/t/project-vllm-docker-for-running-smoothly-on-rtx-5090-wsl2/1697

### [B2] llm-jp-4-8b-thinking が実用速度で使えない → **解決済み（2026-07-08、RAGフルパス検証完了）**

- 従来症状: 単純な質問でも 3分13秒（thinking フェーズで大量トークン生成）。AnythingLLM のデフォルト HTTP タイムアウトを超える。
- **2026-07-04 実施した対処**:
  1. `runtime/docker-compose.yml` に `OLLAMA_RESPONSE_TIMEOUT=1200000`（20分）を有効化。
  2. `OLLAMA_MODEL_PREF` を `hf.co/mmnga-o/llm-jp-4-8b-thinking-gguf:Q4_K_M` に切替、`docker compose up -d anythingllm` でコンテナ再作成 → `healthy` 復帰・`/api/ping` 正常を確認。
  3. `docker exec rag-ollama ollama run ...` で生Ollama呼び出しを2回実測: 1回目（コールドスタート）**6.6秒**、2回目（ウォーム、就業規則要約という多少実務的な質問）**1.06秒**。GPU（RTX 5070 Ti）がしっかり効いており、当初の「3分13秒」は再現しなかった。
- **2026-07-08 実施したRAGフルパス検証**: AnythingLLM管理画面を使わず、`POST /api/system/generate-api-key`をAPI直叩きでAPIキーを発行（single-user mode・AUTH_TOKEN未設定のため無認証で発行可能だった）。`LOCALRAG_API_KEY=<key> bash scripts/rag-e2e-test.sh`を2回実行:
  - ワークスペース作成→文書アップロード・embedding→文書内質問（RAG検索＋LLM推論＋出典付き回答）→文書外質問→外部provider拒否確認→Swagger無効確認、の全6ステップが**合計6.4秒**で完走（タイムアウトなし）。当初懸念していた「3分13秒」は文書検索を挟んだフルパスでも再現せず、[B2]は完全解消と判断してよい。
  - 文書内質問（「有給休暇は年間何日か」）には正しく「22」を含む回答＋出典1件が返り、PASS。
  - **新たに発見した問題**: 文書外質問（文書に無い情報を聞く）に対して、AnythingLLMが「不明」と答えずに出典付きで回答してしまい、FAIL（ハルシネーションの疑い）。これは`CLAUDE.md`の絶対ルール「RAG回答は出典必須・文書外は『不明』を既定プロンプトで強制」が未実装であることを示す。下記P1に追加。
- 使用したテスト用APIキーはすべてテスト後に`DELETE /api/system/api-key/:id`で削除済み。

### [B3] コンテナ内DNS失敗 → **解決済み（2026-07-02）**

`docker build --network=host --add-host=release-assets.githubusercontent.com:<IP>` でカスタムimageビルド成功。詳細は上記セクション3参照。

## 5. 次のアクション（優先度順）

### P1 — Phase 1 完了に必須

1. ~~**[B2] フルパス検証**~~ → **完了（2026-07-08）**。6ステップ合計6.4秒、タイムアウトなし。詳細は上記[B2]セクション参照。
2. ~~**RAG回答の「出典必須・文書外は不明」を既定システムプロンプトで強制**~~ → **完了（2026-07-08）**。fork commit `b29d5567`で`saneDefaultSystemPrompt`を日本語RAG厳格版に変更（出典必須・文書外は「提供された文書には該当する情報がありません」・日本語回答強制）。image 1.0.1に反映しrag-e2e-test.shで文書外質問の不明応答を確認済み。
3. ~~**PDF/DOCX テスト**~~ → **完了（2026-07-08）**。DOCXは素通し成功。**日本語CIDフォントPDFは取り込み失敗するバグを発見・修正**（fork commit `5773dc9f`: pdf-parse同梱の古いpdf.jsがcMap非対応 → pdfjs-dist@4.4.168+同梱cMapsに切替。upstream masterも未修正の制約だった）。image 1.0.2に反映、fixtures/test-expense.pdf（CIDフォント）＋test-attendance.docxで検証、rag-e2e-test.shに回帰テスト[3b][3c]を追加（11/11 PASS）。
4. ~~**日本語 embedding 正式選定**~~ → **mxbai-embed-largeを正式採用（2026-07-08）**。文書の語彙を避けた言い換え質問5問（年休→有給休暇・手当→日当・リモートワーク→在宅勤務等の同義語検索を含む）で5/5正答を確認し実用水準と判断。plamo-embedding-1b等への切替（全文書再embedding必須）は不要。※サンプル5問・3文書での評価のため、実文書規模での再確認はPhase 2で行う。

### P2 — 配布品質

5. `trust_remote_code` コードレビュー（llm-jp-4-8b-thinking 採用時）とコミットハッシュ固定。
6. `install.sh` のフルサイクル実機検証（別マシンまたは現行コンテナ停止後に実施）。

### P3 — 仕上げ

7. 完全オフライン（ネットワーク遮断）実機検証。
8. SBOM・MODEL_CARDS の作成。
9. 生成済み配布パッケージ上でのPowerShellランチャー動作確認。

## 6. 現在のファイル構成

- `runtime/docker-compose.yml`: AnythingLLM(`localrag-anythingllm:1.0.0`) + Ollama(Docker) サービス定義。
- `runtime/anythingllm-storage/`: データ永続化ボリューム（DB, ベクター, 設定）。コミット禁止。
- `runtime/ollama-models/`: Ollamaモデルファイル。コミット禁止。
- `anything-llm/`: AnythingLLM fork（branch: `product/customer-rag-base`、独立git、親からは`.gitignore`で除外）。
- `scripts/`: export/install/uninstall/start/stop/backup/restore/smoke-test/rag-e2e-test（bash）+ WSL2ランチャー版PowerShellスクリプト(.ps1)。
- `docs/customer/`: 顧客向けドキュメント5点。
- `LICENSES/`, `NOTICE`: 第三者ライセンス。

## 7. Git 状態

- リモート: `git@github.com:ishihara1447/localRAG.git`（`origin/main`、push運用に移行済み）。
- `anything-llm/` は独立リポジトリ。fork先remoteは未設定（`upstream`=Mintplex-Labs本家のみ）。**pushしない**（allowlist改修などはローカルコミットのみ）。

## 8. Claude Code セッション運用

- ユーザー方針: 確認・プロンプトを極力減らす。妥当なデフォルトは自分で決めて進め、事後報告。ただし工数の大きい別トラック（PowerShell対応など）は着手前に確認する。
- 作業単位: 1改修1コミット。レビュー→修正→再レビュー→コミット&pushのサイクルを細かく回す。
- メモリ: `~/.claude/projects/-home-ishihara1447-projects-localRAG/memory/` に保存済み。

---

Source（vLLM/WSL2 ブロッカー調査）:
- vLLM Forum: Project: vLLM docker for running smoothly on RTX 5090 + WSL2 — https://discuss.vllm.ai/t/project-vllm-docker-for-running-smoothly-on-rtx-5090-wsl2/1697
- Making vLLM work on WSL2 (DEV) — https://dev.to/docteurrs/making-vllm-work-on-wsl2-482e
- vLLM Troubleshooting — https://docs.vllm.ai/en/latest/usage/troubleshooting/
