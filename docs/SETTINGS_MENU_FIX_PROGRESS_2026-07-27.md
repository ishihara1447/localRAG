# OTE-RAG Webアプリ改修の進捗確認

確認日: 2026-07-27  
確認対象: 2026-07-26付けの設定メニュー改修依頼と、現在のAnythingLLM fork / Windows配布物

## 1. 総合判定

**ソース側は、プロバイダー選択とバックエンド拒否処理まで実装済みです。**

一方で、次の重要項目は未完了です。

- スパナメニュー全体の表示整理
- Community Hub、Telegram、モバイル、ブラウザ拡張、定期実行などの顧客向け非表示
- 現行Windows同梱構成に合わせた許可リストの厳密化
- 変更後frontendのWindows配布物への反映
- Windowsインストール後の実画面確認

したがって、現時点は**「能力プロファイルの基礎実装済み、製品UIと配布物の仕上げ前」**です。

## 2. 実装済み

### 2.1 製品能力プロファイル

AnythingLLM forkのコミット `d6e7174d`（2026-07-27 07:52）で、以下が追加されています。

- `anything-llm/frontend/src/utils/productProfile.js`
- `anything-llm/server/utils/helpers/productProfile.js`
- `anything-llm/server/utils/helpers/index.js` の利用制限
- `anything-llm/server/utils/helpers/updateENV.js` の保存時validator

フロントエンドとサーバーの許可値を別々に増やさず、製品プロファイルに集約する方向は正しいです。

### 2.2 LLM設定の絞り込み

以下の画面・選択箇所には、許可リストによる表示制限が入っています。

- 全体LLM設定
- オンボーディング時のLLM選択
- ワークスペースのLLM選択
- チャット入力欄のLLM選択
- エージェントLLM選択
- モデルルーターのfallback選択

OpenAI、Anthropic、Gemini等のクラウドLLMを通常の選択肢から除外した点は、依頼内容に対する実装済み成果です。

### 2.3 embedding / Vector DBの選択肢とバックエンド拒否

以下は実装済みです。

- embedding画面の表示絞り込み
- Vector DB画面のLanceDB限定表示
- `EMBEDDING_ENGINE` の保存時拒否
- `VECTOR_DB` の保存時拒否
- サーバー実行時の不許可Vector DB拒否
- オンボーディング完了時に`EmbeddingEngine="native"`を無条件送信する問題の修正
- embedding変更時の再埋め込み警告の日本語化

特にオンボーディング完了だけで`bge-m3`から未同梱のnative embeddingへ切り替わり、ベクトルストアがリセットされるP0級問題を修正した点は重要です。

## 3. 部分実装・追加確認が必要

### 3.1 許可リストが現行Windows同梱構成より広い

現在のプロファイルには、次のような値が残っています。

- LLM: `localai`、`lmstudio`、`koboldcpp`、`textgenwebui`、`litellm`、`generic-openai`、`lemonade`等
- embedding: `native`、`localai`、`lmstudio`、`litellm`、`generic-openai`、`lemonade`
- モデルルーター: `anythingllm-router`

これらは「ローカルまたは自己ホスト型」としては説明できますが、現在のWindows配布物で実際に同梱・検証された構成は、原則として以下です。

```text
LLM       = ollama + gemma4:12b
Embedding = ollama + bge-m3:latest
VectorDB  = lancedb
```

特に`generic-openai`は接続先次第で外部送信になり得ます。また`native`はモデル同梱と完全オフライン動作の確認が必要です。したがって、顧客向けWindows版で「外部送信なし」を厳密に保証するなら、許可値を同梱・検証済みのものへさらに絞る必要があります。

### 3.2 設定サイドバーは未整理

[`anything-llm/frontend/src/components/SettingsSidebar/index.jsx`](../anything-llm/frontend/src/components/SettingsSidebar/index.jsx) は、従来のメニューを引き続き表示しています。

現時点でも、単一ユーザーの`flex`条件により、以下の顧客向け非対応メニューが表示される可能性があります。

- Agent skills
- Community Hub
- Telegram
- Chat Embed
- Scheduled Jobs
- Browser Extension
- Mobile App
- Experimental Features
- モデルルーター
- 音声・文字起こしの未検証経路

つまり、今回の依頼のうち**「使えない機能をスパナメニューから隠す」部分は未実装**です。

### 3.3 エージェント機能

サーバー側ではRAG memory中心の既定設定や、Docker専用Filesystem/Create Filesの利用判定など、既存の安全策があります。

しかし、エージェント設定画面そのものは顧客向けメニューに残っています。コードが安全側に設定されていることと、顧客に機能として見せることは別なので、初期版ではメニューを非表示にする判断が必要です。

### 3.4 音声・文字起こし

コード上の経路はありますが、以下は未完了です。

- Windows配布物へのWhisperモデル同梱確認
- ネットワーク遮断状態での文字起こし確認
- ブラウザ標準SpeechRecognitionの外部依存確認
- ローカルTTSモデルの同梱確認

現段階では「完全オフライン対応」と表示してはいけません。

## 4. 未実装

### 4.1 顧客向けメニューのallowlist化

依頼書で指定した以下の整理は、まだ実装されていません。

- RAG設定
- 資料・ワークスペース
- 運用
- 表示

のような製品目的に沿ったグループ整理と、非対応カテゴリの非表示が必要です。

### 4.2 外部機能の顧客向け非表示

以下はコードやルートが存在していても、顧客向けWindows版には表示しない方針です。

- Community Hub
- Telegram
- Web検索 / Webスクレイピング
- Gmail / Google Calendar / Outlook
- Chat Embed
- Scheduled Jobs
- Browser Extension
- Mobile App
- Experimental Features
- 任意MCP
- 未監査SQL Agent

Community Hubのバンドルダウンロードはサーバー側で既定無効ですが、メニュー表示自体は残っています。

## 5. Windows配布物への反映状況

現行のWindows配布物は、引き継ぎ記録上、v1.2.5を2026-07-24にビルド済みです。一方、能力プロファイル導入コミットは2026-07-27です。

したがって、**v1.2.5には今回の能力プロファイル改修が入っていない可能性が高く、再ビルドが必要**です。

さらに、以前確認したとおり、インストール済み`C:\LocalRAGProd`のWeb bundleにはサービス制御UIが含まれていません。ソースに存在するUIが配布物に反映されているかを、今回も必ず確認する必要があります。

## 6. 次に実施すべき順序

1. `SettingsSidebar`を能力プロファイルまたは顧客向けallowlistで整理する。
2. 現行Windows同梱構成に合わせて、LLM/embedding許可値を再確認する。
3. Community Hub等を顧客向け画面から非表示にする。
4. frontend buildを実行する。
5. Windows native exportで新しいfrontend bundleを同梱する。
6. クリーンインストール後にスパナメニューを手動確認する。
7. 外部provider・外部機能をAPI/env直接指定しても拒否されることを確認する。
8. その後にのみ、配布版の更新を出荷候補とする。

## 7. Claude Codeへの伝達事項

- `d6e7174d`の能力プロファイル導入は有効な前進だが、依頼全体の完了ではない。
- `SettingsSidebar`のメニュー整理が未実装である。
- 許可リストは「ローカル系」ではなく、現行Windows同梱・検証済み構成と一致させる必要がある。
- `generic-openai`、未同梱native embedding、未検証localai/LM Studio等を顧客向け既定で許可しない。
- ソースの変更だけで完了とせず、Windows配布物を再ビルドし、実際のブラウザ画面で確認する。
- 今回はスコープ外の機能を実装するのではなく、まず顧客に誤解を与える表示を整理する。

