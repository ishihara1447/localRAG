# Codex依頼「設定メニューの製品能力プロファイル対応」の費用対効果仕分けと先行実装

作成日: 2026-07-26
担当: Claude Code（サブエージェント）
対象依頼: [`docs/CLAUDE_CODE_REQUEST_SETTINGS_MENU_PRODUCT_PROFILE_2026-07-26.md`](./CLAUDE_CODE_REQUEST_SETTINGS_MENU_PRODUCT_PROFILE_2026-07-26.md)
根拠分析: [`docs/SETTINGS_MENU_COMPATIBILITY_ANALYSIS_2026-07-25.md`](./SETTINGS_MENU_COMPATIBILITY_ANALYSIS_2026-07-25.md)
ブランチ: `product/customer-rag-base`（切替なし・コミットなし）

---

## 0. 前提: 依頼の完了条件のうち、このセッションで満たせないもの

Codexは完了条件に「Windows配布用bundleへの同梱」「クリーンなWindowsインストール後の画面で確認」を挙げているが、
これは**配布物の再ビルド（`export-windows.ps1`）とWindows実機**を必要とし、本セッション（WSL/Linux）では実施できない。
したがって「ソース変更だけで完結し、リスクが低く、顧客の事故を確実に防ぐもの」に絞って先行実装した。

---

## 1. 仕分け結果

### (a) 今すぐやる（本セッションで実装済み）

| 項目 | 理由 |
|---|---|
| **初回セットアップ（オンボーディング）画面のLLM一覧をローカル系のみに絞る** | **クリーンインストール直後に顧客が最初に見る画面**。`prisma migrate deploy` 直後のDBには `onboarding_complete` が無いため、Windows配布版でもオンボーディングは必ず表示される。ここにOpenAI/Anthropic等が並んでおり、選ぶとサーバー側許可リストで拒否され製品が起動不能になる |
| **オンボーディング完了時の `EmbeddingEngine="native"` 固定送信を廃止** | **本セッション最大の発見（P0級）**。上流実装は完了時に `EmbeddingEngine="native"` / `VectorDB="lancedb"` を無条件送信する。配布版は `server/.env` で `EMBEDDING_ENGINE=ollama` / `EMBEDDING_MODEL_PREF=bge-m3:latest` を設定済みなので、**顧客が初回セットアップを完了しただけで埋め込みが bge-m3 から native(未同梱・`HF_HUB_OFFLINE=1`で取得不可)へ差し替わり、検索が壊れる**。しかも `handleVectorStoreReset` が走り既存ベクトルも消える |
| **埋め込みエンジン選択のUI絞り込み** | Pinecone同様「選ぶと壊れる」+ 外部embeddingは顧客文書の外部送信そのもの |
| **ベクターDB選択のUI絞り込み（LanceDBのみ）** | 未同梱DBを選ぶと取り込み・検索が即死。既存の `DISTRIBUTABLE_LLM_PROVIDERS` と同じパターンで済む |
| **サーバー側の許可リスト（embedding / vectorDB）追加** | Codexの「UIから隠すだけでは不十分、APIでも拒否せよ」。LLMには既にあるがembedding/vectorDBには**無かった**。env直接編集・API直叩きの迂回を塞ぐ |
| **ワークスペース単位／チャット画面／エージェント／モデルルーターのLLMセレクタ絞り込み** | 2026-07-17のLLMハードニングが**全体設定画面にしか入っていなかった**。ワークスペース設定からOpenAIに切り替えると、そのワークスペースのチャットだけ起動不能になる。同じ許可リストを使うだけなので追加コストほぼゼロ |
| **埋め込み変更時の再埋め込み警告を日本語で明示** | 依頼6.1-5。既存の警告モーダルの文言追加のみ |

### (b) 後回し（効果はあるが工数・設計判断が必要）

| 項目 | 理由 |
|---|---|
| **SettingsSidebar のメニューallowlist化** | 522行・多数のメニュー・i18n・「子が全部非表示なら親カテゴリも消す」実装が必要。**どのメニューを残すかは製品仕様の意思決定**（例: APIキー・システムプロンプト変数・ワークスペースチャットを顧客に見せるか）。Community Hub / Telegram / Browser Extension / Mobile / Scheduled Jobs / Experimental は非表示にすべきだが、まとめて1本の設計として扱うべき |
| **能力プロファイルをサーバーAPIで返しfrontendが参照する方式** | 依頼§4の理想形。今回は**ビルド時定数の共有モジュール**（`productProfile.js` を frontend/server 双方に配置）で実装した。API配信方式は「外部入力で `product_mode` を変更できない」設計の検討が要る。現状のビルド時定数はその点むしろ安全 |
| **LLMをOllamaだけに絞る** | 現行の許可リストは「ローカル/自己ホスト型10種」。Ollama単独に絞るのは安全性ではなく**製品ポリシーの変更**（LM Studio利用者を切る判断）。既存方針を勝手に狭めない |
| **Agent skills の絞り込み（Filesystem / Create Files / SQL / MCP）** | `defaults.js` で docSummarizer/web-scraping は既に既定除外済み。Docker専用スキルの非表示は追加実装が必要で、エージェント設計と併せて判断すべき |
| **ブランディング画面のロック** | 製品識別の方針決定が先 |

### (c) 今やるべきでない（Windows実機・再ビルド・別途調査が前提）

| 項目 | 理由 |
|---|---|
| **音声・文字起こし（Whisper / TTS）のオフライン検証** | 依頼§6.4が求めるのは「配布物にモデルが同梱されているか」「`HF_HUB_OFFLINE=1` で初回起動できるか」「ネットワーク遮断で文字起こしが成功するか」。**すべてWindows実機での実測**。ソース側で先に有効/無効を決めるのは順序が逆 |
| **クリーンWindows環境での画面確認（依頼§7・§8手動確認）** | 再ビルド + 実機必須 |
| **`C:\LocalRAGProd\app\server\public\index.js` への反映確認** | 同上 |
| **Windows export/self-test の実行** | PowerShell + Windows必須 |

---

## 2. 「依頼に書いてあるが既に実装済みだった」もの（依頼と現状のギャップ）

| 依頼項目 | 実際の状況 |
|---|---|
| 6.1 LLMプロバイダーのUI絞り込み | **全体設定画面は2026-07-17に実装済み**（`DISTRIBUTABLE_LLM_PROVIDERS`）。ただし**オンボーディング・ワークスペース設定・チャット画面・エージェント設定・モデルルーターには未適用**だった → 今回補完 |
| 6.1 LLMのバックエンド拒否 | `getLLMProvider` の `_LOCAL_ALLOWED_LLM_PROVIDERS` と `updateENV.js` の `supportedLLM` に実装済み。ただし**2箇所に同じリストが重複**していた → `productProfile.js` に集約 |
| 6.5 Community Hub のダウンロード無効化 | サーバー側で既定無効（`communityHubDownloadsEnabled.js`）。**解除していない** |
| 6.3 Agent skills（要約・Webスクレイピング） | `server/utils/agents/defaults.js` で既定スキルから除外済み（コミット `709f6d56`） |
| テレメトリ / Swagger / HF offline | `windows-native/config/server.env.template` で `DISABLE_TELEMETRY=true` / `DISABLE_SWAGGER_DOCS=true` / `HF_HUB_OFFLINE=1` 設定済み |
| ネットワーク露出 | `SERVER_HOST` 未設定で 127.0.0.1 バインド（2026-07-15対応済み） |

**逆に、依頼書にも分析メモにも書かれていなかった実バグ**: オンボーディング完了時の `EmbeddingEngine="native"` 固定送信（上記(a)）。
分析メモ§4は「単一ユーザーだと上流メニューが広く見える」までしか指摘していないが、実際にはオンボーディングが
**設定を書き換えて製品既定を壊す**経路になっていた。

---

## 3. 実装内容（タスク2）

### 新規ファイル

- `anything-llm/frontend/src/utils/productProfile.js`
  顧客配布版で**表示してよい**LLM / embedding / vectorDB の値を1箇所で定義。`onlyDistributable()` ヘルパー付き。
- `anything-llm/server/utils/helpers/productProfile.js`
  顧客配布版で**許可する**LLM / embedding / vectorDB の値を1箇所で定義。`notPermittedError()` は
  管理者が原因を特定できるよう許可値を併記してログ出力してから Error を返す。

上流のリスト定義（`AVAILABLE_LLM_PROVIDERS` / `EMBEDDERS` / `VECTOR_DBS`）は**削除せず、表示時に絞り込む**方式。
依頼§9「上流のメニューを一括削除して将来の再利用性を失うこと」を避けるため。

### 変更ファイル

サーバー（API/env での迂回を拒否）

| ファイル | 変更 |
|---|---|
| `server/utils/helpers/index.js` | `getVectorDbClass` に LanceDB以外を拒否するガードを追加。`getEmbeddingEngineSelection` に外部embedding拒否ガードを追加（未設定時は上流どおり native フォールバック）。LLM許可リストを `productProfile.js` へ集約 |
| `server/utils/helpers/updateENV.js` | `supportedEmbeddingModel` / `supportedVectorDB` を許可リスト基準に変更（従来は上流の全プロバイダーを通していた）。`supportedLLM` も `productProfile.js` 参照に統一 |

フロントエンド（顧客に選ばせない）

| ファイル | 変更 |
|---|---|
| `frontend/src/pages/OnboardingFlow/Steps/LLMPreference/index.jsx` | LLM一覧を許可リストで絞り込み。初期選択を `openai` → `ollama`。**`EmbeddingEngine`/`VectorDB` の固定値上書きを廃止し既存設定を尊重** |
| `frontend/src/pages/GeneralSettings/EmbeddingPreference/index.jsx` | 選択一覧を許可リストで絞り込み。再埋め込み警告に日本語説明を追加 |
| `frontend/src/pages/GeneralSettings/VectorDatabase/index.jsx` | 選択一覧を LanceDB のみに絞り込み |
| `frontend/src/pages/GeneralSettings/LLMPreference/index.jsx` | 許可値を `productProfile.js` 参照に変更。`DISTRIBUTABLE_ALL_LLM_PROVIDERS` を追加エクスポート |
| `frontend/src/pages/WorkspaceSettings/ChatSettings/WorkspaceLLMSelection/index.jsx` | ワークスペース単位のLLM切替を許可プロバイダーのみに |
| `frontend/src/components/WorkspaceChat/ChatContainer/PromptInput/LLMSelector/utils.js` | チャット画面のプロバイダー切替を許可プロバイダーのみに |
| `frontend/src/pages/WorkspaceSettings/AgentConfig/AgentLLMSelection/index.jsx` | エージェント用LLMを許可プロバイダーとの積集合に |
| `frontend/src/pages/GeneralSettings/ModelRouters/LLMProviderModelPicker/index.jsx` | ルーティング先を許可プロバイダーのみに |

### 触っていないもの（他セッションの未コミット変更・厳守）

`frontend/public/favicon.ico` / `favicon.png` / `frontend/src/media/logo/localrag-icon.svg`（Codexアイコン）、
`server/models/systemSettings.js` / `server/utils/EmbeddingRerankers/native/index.js` /
`server/utils/vectorDbProviders/lance/index.js` / `server/utils/vectorDbProviders/lance/sentenceCushion.js`（cushion系）。
`git status` で全て変更前と同じ状態を維持していることを確認済み。

---

## 4. 検証結果

| 項目 | 結果 |
|---|---|
| `eslint`（server変更3ファイル） | PASS（prettier指摘1件を `--fix` で解消） |
| `eslint`（frontend変更9ファイル） | PASS |
| `vite build`（frontend本番ビルド） | **PASS**（`✓ built in 24.46s`） |
| `jest`（server全体） | 170 passed / **2 failed**。失敗2件は `lance/hybridSearch` の FTSテーブル名（`__oterag_fts__` vs `__oterag_fts__v2_`）で、**本変更前から存在する既存failure**（FTSトークナイザ版数導入時にテスト未更新）。本変更は `utils/helpers` のみに触れており無関係 |
| `git diff --check` | PASS（exit 0） |
| 許可リストの実動作確認（node直実行） | `VECTOR_DB=pinecone` → 拒否 / `lancedb` → OK。`EMBEDDING_ENGINE=openai` → 拒否 / 未設定 → native フォールバックOK |
| API経路の拒否確認（`updateENV()` 直実行） | `VectorDB:'pinecone'` → `"pinecone is not a permitted vector database in this build. Allowed: lancedb."`<br>`EmbeddingEngine:'openai'` → `"openai is not a permitted embedding engine in this build. Allowed: native, ollama, ..."`<br>`LLMProvider:'anthropic'` → 拒否 |
| 既定値の非破壊 | `bge-m3:latest`（ollama）/ `gemma4:12b`（ollama）/ `lancedb` はいずれも許可リスト内。`handleVectorStoreReset` は `prevValue === nextValue` で早期returnするため、オンボーディングが同値を送っても再埋め込みリセットは発生しない |

未実施: Windows export/self-test、クリーン環境の手動確認（(c)に分類。実機必須）。

---

## 5. 「ソースを変えただけでは顧客に届かない」— 配布反映に必要なこと

今回の変更は**フロントエンドのバンドルに焼き込まれる**ため、`C:\LocalRAGProd\app\server\public\index.js` を
差し替えない限り顧客の画面は一切変わらない。反映には以下が必要（すべてWindowsビルドマシン上）。

1. ソースをWindowsビルドマシンへ同期（WSL側 `anything-llm/` → `C:\LocalRAG\src`）
2. frontend をビルドして `server\public` へコピー
   （`docs/CODEX_WINDOWS_NATIVE_BUILD_AND_VERIFY_2026-07-09.md` L57-61）
   ```powershell
   cd C:\LocalRAG\src\frontend
   yarn build
   Copy-Item -Recurse -Force C:\LocalRAG\src\frontend\dist C:\LocalRAG\src\server\public
   ```
   ※ `export-windows.ps1` は L63-66 で `server\public\index.html` の存在をチェックするだけで、
   **ビルドが古いかどうかは検出しない**。前回のサービス制御UI事故と同じ落とし穴なので、
   コピー後に `server\public\index.js` のタイムスタンプを必ず確認すること。
3. `windows-native/export-windows.ps1 -Version 1.2.6 ...` で ZIP + Setup.exe を再生成
4. 旧版をアンインストールしてからクリーンインストール、ブラウザキャッシュをクリアして画面確認

**確認すべき画面（今回の変更点）**
- 初回セットアップのLLM選択にOpenAI/Anthropic/Gemini等が出ないこと、初期選択がOllamaであること
- **初回セットアップ完了後に「埋め込みエンジン」がOllama + `bge-m3:latest` のままであること**（最重要・従来はnativeへ差し替わっていた）
- 設定 → 埋め込みエンジンにOpenAI/Gemini/Cohere/Voyage/Mistral/OpenRouterが出ないこと
- 設定 → ベクターデータベースがLanceDBのみであること
- ワークスペース設定 → チャット設定のLLM、チャット画面のモデル切替にクラウドLLMが出ないこと

---

## 6. 未解決事項 / 次の作業

- **顧客向けにまだ表示される未対応メニュー**: Community Hub、Telegram、ブラウザ拡張、モバイルアプリ、チャット埋め込み、定期実行、実験的機能、ユーザー/招待（マルチユーザー）、Docker専用エージェント。→ (b) SettingsSidebar のallowlist化で一括対応する
- **配布物への反映待ち**: 本変更すべて（frontendバンドル再生成が必要）
- **既存テストの修正**: `__tests__/utils/vectorDbProviders/lance/*.test.js` の2件がFTSテーブル名の版数（`v2_`）追加に追随していない。cushion系の作業者が対応するのが自然
- **音声/文字起こし**: Windows実機でのモデル同梱・オフライン動作確認が先（未着手）
- **能力プロファイルのAPI配信化**: 依頼§4の理想形。現状はビルド時定数で、外部入力による変更が不可能な分むしろ安全なので、必要になった時点で再検討

---

## 意思決定ログ

| 日付 | 内容 | 担当 |
|---|---|---|
| 2026-07-26 | Codex依頼を(a)(b)(c)に仕分け、(a)のみ先行実装。Windows実機依存の完了条件は(c)として除外 | Claude Code |
| 2026-07-26 | オンボーディングの `EmbeddingEngine="native"` 固定送信を製品既定破壊バグとして修正（依頼書・分析メモとも未指摘） | Claude Code |
| 2026-07-26 | 能力プロファイルはAPI配信ではなくfrontend/server双方のビルド時定数モジュールとして実装（外部入力で変更できない設計を優先） | Claude Code |
