# Claude Code作業依頼: OTE-RAG設定メニューの製品能力プロファイル対応

作成日: 2026-07-26  
依頼元: Codex  
対象製品: OTE-RAG Windowsネイティブ版

## 1. 目的

現在の設定画面はAnythingLLM上流版のメニューとプロバイダー選択肢を広く表示しています。しかし、OTE-RAGの顧客配布版は次の方針です。

- Windows 11単体で動作する
- WSL、Docker、外部LLM、外部embeddingを必要としない
- 顧客文書を外部サービスへ送信しない
- 単一ユーザーを基本とする
- LLMは同梱Ollama、embeddingはOllama + `bge-m3:latest`
- ベクターデータベースはLanceDB
- Web検索、Community Hub、クラウド連携は既定で使用しない

設定画面には、**画面が存在するだけでなく、OTE-RAGの配布物で利用を保証できる機能だけを顧客向けに表示**してください。

今回の作業では、上流版の機能を無差別に削除しません。製品能力プロファイルにより、顧客向けWindows版では安全に隠し、開発版・将来版では再利用できる構造にします。

## 2. 先に読むべき資料

必ず以下を確認してから実装してください。

1. [`docs/SETTINGS_MENU_COMPATIBILITY_ANALYSIS_2026-07-25.md`](./SETTINGS_MENU_COMPATIBILITY_ANALYSIS_2026-07-25.md)
2. [`docs/HANDOFF.md`](./HANDOFF.md)
3. [`windows-native/config/server.env.template`](../windows-native/config/server.env.template)
4. [`windows-native/config/collector.env.template`](../windows-native/config/collector.env.template)
5. [`anything-llm/frontend/src/components/SettingsSidebar/index.jsx`](../anything-llm/frontend/src/components/SettingsSidebar/index.jsx)
6. [`anything-llm/frontend/src/components/SettingsSidebar/MenuOption/index.jsx`](../anything-llm/frontend/src/components/SettingsSidebar/MenuOption/index.jsx)

既存の未コミット変更は作業開始前に確認し、関係ない変更を戻さないでください。

## 3. 最重要の前提

### 3.1 UIとバックエンドの両方を直す

UIから選択肢を隠すだけでは不十分です。ユーザーが環境変数やAPIを直接変更しても、製品方針を迂回できないようにしてください。

- UI: 利用できない選択肢を顧客向けに表示しない
- API: 許可されていないprovider/database/connectorを拒否する
- 起動時: 不正な設定なら明確なエラーをログに出す
- 配布物: Windows版の環境変数テンプレートと実際のbundleを一致させる

### 3.2 「ソースにある」ことを完了条件にしない

前回、サービス制御UIはソース側に存在する一方、実際に稼働している `C:\LocalRAGProd\app\server\public\index.js` には反映されていませんでした。

したがって、今回も次を完了条件にします。

1. ソースコードに変更がある
2. frontend buildが成功する
3. Windows配布用bundleへ新しいfrontendが同梱される
4. クリーンなWindowsインストール後の画面で変更を確認できる

## 4. 製品能力プロファイルを追加する

設定画面の各所に個別の `if` や provider 配列を増やすのではなく、能力プロファイルを一箇所で定義し、UIとサーバーが参照する形にしてください。

### 推奨プロファイル

```text
product_mode=ote-rag-windows-local
multi_user=false
docker_runtime=false
external_network=false
allowed_llm_providers=ollama
allowed_embedding_engines=ollama
allowed_vector_databases=lancedb
allow_web_search=false
allow_community_hub=false
allow_cloud_connectors=false
allow_arbitrary_mcp=false
```

実装方法は既存構成に合わせて選択してください。例えば、Windows版の環境変数から読み取るサーバー能力情報をAPIで返し、frontendがその結果を利用する方式が望ましいです。

ただし、外部入力で `product_mode` を自由に変更できる設計にはしないでください。顧客配布版で外部サービスを有効化できる抜け道を作らないことが条件です。

## 5. 顧客向けメニューの表示方針

### 5.1 残すメニュー

以下はOTE-RAGの中心機能なので、顧客向け画面に残してください。

- LLM: 同梱Ollamaのみ
- 埋め込みエンジン: Ollama + `bge-m3:latest`のみ
- ベクターデータベース: LanceDBのみ
- テキスト分割とチャンク化
- ワークスペース
- 既定のシステムプロンプト
- UI設定
- チャット設定
- イベントログ
- セキュリティ

### 5.2 条件付きで残すメニュー

次は実装経路がありますが、配布条件または安全性の確認が必要です。

| メニュー | 条件 |
|---|---|
| 文字起こし | Whisperモデルが配布物に同梱され、ネットワーク遮断状態でも動くこと |
| 音声とスピーチ | ブラウザ依存機能と完全ローカル機能を明確に分け、オフライン保証の有無を表示すること |
| APIキー | 管理者限定、localhost限定、秘密値の表示・ローテーション方針があること |
| システムプロンプト変数 | 管理者向けの詳細設定として扱うこと |
| ワークスペースチャット | 履歴・監査画面としての目的を明確にすること |
| モデルルーター | 複数のローカルモデルを正式サポートする場合だけ表示すること |

条件を満たせない場合は、顧客向けWindows版では非表示にしてください。

### 5.3 顧客向けに隠すメニュー

次の項目は、現行の「Windows単体・ローカル限定・単一ユーザー」方針では、顧客向け画面に表示しないでください。

- OpenAI、Anthropic、Gemini等の外部LLM
- 外部embedding provider
- PGVector、Pinecone、Qdrant、Weaviate等の未同梱vector database
- Users、Invitesなどのマルチユーザー管理
- Community Hub全体
- Telegram
- Web検索、Webスクレイピング
- Gmail、Google Calendar、Outlook
- Docker専用のFilesystem Agent、Create Files Agent
- 未監査のSQL Agent
- 任意のMCPサーバー
- Chat Embed / 外部公開用埋め込み
- Scheduled Jobs
- Browser Extension
- Mobile App
- Experimental Features

開発版でこれらを確認したい場合は、開発者用の能力プロファイルまたは開発者用フラグで扱い、顧客向けWindows版の既定値にはしないでください。

## 6. 個別の実装方針

### 6.1 LLM / embedding / vector database

対象候補:

- `anything-llm/frontend/src/pages/GeneralSettings/LLMPreference/index.jsx`
- `anything-llm/frontend/src/pages/GeneralSettings/EmbeddingPreference/index.jsx`
- `anything-llm/frontend/src/pages/GeneralSettings/VectorDatabase/index.jsx`
- `anything-llm/server/utils/helpers/index.js`
- provider/database設定を保存する既存API・validator

実施内容:

1. provider配列の表示可否を能力プロファイルから決める。
2. Windowsローカル版では、LLMはOllama、embeddingはOllama、vector databaseはLanceDBだけを表示する。
3. LLMに既にあるローカルprovider許可リストの考え方をembedding/vector databaseにも適用する。
4. 外部providerをAPIや環境変数で指定した場合は保存または起動を拒否する。
5. embeddingモデル変更時には、全文書の再埋め込みが必要であることを既存の警告に加えて明示する。
6. 現在の `bge-m3:latest` と `gemma4:12b` の既定値を壊さない。

### 6.2 SettingsSidebar

対象候補:

- `anything-llm/frontend/src/components/SettingsSidebar/index.jsx`
- `anything-llm/frontend/src/components/SettingsSidebar/MenuOption/index.jsx`
- `anything-llm/frontend/src/utils/paths.js`

実施内容:

1. `flex` 条件だけで単一ユーザーに上流版メニューを全表示しない。
2. 顧客向け能力プロファイルに対応したメニューallowlistを作る。
3. 子メニューがすべて非表示の場合は親カテゴリも消す。
4. 顧客に不要な上流名称やAnythingLLM固有の説明を残さない。
5. 利用不可機能を単にdisabled表示する場合は、理由を日本語で明示する。顧客向け初期版では原則非表示を推奨する。

### 6.3 Agent skills

対象候補:

- `anything-llm/frontend/src/pages/Admin/Agents/index.jsx`
- `anything-llm/frontend/src/pages/Admin/Agents/skills.jsx`
- `anything-llm/server/utils/agents/defaults.js`
- `anything-llm/server/utils/agents/aibitat/plugins/filesystem/lib.js`
- `anything-llm/server/utils/agents/aibitat/plugins/create-files/lib.js`

実施内容:

1. 現行製品ではRAG応答に必要な最小スキルだけを有効にする。
2. Web scraping/web browsing、クラウド連携を既定有効にしない。
3. DockerランタイムがないWindowsネイティブ版でFilesystem/Create Filesを表示しない。
4. SQL、MCP、ファイル操作を将来追加する場合は、対象範囲、権限、監査、停止方法を別設計にする。
5. 「エージェントを有効にすると何でもできる」という印象を顧客画面に与えない。

### 6.4 音声・文字起こし

実装を急いで有効化せず、まず配布物の実態を確認してください。

確認事項:

- WhisperモデルがZIP/インストーラに同梱されているか
- `HF_HUB_OFFLINE=1` の状態で初回起動できるか
- ネットワーク遮断状態で音声ファイルの文字起こしが成功するか
- ブラウザ標準SpeechRecognitionが外部サービス依存にならないか
- Piper/Kokoro等のローカルTTSを同梱しているか

上記が未確認の間は、音声メニューを「完全オフライン対応」と表示しないでください。

### 6.5 Community Hub / 外部連携

次の機能はコードを残しても構いませんが、顧客向けプロファイルでは表示・接続・インポートを無効にしてください。

- Community Hub
- Telegram
- Gmail / Google Calendar / Outlook
- Browser Extension
- Mobile App
- Chat Embed

特にCommunity Hubは、外部API接続に加えて、未検証バンドルのインポートが任意コード実行リスクになり得ます。既存のダウンロード無効化を解除しないでください。

## 7. Windows配布物との一致確認

ソース変更後、必ず次を確認してください。

1. frontend buildが成功する。
2. build成果物がWindows exportへコピーされる。
3. `C:\LocalRAGProd\app\server\public\index.js` など、実際に配信されるbundleへ変更が入っている。
4. 古いブラウザキャッシュの影響を除いて画面を確認する。
5. クリーンなWindows環境、または既存インストールを正しく更新した環境で確認する。

今回のサービス制御UIのように、ソースに存在するだけで、配布物に入っていない状態を合格にしないでください。

## 8. テストと受け入れ条件

### 自動・静的確認

- 既存のfrontend lint/testを実行する
- 既存のserver testを実行する
- Windows nativeのexport/self-testを実行する
- `git diff --check` を実行する
- 外部providerのUI選択肢が顧客向けbundleに残っていないことを確認する
- 外部providerをAPI/envで指定した場合に拒否されるテストを追加または実行する

### 手動確認

Windows配布物を起動し、以下を確認してください。

1. スパナメニューにコア機能だけが表示される。
2. LLMはOllamaのみ表示される。
3. embeddingはOllama + `bge-m3:latest`のみ表示される。
4. vector databaseはLanceDBのみ表示される。
5. Community Hub、Telegram、クラウドLLM、Web検索、Docker専用エージェントが表示されない。
6. ワークスペース作成、資料取り込み、検索、出典付き回答が従来どおり動く。
7. 設定変更後も文書データ・ベクトルデータが意図せず消えない。
8. Windows配布物の実際の画面が、ソース側の想定と一致する。

## 9. やってはいけないこと

- 上流のメニューを一括削除して将来の再利用性を失うこと
- UIだけを隠して、API・環境変数経由の迂回を残すこと
- 顧客文書を外部providerの動作確認に送信すること
- DockerがないWindowsネイティブ版でDocker専用機能を有効化すること
- WhisperやTTSを未同梱のまま「オフライン対応」と表示すること
- サービス停止、アンインストール、データ削除を混同すること
- 既存の未コミット変更を確認せずに戻すこと

## 10. Claude Codeから返してほしい内容

作業完了時は、次の形式で報告してください。

```text
## 実施結果
- 変更したファイル:
- 変更しなかった項目と理由:
- Windows配布物への反映状況:

## 検証結果
- frontend lint/test:
- server test:
- Windows export/self-test:
- クリーン環境の手動確認:

## 未解決事項
- 顧客向けにまだ表示される未対応メニュー:
- 配布物への反映待ち:
- 次に必要な作業:
```

コミット・プッシュは、変更内容と配布物への反映をレビューした後に実施します。ユーザーから明示的な依頼があるまでは実行しないでください。

