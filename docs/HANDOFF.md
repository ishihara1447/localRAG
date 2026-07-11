# 引き継ぎメモ（セッション間ハンドオフ）

最終更新: 2026-07-11（Claude・v1.1.0再ビルド前提を整備: bge-m3をWindows側`.ollama\models`へコピー検証済み・MODEL_CARDS.md作成・両export同梱対応） / 次セッション開始時にまずこれを読む。

> **【重要 2026-07-11】RAG精度検証の結果、モデル構成を全面変更（詳細: `docs/RAG_ACCURACY_IMPROVEMENT_2026-07-11.md`）**
> - **旧LLM（llm-jpコミュニティGGUF）はテンプレート破損で本文が空になる致命的問題**があり撤回。
>   過去のe2e PASSは思考テキストへの偶然マッチを含む見かけのPASSだった。以後LLMはOllama公式配布のみ使用。
> - **新構成: LLM=`qwen3:8b`・Embedding=`bge-m3`・topN既定8（env注入）・日本語セパレータ・image 1.0.3**。
>   実運用規模30問評価（紛らわしい規程10本、`scripts/scale-eval.py`）で26/30・ハルシネーションゼロ・不明応答5/5。
>   回帰: e2e 11/11 PASS。配布側（compose/envテンプレ/export-windows.ps1のBundleModels/LICENSES）も反映済み。
> - **Round2実機検証（ユーザーの管理者実行待ち）は旧構成zipのまま実施してよい**（インストーラ機構の検証として有効）。
>   合格後にv1.1.0として新モデル構成で再ビルドする。**再ビルドのモデル前提は整備済み（2026-07-11 Claude）**:
>   bge-m3をWSL側`runtime/ollama-models`からWindows側`%USERPROFILE%\.ollama\models`へコピーし全blobのsha256検証OK、
>   qwen3:8bもWindows側で全blob存在を検証済み。`docs/MODEL_CARDS.md`を作成し両export（export.sh / export-windows.ps1）に同梱処理を追加。

> **【今すぐの状況 2026-07-10】Round2検証は「ユーザーが管理者権限で1回実行」だけ待ち**
> Codexは第2ラウンド検証で再び管理者権限の壁に当たり（予測どおり）、代わりに検証を通しで自動実行する
> ランナー `windows-native/verify/round2-admin-verify.ps1` を完成させて実行待ちにした。ClaudeがレビューしASCII/構文OKを確認、
> リポジトリに取り込み＋UAC自己昇格ランチャー `Run-Round2-Verify.cmd` を追加（Codex版.cmdは自己昇格しないため）。
> 実行物は `C:\Temp\localrag-round2\` にも配置済み。**ユーザーがこの.cmdをダブルクリック→UAC承認するだけ**で
> tar展開→install→E2E→backup→uninstallまで走り、`C:\Temp\localrag-round2-logs\*.summary.json`に結果が出る。
> それをClaudeが判定して仕上げ（顧客docsの実機確認2点・完全オフライン検証4-6へ）。

> **【新トラック 2026-07-09】Windows native配布（Docker/WSLなし配布）— PoC合格・Go確定**
> Codex提案（`docs/CLAUDE_CODE_MEMO_WINDOWS_NATIVE_DISTRIBUTION_2026-07-09.md`）→ Phase 0（Claude）→
> Codex実機PoC（`docs/WINDOWS_NATIVE_POC_RESULT_2026-07-09.md`、**RAG E2E 11/11 PASS**・GPU認識・オフラインモデル投入OK）→
> **ClaudeがGo判断を確定（2026-07-09）**。判断根拠とPhase 4詳細設計は `docs/WINDOWS_NATIVE_PHASE4_DESIGN_2026-07-09.md`。
> - **PoC課題対応済み**: #1 PS5.1文字化け → `windows-native/rag-e2e-test.ps1`をUTF-8 BOM付き化。
>   #2 hotdir誤解決 → fork `fd67e830`で`COLLECTOR_HOTDIR_PATH` env追加（server/collector共有）、envテンプレ更新済み。
> - **Phase 4方針**: WinSWでWindows Service 3本（Server/Collector/専用Ollama@11435）、
>   ビルド済み成果物同梱のzip+install.ps1配布、preflight（ポートowner/GPU/VRAM/ディスク検出）。
>   タスク分解4-1〜4-8と担当は設計メモ参照（4-1〜4-4=Claude、4-5/4-6実機検証=Codex）。
> - **Phase 4-1〜4-4実装完了（2026-07-09 Claude）**: WinSWサービス定義3本＋登録/解除ps1、
>   `export-windows.ps1`（配布zip生成、モデルはmanifest解析で必要blobのみ同梱）、
>   `install.ps1`（preflight＋checksum検証＋env生成＋prisma migrate＋サービス登録＋疎通確認）、
>   運用5本（start/stop/backup/restore/uninstall）、本番envテンプレ（`windows-native/config/`）。
>   全ps1はPowerShell 7.4.6 parserでSYNTAX OK・ASCII-only（rag-e2e-test.ps1のみ日本語＋UTF-8 BOM）。
>   設計判断: STORAGE_DIRは`app\server\storage`固定（prisma schemaのDBパスがソースツリー相対のため）、
>   InstallRoot既定は`C:\LocalRAG`（Program Filesの空白パスリスク回避）、モデル/ログのみProgramData。
> - **Codex実行結果（2026-07-10）**: 配布ビルドPart Aは成功。成果物は `C:\LocalRAG\dist\LocalRAG-win64-v1.0.0.zip`
>   （6.04GiB、100513 files、`versions.lock`作成済み）。結果詳細は `docs/WINDOWS_NATIVE_BUILD_VERIFY_RESULT_2026-07-09.md`。
>   Part Bは非管理者のため中断。「Expand-Archive展開後のinstall.ps1がPS5.1でハング」を発見。
> - **Claude診断完了（2026-07-10）**: ハングは成果物の欠陥ではなく、Expand-Archiveが書いたNTFSファイル実体に残る
>   開発機ローカルのフィルタドライバ状態と特定（13項目の切り分け: 同一内容の複製は動く・rename追従・pwsh正常・
>   排他オープン成功）。**展開手順は`tar.exe -xf`を正式化、PS5.1のExpand-Archiveは使用禁止**。
>   Ollama「0.23.0」表示は接続先サーバー（WSL Docker側）のバージョンで、**同梱exeは正しくv0.31.2**（再DL不要）。
>   詳細: `docs/WINDOWS_NATIVE_EXPAND_ARCHIVE_HANG_DIAGNOSIS_2026-07-10.md`
> - **Phase 4-7/4-8完了（2026-07-10、サブエージェント委譲で並行実施）**: 顧客向けdocs 4点を`docs/customer-windows/`に
>   作成しexport-windows.ps1の同梱対象を切替（Docker版docs同梱バグも修正）。LICENSES/にWinSW(MIT)・
>   Node.js v22(複合)の全文追加、NOTICE/THIRD_PARTY_NOTICES更新。
>   実機確認待ち2点: WinSWログファイル名の実名、アップロードUIの実文言（第2ラウンド検証時または次回に確認）
> - **次: Codexが第2ラウンド検証を実行** — 依頼書 `docs/CODEX_WINDOWS_NATIVE_VERIFY_ROUND2_2026-07-10.md`
>   （管理者権限でtar展開→install→**サービスからのGPU動作確認（Session 0でCUDAが効くかが今回の核心）**→
>   E2E(PS5.1)→backup/stop/start→uninstall。障害予測と対策表・昇格不可時の代替手順を同梱。
>   ポートは3001でなく3005を使用＝wsl --shutdownがWSL上のClaude Codeを殺すため回避）
> - 現行のWSL2+Docker方式は保険として無変更で温存。P2（install.shフルサイクル検証等）はWindows native版の顧客配布方針確定後に要否を再判断

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
7. **（2026-07-08発見）既定`topN=4`は複数文書投入時に不足**: `scripts/precision-eval.py`で検証。単一の長文文書内では16/16正答だが、4文書（短文3件＋長文1件）を同一ワークスペースに入れるとtopN=4では3問中2問が誤った文書から出典を引いた（長文側がチャンク数で他文書を圧迫し上位を独占）。topN=8に上げたところ3/3正答。**ワークスペース既定値のtopN引き上げ（例: 6〜8）を検討し、複数文書アップロードを前提とした顧客シナリオで再検証すること。**

### P3 — 仕上げ

7. 完全オフライン（ネットワーク遮断）実機検証。
8. SBOM の作成（MODEL_CARDSは2026-07-11完了: `docs/MODEL_CARDS.md`、両exportで同梱済み）。
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
