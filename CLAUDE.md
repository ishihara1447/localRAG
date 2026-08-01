# CLAUDE.md

ローカル RAG 開発プロジェクト。AnythingLLM(OSS) を fork して改修し、完全ローカルで動く日本語 RAG を構築、最終的に**顧客配布可能な形**に仕上げる。詳細計画は `docs/anythingllm_customer_distribution_plan.md`（配布計画書）が一次情報。本ファイルと矛盾したら計画書を正とし、本ファイルを更新する。

## 現在地

- フェーズ: **Phase 1（個人PC検証）の技術タスクは全完了**。製品名は **OTE-RAG（おてらぐ）**（2026-07-13リブランド、日の丸アイコン）。**セッション開始時はまず `docs/HANDOFF.md` を読む**（最新状態・ブロッカー・次手。本ファイルと矛盾したらHANDOFFが正）。
- **対象プラットフォーム（2026-07-08確定）**: Windows（GPU搭載機、RTX 5070 Ti相当以上を想定）。当初のApple Silicon Mac限定戦略は撤回。macOS向け実装は行わない。この変更は当初の批判リスク「士業事務所PCはほぼGPU非搭載」と矛盾するため、対象顧客のGPU保有実態が未検証の新規リスクとして残っている（`fukugyo/ideas/2026-06-29_local-rag-pro.md`の批判・懸念点参照）。
- 済: ハルシネーション対策・日本語CIDフォントPDF対応（upstream未修正のバグをfork側で修正）・日本語PDF字間空白の正規化・APIキー未認証露出の修正（127.0.0.1バインド化）。
- **モデル構成確定（2026-07-16）**: LLM=`gemma4:12b`（Google, Apache-2.0, 非中国系）・Embedding=`bge-m3`（MIT）・Reranker=`bge-reranker-v2-m3`（MIT, ONNX int8。ハイブリッド検索後の「文抽出クッション」で使用）・topN既定8・日本語セパレータ・ハイブリッド検索（dense+BM25+RRF）既定ON。旧LLMの変遷: llm-jp GGUF（テンプレート破損で空回答）→ qwen3:8b（中国系のため2026-07-14に切替）→ gemma4:12b。Phi-4 14Bは架空引用の捏造で不採用。詳細は `docs/HANDOFF.md` および `docs/MODEL_CARDS.md`。
- **配布形態は2系統ある。導入先は RHEL 9 なので、現在の主戦場は Linux 版。**
  - **Linux 版（現行・出荷可能）**: `linux-native/` 一式。RHEL 9 + Docker + NVIDIA GPU 向けの
    完全オフライン配布物。**最新は `linux-v1.1.1`**（2026-07-31 公開、SHA-256 `0241fd0a…`）。
    12.3GB を7分割して GitHub Release で配布。導入から RAG 応答、アンインストールまで
    実環境で通し検証済み（`docs/LINUX_E2E_WSL2_2026-07-31.md`）。ただし**RHEL 9 実機での
    実行は未検証**（開発機が WSL2 のため。初回導入が実証を兼ねる）。
    詳細は `docs/LINUX_RELEASE_v1.1.1_2026-07-31.md`。
  - **Windows 版**: `OTE-RAG-Setup.exe`（.NET Framework製GUI、`windows-native/setup/OTE-RAG-Setup.cs`）の
    ダブルクリックでインストール。**最新は v1.2.7**（Release `v1.2.7`）。Setup.exeは**未署名**。
- **【2026-07-26 前提変更】事業フェーズが変わった**: ユーザーより「**本製品は利用者の目処が立っている**」との連絡があり、**「士業へのヒアリングで核心仮説Aを検証するのが最優先」という方針と、2026-08-15の撤退期限は撤回された**。現在の最優先は**製品品質の向上**。
- **【2026-07-26】想定文書が判明**: **①行政資料（段組みPDF、DTP制作） ②製品のヘルプファイル（Word/Acrobatで作成しPDF化したもの。しおり＝見出しを持つ）**。士業の規程集・条文中心という従来の想定は外れている。したがって「対象顧客のGPU保有実態」リスクの位置づけも変わった（上記の対象プラットフォーム項の記述は当時のまま残している）。
- **【2026-07-26】マイルストーンM1（測定基盤）達成**: 検索の失敗と生成の失敗を切り分けられる状態になった。**新ベースライン: 防衛白書 28/30（3run完全一致で決定的）**。旧「28〜29/30」の揺れは**GPU非決定性ではなくチャット履歴の交絡**だった（`hakusho-eval.py` が `sessionId` を振っていなかった）。**ただしRAG精度自体はまだ改善していない**（製品コード未変更）。
- **【2026-07-29〜31】Linux 配布へ軸足が移った**: 導入先が RHEL 9 + Docker + GPU の完全オフライン環境と判明し、Linux 版の構築・検証・公開を実施した。**RAG 精度は 2026-07-21〜22 時点の水準のまま**で、7/26 以降の品質向上フェーズは測定基盤を作った段階（製品コード未変更）。Phase 1-a/1-b の実験は未コミットで配布物に入っていない。
- **次にやること（優先順）**:
  1. **導入先の環境確認**（ユーザー作業・**唯一のクリティカルパス**）。`survey-target.sh` を実行してもらう。docker か podman かが未確定で、podman なら `install.sh` が停止する。ただし作り直すのは 12GB ではなくスクリプト約1,200行のみ（`docker save` 形式は `podman load` が読める）。**podman 版の先回り実装は見送り済み**（compose 経由の GPU 指定が podman では無言で無視され CPU 転落する既知問題があり、開発機に podman が無く一度も動かせないため）
  2. `docker/Dockerfile` の入手。2026-07-31 にイメージが消失し、配布物の tar から復旧できたが**作り直す手段が無い**
  3. exit 137 の根本対処（`docker-entrypoint.sh` に trap が無く PID 1 が SIGTERM を無視する。イメージ再ビルドを伴う）
  4. RAG 精度の改善に戻る場合は `docs/QUALITY_ROADMAP_2026-07-26.md` が背骨。直近は評価セットの拡張 → 構造抽出（`getOutline()`、`docs/GETOUTLINE_VERIFICATION_2026-07-26.md`）
- Windows 版の残課題: Setup.exe のコード署名・再起動耐性・完全オフライン検証。
- 開発用の起動は自前ビルドイメージ＝`runtime/docker-compose.yml`（image 1.0.x）。コミット/pushはユーザーが明示依頼したときのみ。

## 技術スタック / 構成（予定）

- 改修元: `Mintplex-Labs/anything-llm`（MIT）の **GitHub ソース版**。Desktop 配布バイナリは使わない。
- monorepo: `frontend`(Vite+React) / `server`(Node+Express, LLM・VectorDB・Workspace管理) / `collector`(文書パース) / `docker` / `embed`。
- LLM: **`gemma4:12b`**（Google, Apache-2.0, Ollama公式・非中国系）。2026-07-14確定。旧採用のqwen3:8b（中国系）から切替。llm-jp系はコミュニティGGUFのテンプレート破損（本文が生成されない）により撤回。Ollama公式配布モデルのみを使う方針（`trust_remote_code`不要）。
- Vector DB: LanceDB（既定）。Embedding: **`bge-m3`**（MIT, 多言語）。2026-07-11確定。mxbaiは日本語の言い換え検索で正解文書をtop8にも入れられず撤回。**embedding変更時は全文書の再embedが必須**。
- Reranker: **`bge-reranker-v2-m3`**（BAAI, MIT, ONNX int8, 約571MB）。2026-07-16採用。ハイブリッド検索（dense+BM25+RRF, 既定ON）の結果を文単位で再順位付けする「文抽出クッション」で使用（`LANCE_SENTENCE_CUSHION=true` / `RERANKER_QUANTIZED=true`）。
- 開発環境: Windows 11 + WSL2 Ubuntu + Docker Desktop。Node >= 18（推奨20）、Yarn は Corepack 経由。

## クローン直後のセットアップ（このリポジトリだけでは動かない）

**このリポジトリには AnythingLLM fork 本体（`anything-llm/`）は含まれていない。** `.gitignore` の `/anything-llm/` で意図的に除外しており（独立した git リポジトリとして別管理）、`git clone` した時点で入るのは**設定・ドキュメント・評価スクリプト・Windows配布ツール**のみである。

したがってクローン直後は、以下がまだ揃っていない。

| 揃っていないもの | 入手方法 |
|---|---|
| `anything-llm/`（製品本体のソース） | `Mintplex-Labs/anything-llm`（MIT）を clone し、`product/customer-rag-base` 相当の改修を当てる。**このforkは `upstream` のみを持ちpushしない設計**（下記「Git / ブランチ運用」参照） |
| `runtime/ollama-models/`・`runtime/anythingllm-storage/` | 実行時データ。`.gitignore` で除外。Ollamaのモデル取得と文書投入で生成される |
| `fixtures/local/`（精度評価用の実文書） | 除外。評価を回すには別途配置が必要 |

**評価スクリプトの前提**: `scripts/` 配下は稼働中の AnythingLLM（既定 `http://localhost:3001`）に対して動く。文書やストレージが無い状態で実行すると、原因と対処を示す日本語のエラーで停止する（例: `PageIndex.autodetect()` が「改ページマーカー付きの文書JSONが〜に見つかりません」）。**環境変数 `LOCALRAG_BASE_URL` / `LOCALRAG_STORAGE_DOCS` で参照先を変更できる。**

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
