# Claude Code作業指示書: OTE-RAG設定メニューの顧客向け整理

作成日: 2026-07-27  
依頼元: Codex  
対象: OTE-RAG Windowsネイティブ版のWebアプリ

## 1. この作業の目的

OTE-RAGのWeb設定画面には、AnythingLLM上流版の機能が多数残っています。画面を開けても、Windowsネイティブ版ではDocker、外部アカウント、外部API、別サーバー、未同梱モデルなどが必要な機能があります。

顧客に「選べるが動かない」機能を見せないため、次の3点を一致させてください。

1. 顧客向けWeb UIの表示項目
2. API・環境変数を含むバックエンドの許可範囲
3. Windows配布物に実際に同梱されるfrontend bundle

## 2. 既に実装済みの範囲

以下はforkのコミット `d6e7174d` で実装済みです。原則として再実装せず、動作確認と不足部分の修正に集中してください。

- `frontend/src/utils/productProfile.js` の表示用プロファイル
- `server/utils/helpers/productProfile.js` のサーバー側許可リスト
- LLM設定のprovider表示絞り込み
- embedding設定のengine表示絞り込み
- Vector DBのLanceDB限定表示
- `updateENV.js` のLLM/embedding/Vector DB validator
- `getLLMProvider()`、`getEmbeddingEngineSelection()`、`getVectorDbClass()`のサーバー側拒否
- オンボーディング完了時にembeddingを`native`へ固定送信する不具合の修正
- ワークスペース、チャット、エージェント、モデルルーターのLLM選択制限

## 3. 現在の問題点

### 3.1 設定サイドバーが未整理

対象:

- `anything-llm/frontend/src/components/SettingsSidebar/index.jsx`
- `anything-llm/frontend/src/components/SettingsSidebar/MenuOption/index.jsx`
- `anything-llm/frontend/src/main.jsx`
- `anything-llm/frontend/src/components/PrivateRoute/index.jsx`

現在は単一ユーザーモードで`flex`項目が広く表示され、次のような顧客向け非対応機能が残っています。

- Community Hub
- Telegram
- Scheduled Jobs
- Browser Extension
- Mobile App
- Chat Embed
- Experimental Features
- Users / Invites
- 外部連携を前提とするAgent Skills
- 現時点で未検証の音声・文字起こし
- 現行Windows版では不要なModel Router

### 3.2 許可リストが実際のWindows同梱構成より広い

現在の`productProfile.js`には、`localai`、`lmstudio`、`litellm`、`generic-openai`、`lemonade`、`native`などが含まれています。

これらは「ローカルで動かせる場合がある」だけで、現行のWindows配布物で同梱・検証済みとは限りません。特に`generic-openai`は接続先次第で外部送信になります。

現行の顧客配布版の実体は次の構成です。

```text
LLM       = ollama + gemma4:12b
Embedding = ollama + bge-m3:latest
VectorDB  = lancedb
Docker    = 不使用
外部通信  = 不使用
```

## 4. 実装方針

### 4.1 製品プロファイルをWindows顧客版に固定する

既存の上流provider定義は削除せず、表示時・保存時・起動時に製品プロファイルで絞り込む方式を維持してください。

ただし、顧客向けWindows版の既定許可値は、まず次に絞ってください。

```text
LLM provider          = ollama
Embedding engine      = ollama
Vector database       = lancedb
Model router          = disabled
External network      = false
Community Hub         = false
Cloud connectors      = false
Web search/scraping   = false
Arbitrary MCP         = false
Docker-only agents    = false
```

`native` embeddingを残す場合は、Whisperではなくembeddingモデルの同梱・オフライン動作を実証したうえで、別途判断してください。未検証のまま許可値に残さないでください。

`generic-openai`、`litellm`、`localai`、`lmstudio`、`lemonade`等は、将来の開発版で再利用できるよう定義を残しても構いません。ただし、顧客向けWindowsプロファイルでは選択・保存・起動を許可しないでください。

### 4.2 顧客向け設定サイドバーのallowlist

顧客向けWindows版では、次のメニューだけを基本表示としてください。

#### 表示する

- AIプロバイダー
  - LLM
  - 埋め込みエンジン
  - ベクターデータベース
  - テキスト分割とチャンク化
- 管理
  - ワークスペース
  - 既定のシステムプロンプト
- カスタマイズ
  - UI設定
  - チャット
- ツール
  - イベントログ
  - APIキー（管理者向け）
- セキュリティ

#### 条件確認後に表示する

- 文字起こし
- 音声とスピーチ
- システムプロンプト変数
- ワークスペースチャット

条件確認が終わるまでは非表示にしてください。特に音声・文字起こしを「完全オフライン対応」と表示しないでください。

#### 顧客向けWindows版では非表示にする

- Model Router
- Users
- Invites
- Agent Skills
- Community Hub全体
- Telegram
- Chat Embed
- Scheduled Jobs
- Browser Extension
- Mobile App
- Experimental Features

### 4.3 直接URLでも迂回できないようにする

サイドバーから隠すだけでは不十分です。顧客がURLを直接入力した場合も、非対応画面へ到達できないようにしてください。

実装候補:

- 既存の`PrivateRoute`に製品能力チェックを追加する
- `CapabilityRoute`または同等の小さなguardを追加する
- 非対応機能は設定トップへリダイレクトし、日本語で「この配布版では利用できません」と表示する

上流版のルートやコンポーネントを削除する必要はありません。開発版・将来版で再利用できるよう、製品プロファイルで制御してください。

### 4.4 Agent Skillsを顧客向けに扱う

現行の既定スキルがRAG memory中心であることと、Agent Skillsメニューを顧客へ公開することは別問題です。

顧客向けWindows版では、次を実施してください。

- Agent Skillsの設定メニューを非表示
- Web scraping / Web browsingを既定有効にしない
- Filesystem / Create FilesはDockerがない場合に表示・実行できないことを確認
- Gmail / Google Calendar / Outlookを非表示
- 任意MCPサーバーを非表示
- SQL Agentを未監査のまま表示しない
- Scheduled Jobsが利用可能なAgent Toolを自動承認しないことを確認

将来、ファイルサーバー連携を追加する場合は、汎用Filesystem Agentをそのまま有効化せず、読み取り専用・許可フォルダ固定・差分同期・監査ログ付きの資料コネクターとして別実装してください。

### 4.5 Community Hubと外部連携

既存のCommunity Hubダウンロード無効化は解除しないでください。

次の機能は顧客向けUIから非表示にし、バックエンドでも既定無効を維持してください。

- Community Hub
- Telegram
- Gmail / Google Calendar / Outlook
- Browser Extension
- Mobile App
- Chat Embed
- Web search / Web scraping

外部APIへ接続できることを「拡張性」として顧客向け画面に残さないことが重要です。

## 5. 小さく実装する順序

一度に大きな変更を入れず、次の順で実施してください。

### Step 1: 許可値をWindows同梱構成へ合わせる

対象:

- `frontend/src/utils/productProfile.js`
- `server/utils/helpers/productProfile.js`
- `server/utils/helpers/updateENV.js`
- `server/utils/helpers/index.js`

確認:

- UI許可値とサーバー許可値が一致する
- `ollama / ollama / lancedb`以外を顧客向けWindows版で保存できない
- `generic-openai`を指定しても保存・起動できない
- `native`を未検証のまま既定に戻せない
- `gemma4:12b`、`bge-m3:latest`、`lancedb`の既定値は変わらない

### Step 2: SettingsSidebarの表示allowlistを追加する

対象:

- `frontend/src/components/SettingsSidebar/index.jsx`
- 必要に応じて`MenuOption/index.jsx`

確認:

- 単一ユーザーだからという理由で上流版の全`flex`項目が表示されない
- 非対応の子項目がすべて消えた親カテゴリも消える
- 顧客向け表示項目が4.2のallowlistと一致する
- 上流版定義を削除していない

### Step 3: 直接URLのguardを追加する

対象:

- `frontend/src/main.jsx`
- `frontend/src/components/PrivateRoute/index.jsx`
- または既存のルート保護機構に合う場所

確認:

- 非対応設定のURLを直接開いても機能画面が表示されない
- 顧客向けに日本語の理由が表示される
- ワークスペース、資料取込、チャット、必要な管理画面は回帰しない

### Step 4: Agent / Community / 外部機能を確認する

UI非表示だけでなく、既存のバックエンド無効化が残っていることを確認してください。

### Step 5: frontend buildと配布依頼を分離する

Claude Code側で以下を実施してください。

- frontend lint
- frontend test
- frontend build
- server lint/test
- `git diff --check`
- 変更ファイルとテスト結果を記録

Windowsのexport、Setup.exe再ビルド、クリーンインストール、実ブラウザ確認はCodex側へ依頼してください。必要なら、次のファイルを作成して引き継いでください。

```text
docs/CODEX_REQUEST_WINDOWS_BUILD_SETTINGS_MENU_2026-07-27.md
```

## 6. Windows配布物の受け入れ条件

ソースだけで完了扱いにしないでください。Codex側のWindows検証で、次を確認します。

1. frontend build成果物がWindows exportに同梱されている
2. 実際の`C:\LocalRAGProd\app\server\public\index.js`が更新されている
3. 古いブラウザキャッシュを除去した状態でスパナメニューを開ける
4. 顧客向け設定メニューがallowlistどおりである
5. LLMはOllama、embeddingはOllama、Vector DBはLanceDBだけである
6. Community Hub、Telegram、Chat Embed、Scheduled Jobs等が表示されない
7. 資料取込、検索、出典付き回答が回帰していない
8. API/env直接変更による外部provider選択が拒否される

以前、ソース側のサービス制御UIがインストール済みbundleに反映されていない事例がありました。同じ問題を繰り返さないため、bundleの更新確認を必須にします。

## 7. テスト方針

### 必須テスト

- productProfileの許可値テスト
- `updateENV`で不許可LLM/embedding/Vector DBが拒否されるテスト
- SettingsSidebarの単一ユーザー表示テスト
- 非対応ルートのguardテスト
- frontend lint/test/build
- server lint/test
- 既存RAG E2Eの回帰確認

### 手動確認

- 初回オンボーディング完了後にembeddingが`native`へ変わらない
- 既存embeddingとベクトルデータが設定表示だけで消えない
- スパナメニューが顧客向けallowlistどおりに表示される
- 非対応URLへ直接移動しても拒否される
- 外部通信なしでコア機能が利用できる

## 8. やってはいけないこと

- AnythingLLM上流のprovider定義を一括削除する
- UIだけを隠してAPI/envの迂回を残す
- `generic-openai`を外部送信なしとして扱う
- 未同梱のnative embeddingやWhisperをオフライン対応と表示する
- 顧客文書を外部providerのテストへ送信する
- DockerなしのWindows版でDocker専用Agentを有効化する
- 既存の未コミット変更を確認せずに戻す
- 配布物を再ビルドせずに完了報告する
- ユーザーの明示依頼なしにコミット・プッシュする

## 9. 完了報告の形式

作業完了時は、以下を埋めて報告してください。

```text
## 実装結果
- Step 1 許可値の厳密化: PASS / PARTIAL / BLOCKED
- Step 2 SettingsSidebar整理: PASS / PARTIAL / BLOCKED
- Step 3 直接URL guard: PASS / PARTIAL / BLOCKED
- Step 4 Agent/Community/外部機能: PASS / PARTIAL / BLOCKED
- Windows配布物反映: Claude Code対象外 / PASS / BLOCKED

## 変更ファイル
- 

## テスト結果
- frontend lint:
- frontend test:
- frontend build:
- server lint/test:
- RAG E2E:

## 未解決事項
- 

## Codexへの引き継ぎ
- Windows再ビルドで確認する項目:
- クリーンインストールで確認する項目:
```

