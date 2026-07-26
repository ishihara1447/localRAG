# OTE-RAG 競合機能・連携価値分析

調査日: 2026-07-24

## 1. 目的と結論

本調査は、ChatGPT、Genspark、NotebookLM、Perplexity、Claude、Microsoft 365 Copilot、Gemini などの主要なLLMサービスと、Open WebUI、AnythingLLM、LM Studio、Ollamaなどのローカル系ツール、さらに国内の業務RAG製品を比較し、OTE-RAGの付加価値と今後の優先施策を定めることを目的とする。

結論は次のとおり。

1. 競争軸は「PDFに質問できるか」から、「知識を取り込み、根拠を確認し、成果物を作り、業務を進められるか」へ移っている。
2. 利用者が便利だと感じる本質は、モデルそのものよりも、既存のファイル・メール・チャット・タスク・カレンダーとつながり、コピー＆ペーストを減らせることにある。
3. OTE-RAGは、顧客資料を外部送信しないこと、日本語文書に合わせた検索改善、引用を確認できること、Windowsに配布できることを中核に据えるべきである。
4. 最初に競合と同じ数のクラウド連携を作る必要はない。まず、ローカルフォルダ同期、根拠確認、引用付き成果物出力、ローカルMCP/OpenAPI連携を段階的に実装する方が、製品思想と顧客価値の両方に合う。

### 推奨する製品ポジション

> 顧客資料を外部に送らず、日本語文書を根拠付きで検索・回答し、報告書や確認資料までWindows上で完結できる業務RAG。

## 2. 調査対象と比較軸

### 2.1 比較対象

| 区分 | 対象 |
|---|---|
| 国際的な汎用・業務LLM | ChatGPT、Genspark、NotebookLM、Perplexity、Claude、Microsoft 365 Copilot、Gemini |
| ローカル・自己ホスト系 | Open WebUI、AnythingLLM、LM Studio、Ollama |
| 国内の業務RAG・企業向け基盤 | NEC Generative AI Service、PKSHA AIヘルプデスク、Crew、rokadoc、GRAPE Lumia RAG |

### 2.2 比較した観点

- 知識の取り込み: ファイル、フォルダ、クラウド、Web、会話、コード、音声、画像
- 検索と信頼性: 引用、出典位置、権限、同期、ハイブリッド検索、再ランキング
- 業務実行: メール、予定、タスク、チケット、CRM、ファイルへの読み書き
- 成果物: 文書、表計算、スライド、音声概要、マインドマップ、アプリ
- 継続利用: プロジェクト、共有、メモリ、バックグラウンド処理、履歴
- ローカル適性: オフライン、オンプレミス、モデル選択、API、MCP、管理性

## 3. 主要製品の機能と連携

### 3.1 国際的な汎用・業務LLM

| 製品 | 利用者が便利と感じる機能 | 主な連携 | 付加価値の源泉 | OTE-RAGへの示唆 |
|---|---|---|---|---|
| ChatGPT | Web調査、ファイル分析、データ分析、会話の継続、外部アプリの検索、引用付き調査、確認付き書き込み | Google Drive、SharePoint、Dropbox、Box、Gmail、Outlook、Calendar、GitHub、Teamsなど。カスタムMCPアプリも可能 | 調査・社内情報・成果物作成を一つの会話に集約 | 外部連携の数ではなく、ローカルフォルダと業務成果物を一本の流れにする。書き込みは確認を必須にする |
| Genspark | 1つの依頼から調査、整理、生成、実行まで進めるSuper Agent。Slides、Sheets、Docs、Designer、Developerの専門エージェント | 多数のモデル、ツール、MCP連携。Web、ファイル、表計算、コードを使った資料作成 | 「回答」ではなく、スライド・表・文書という完成物を作る | OTE-RAGでは、まず引用付き報告書・比較表・調査メモをローカル生成する。自律実行は限定する |
| NotebookLM | 登録した資料だけを根拠にした質問、引用位置の確認、資料の比較、学習ガイド、ブリーフィング、マインドマップ、Audio Overview | PDF、Google Docs/Slides/Sheets、Web、YouTube字幕、音声、画像 | ソースグラウンデッドな理解支援。引用をクリックして元資料を確認できる | OTE-RAGの強みになり得る。引用抜粋、ページ移動、根拠パックを優先する |
| Perplexity | Web検索と社内検索の統合、深掘り調査、ファイル比較、検索源の選択、プロジェクト | Google Drive、OneDrive、SharePoint、Dropbox、Box、Notion、Slack、Asana、Jira、Confluence、Gmail、Calendar、GitHub、HubSpot、Snowflakeなど | 外部情報と社内情報を横断し、調査を業務に接続 | Web検索は既定で外部送信になるため、OTE-RAGでは「ローカルのみ」と「接続モード」を明確に分離する |
| Claude | プロジェクトごとの知識・指示・履歴、知識量に応じた自動RAG、Artifacts、文書・コードの分析 | Google Drive、GitHub、Asana、AtlassianなどのMCPコネクタ。Desktop拡張でローカルファイルにも接続 | プロジェクト単位で知識と成果物を継続利用できる | 業界・顧客別の「知識パック」「回答規則」「出力テンプレート」を保存できるようにする |
| Microsoft 365 Copilot | Outlook、Teams、Word、Excel、PowerPointの文脈で要約・作成・検索・タスク化。エージェントによる業務フロー | Microsoft Graph、SharePoint、OneDrive、Teams、業務システム用Copilot Connectors、Copilot Studio | 既存の権限と業務データを保ったまま、日常業務の中で使える | 顧客環境にMicrosoft 365がある場合も、OTE-RAG本体はローカルのまま、将来は読み取り専用コネクタを別モジュールで提供する |
| Gemini | GmailやDriveの検索・要約、Calendar/Tasks/Keepとの連携、Docs/Sheets/Slides/Meetとの連続利用、GitHubリポジトリ参照 | Google Workspace、Google Chat、Tasks、Keep、Calendar、Classroom、GitHub | 仕事のデータが最初から同じスイートにあり、切り替えが少ない | OTE-RAGでは、まずWindowsのファイル・共有フォルダ・Excel/CSVを「最初からつながっている」状態にする |

ChatGPTのAppsは、接続サービスの検索・参照だけでなく、同期、引用、確認付きの書き込み、MCPによるカスタムアプリまでを一つの仕組みで扱う。Gensparkは多数のモデルとツールを組み合わせ、調査結果をスライドや表などの成果物に変換する。NotebookLMは、登録資料に限定した回答と引用位置の確認、音声概要などの「理解」の体験が強い。[ChatGPT Apps](https://help.openai.com/en/articles/11487775-connectors-in)、[Genspark Super Agent](https://www.genspark.ai/helpcenter?doc=general_What_is_Super_Agent)、[NotebookLMの機能](https://support.google.com/notebooklm/answer/16164461)

Perplexity、Microsoft 365 Copilot、Geminiに共通するのは、LLM単体ではなく、ファイル・メール・チャット・予定・業務データを横断することである。特にPerplexityは、内部ファイルとWebを同時に検索し、同期更新と権限を扱う。MicrosoftはGraphへのコネクタで業務データを取り込み、GeminiはWorkspaceアプリを会話から参照する。[Perplexity Internal Knowledge Search](https://www.perplexity.ai/help-center/en/articles/10352958-what-is-internal-knowledge-search-for-enterprise)、[Microsoft 365 Copilot Connectors](https://learn.microsoft.com/en-us/microsoft-365/copilot/agent-essentials/m365-agents-faq)、[Gemini Connected Apps](https://support.google.com/gemini/answer/14959807?co=GENIE.Platform%3DDesktop&hl=en)

Claudeは、単発チャットよりも、プロジェクト知識・指示・共有・Artifactsを組み合わせた継続作業に価値がある。MCPは、AIアプリとデータソース・ツールを標準化して接続する共通基盤として機能している。[Claude Projects](https://support.anthropic.com/en/articles/9517075-what-are-projects)、[Claude MCP](https://docs.anthropic.com/en/docs/mcp)

### 3.2 ローカル・自己ホスト系

| 製品 | 主な機能 | 連携・拡張 | 強み | OTE-RAGへの示唆 |
|---|---|---|---|---|
| Open WebUI | ローカル/リモートLLM、文書・Web・音声・画像RAG、メモリ、Web検索、画像生成、ツール、管理 | MCP、OpenAPI、Pythonツール、Pipelines、Skills、複数ベクトルDB、複数抽出エンジン、RBAC/SSO/OIDC/LDAP | 拡張性が高く、RAGの検索方式・抽出方式・ツールを選べる | OTE-RAGは機能数で追わず、日本語業務文書とWindows配布の完成度に集中する。ただしMCP/OpenAPIの入口は重要 |
| AnythingLLM | ローカル/オフラインチャット、PDF/Word/CSV/コード、Web検索、エージェント、カスタムスキル、バックグラウンド処理、会議文字起こし・要約・辞書入力 | ローカルモデル、各種LLM、Web、文書、エージェントスキル | 「導入してすぐ使える」一体型のローカルAI | OTE-RAGは、同じ一体感に加えて、根拠の見やすさ、日本語精度、顧客配布の運用性を前面に出す |
| LM Studio | モデル検索・取得、チャット、文書RAG、MCPクライアント、ローカルAPI、ヘッドレスサーバ、CLI、SDK | OpenAI互換API、Anthropic互換API、Claude Code、Codex、Hermes Agentなど | ローカルモデルを他のアプリから使うための実行基盤 | OTE-RAGも、将来的にOpenAI互換APIまたはMCPサーバとして外部ツールから利用できると、単体製品から基盤へ広がる |
| Ollama | ローカルモデル実行、Windows/Linux/macOS、常駐API、モデル切替、ツール呼び出し、構造化出力 | OpenAI互換API、Function Calling、MCP、Claude Code、Codexなど | モデル実行を開発ツールやアプリに組み込むための軽量な基盤 | OTE-RAGはOllamaを隠蔽するだけでなく、設定・モデル状態・停止・更新をユーザーに安全に見せる管理画面が必要 |

Open WebUIは、ハイブリッド検索（BM25・ベクトル・クロスエンコーダ）、複数の抽出エンジン、ローカルフォルダの増分同期、MCP/OpenAPI、権限管理までを備える。LM StudioとOllamaは、エンドユーザー向けRAG製品というより、ローカルモデルをAPIやツールから利用するための実行基盤として強い。[Open WebUI Knowledge](https://docs.openwebui.com/features/workspace/knowledge/)、[Open WebUI Features](https://docs.openwebui.com/features/)、[LM Studio App](https://lmstudio.ai/docs/app)、[Ollama Tool Support](https://ollama.com/blog/tool-support)

### 3.3 国内の業務RAG・企業向け基盤

| 製品・企業 | 主な機能・連携 | 付加価値の源泉 | OTE-RAGへの示唆 |
|---|---|---|---|
| NEC Generative AI Service | 安全確認済みLLMの選択、社内RAG、社内チャットやWeb会議ツールとの連携、安全なAPI公開。Office/PDFのナレッジ活用や、図表・RDB情報を組み合わせる業務RAGも展開 | ガバナンス、社内システムへの組み込み、業務部門別の適用 | ローカル運用でも、利用ポリシー・API・監査・業務別テンプレートを製品の一部として設計する |
| PKSHA AIヘルプデスク | Teamsの問い合わせ窓口、SharePoint Onlineとのフォルダ単位同期、Word/Excel/PowerPoint/PDF、元のアクセス許可の継承、構造化によるRAG精度向上 | 既存の情報資産をそのまま使い、問い合わせ削減という成果につなげる | 「ファイルをアップロードする」だけでなく、更新・削除・権限・問い合わせログまで扱う必要がある |
| Crew | 社内マニュアル、資料、FAQをRAG化。NotionやGmailへの下書き保存、稟議書・社内規定・製品文書の読解 | 回答を業務フローの次の場所へ渡すこと | OTE-RAGでは、まずMarkdown/Word/PDFの引用付き出力と、確認付きのローカル保存から始める |
| rokadoc | 複雑な社内文書をAIが理解しやすい形式に変換し、生成AI/RAG/エージェントの精度を向上 | RAG前処理・文書変換そのものを製品価値にする | 日本語PDF、表、段組み、スキャン文書の前処理を競争力にする |
| GRAPE Lumia RAG | 社内ドキュメント横断検索、出典付き回答、権限アクセス制御、運用・監査ログ | 回答精度だけでなく、企業運用に耐える証跡 | OTE-RAGにも、回答ログ、検索結果、利用者評価、再インデックス状態を確認できる運用画面が必要 |

国内製品を見ると、差別化の中心は「国産LLMを使っていること」だけではない。SharePointやTeamsなど既存の場所を起点にすること、権限を壊さないこと、文書の構造化、問い合わせ削減、監査ログ、導入後の継続改善が重要である。[NEC Generative AI Service](https://jpn.nec.com/techrep/journal/g23/n02/230208.html)、[PKSHA AIヘルプデスクのSharePoint連携](https://www.pkshatech.com/news/20250227/)、[CrewのRAG機能](https://www.gocrew.jp/products/rag)、[rokadoc](https://rokadoc.ntt.com/)、[GRAPE](https://www.grape-eng.com/)

## 4. 便利機能を生む連携パターン

### A. 知識連携: 「探す」コストを消す

代表例は、Google Drive、SharePoint、OneDrive、GitHub、Notion、Slack、Teams、ローカルフォルダなどをLLMから検索できる機能である。重要なのは接続先の数ではなく、次の4点である。

- 初回取り込み後の自動同期
- 変更・削除の反映
- 元システムの権限の維持
- 回答から元ファイルへ戻れること

OTE-RAGでは、外部クラウド連携より前に、Windows上の顧客資料フォルダと共有フォルダを同じ原則で扱うべきである。

### B. ツール連携: 「回答」から「処理」へ進める

MCP、OpenAPI、Function Calling、Graph Connector、デスクトップ拡張などは、LLMがデータを読むだけでなく、検索、集計、下書き作成、タスク登録、ファイル保存などを実行するための接続層である。

ただし、顧客向けローカル製品では、次の順序を守る必要がある。

1. 読み取り専用ツール
2. 実行前の引数表示とユーザー確認
3. 書き込み・削除・外部送信の個別許可
4. 実行結果と証跡の保存

「AIに何でも実行させる」ことは便利そうに見えるが、顧客資料を扱う製品では、権限境界と監査可能性が価値の一部になる。

### C. 成果物連携: 「答え」を納品物にする

GensparkのSlides/Sheets、NotebookLMの学習ガイド・音声概要・マインドマップ、ClaudeのArtifactsが示すのは、チャットの回答だけでは業務が完了しないということである。

OTE-RAGで先に実装すべき成果物は、汎用的なスライド作成ではなく、根拠が失われない次の形式である。

- 引用付き調査メモ
- 複数文書の比較表
- 時系列・論点整理
- FAQ/回答案
- 顧客説明用の根拠一覧
- 更新差分レポート

### D. 継続利用: 「毎回説明する」コストを消す

Projects、Hub、Workspace、Memory、Background Jobsは、過去の資料・指示・会話・定型作業を再利用する機能である。OTE-RAGでは、これを無制限の長期記憶として実装するより、明示的に管理できる「プロジェクトパック」として設計するのが安全である。

プロジェクトパックに含めるもの:

- 対象フォルダと同期状態
- 業務分野・顧客名・文書種別
- 回答ルールと禁止事項
- 引用形式
- 出力テンプレート
- 利用モデル・embedding・検索設定のバージョン

### E. 信頼性・管理: 「使える」から「任せられる」へ進める

引用、出典位置、根拠抜粋、検索ログ、評価、権限、監査ログ、バックアップ、更新状態は、派手ではないが企業導入の障壁を下げる。RAGは回答生成だけでなく、データ更新と品質確認の運用までが製品である。

## 5. OTE-RAGの現状評価

### 5.1 既に強みになっている部分

- 顧客資料を外部LLM・外部embeddingへ送らない構成を目指している。
- Windows単体で顧客へ配布することを前提に、インストーラーと運用確認を進めている。
- 日本語文書を主対象とし、BM25とベクトル検索を組み合わせるハイブリッド検索、再ランキング、クエリ補正など、回答精度の改善を継続している。
- 回答の出典表示を重要視し、RAGベンチマークと実文書で検証している。
- OTE-RAGという製品名・アイコン・READMEを含め、顧客に説明できる製品として整備している。

### 5.2 競合比較で見える不足候補

現時点で最も重要なのは、モデルを増やすことではなく、知識を更新し、根拠を確認し、結果を次の作業へ渡す一連の体験である。

| 領域 | 現状の課題候補 | 競合が提供している体験 |
|---|---|---|
| 資料更新 | 手動アップロード中心になりやすい。変更・削除・再インデックス状態が見えにくい | Drive/SharePoint/ローカルフォルダの自動同期 |
| 根拠確認 | 出典表示はあっても、引用抜粋・元資料の該当箇所・根拠の強弱まで一画面で確認できる余地がある | NotebookLM、Perplexity、国内業務RAGの検証可能な引用 |
| 成果物 | チャット回答からWord/PDF/比較表/差分報告へ変換する手順が残る | Genspark、NotebookLM、Claude Artifacts |
| 継続利用 | 顧客・案件・分野ごとの指示、テンプレート、対象資料の再利用を体系化する余地がある | Claude Projects、Genspark Hub、Perplexity Projects |
| ツール | Windowsファイル、Excel/CSV、SQLite/SQL Server、社内REST APIを安全に参照する入口が必要 | MCP、OpenAPI、Copilot Connectors、デスクトップ拡張 |
| 文書理解 | スキャンPDF、段組み、表、画像、音声を扱う前処理の強化余地がある | Open WebUIの複数抽出エンジン、rokadocの文書変換 |
| 運用 | 同期状態、検索ログ、回答評価、再評価、バックアップを管理する画面が必要 | 国内企業向け製品の監査・ログ・継続改善 |
| 配布品質 | 機能追加より先に、Windowsインストール・更新・停止・再実行が再現可能である必要がある | ローカル製品は導入の容易さそのものが競争力 |

## 6. OTE-RAGへの優先提案

### P0: 製品の土台

#### 1. Windows配布・更新の再現性を完成させる

インストーラーが確実に起動し、途中失敗時に再実行でき、サービス停止・アンインストール・データ保持を安全に選べることを最優先とする。機能を増やしても配布できなければ顧客価値にならない。

#### 2. 根拠確認を製品の中心体験にする

回答ごとに以下を表示する。

- ファイル名、ページ、見出し
- 回答に使った引用抜粋
- 検索方式・候補順位・再ランキング結果の概要
- 根拠不足時の明示的な「不明」
- クリックで元資料の該当箇所を開く操作
- 採用した資料・除外した資料の一覧

### P1: 使う頻度が高く、ローカル思想と相性がよい機能

#### 3. ローカルフォルダの増分同期

Windowsの指定フォルダを監視または定期スキャンし、追加・変更・削除を検出する。ファイルごとに「未処理、処理中、完了、失敗、削除反映済み」を表示し、再インデックスの対象と理由を確認できるようにする。

#### 4. Evidence Packの出力

回答を、引用付きのMarkdownから始め、次にPDF/DOCXへ拡張する。最初のテンプレートは「調査メモ」「比較表」「FAQ」「時系列」「更新差分」に限定する。すべての主張に引用元を付け、引用なしの生成文と明確に区別する。

#### 5. 顧客・案件別のプロジェクトパック

フォルダ、回答規則、引用形式、出力テンプレート、モデル設定をひとまとめにする。パックをエクスポート・バックアップできれば、導入支援や別PCへの移行にも使える。

#### 6. ローカルMCP/OpenAPIゲートウェイ

最初に提供するツールは、読み取り専用に限定する。

- 指定フォルダのファイル一覧・検索
- Excel/CSVの集計
- SQLite/SQL Serverの許可済みSELECT
- 社内REST APIの許可済みGET
- OTE-RAGの検索・引用取得API

書き込み、メール送信、削除、外部URLへの送信は、既定で無効にし、ツール単位の許可と実行前確認を必須にする。

### P2: 付加価値を広げる機能

#### 7. 日本語業務文書のマルチモーダル前処理

スキャンPDFのOCR、表の構造保持、段組み、図表、画像キャプションを強化する。これは汎用LLMの機能数ではなく、OTE-RAGが日本語の顧客資料で勝つための差別化領域である。

#### 8. ローカル音声・会議アシスタント

Whisper等のローカル音声認識と、既存のRAGを組み合わせ、会議録、論点、決定事項、未解決事項、アクションアイテムを根拠付きで出力する。導入は文書RAGが安定した後に行う。

#### 9. API/CLI提供

Windows上の他アプリ、PowerShell、Excel、Claude Code、Codex、LM Studioなどから、OTE-RAGの検索と引用取得を呼び出せるようにする。UIを増やすより、既存業務に組み込める接続面を作る方が長期的な付加価値になる。

#### 10. 接続モードの分離

Web検索、Google Drive、SharePoint、Teamsなどのクラウド連携は需要があるが、既定では有効化しない。「ローカルのみ」と「接続モード」を画面・設定・ログ・説明書で分ける。接続モードでは、送信先、送信データ、認証、保存期間、権限を利用者が確認できるようにする。

## 7. 段階的な実装ロードマップ

| 段階 | 実装 | 価値 | 先に確認すること |
|---|---|---|---|
| Wave 0 | Windowsインストール、更新、停止、アンインストール、バックアップの安定化 | 導入失敗を減らす | 真っさらなWindowsでの再現性、失敗後の復旧 |
| Wave 1 | 根拠ビュー、引用抜粋、元資料への移動、回答評価 | 「任せられる」回答にする | ページ番号・見出し・抜粋の正確性 |
| Wave 1 | ローカルフォルダ増分同期 | 資料更新の手間を消す | 変更・削除・重複・失敗時の状態 |
| Wave 1 | Evidence PackのMarkdown出力 | 回答を業務成果物にする | 引用漏れ、出力の再現性 |
| Wave 2 | PDF/DOCX出力、プロジェクトパック | 反復業務と導入支援を容易にする | テンプレートの固定方法、バックアップ |
| Wave 2 | OCR・表・段組みの改善 | 日本語資料での差別化 | スキャン品質、表の崩れ、処理時間 |
| Wave 2 | ローカルMCP/OpenAPI、読み取り専用ツール | 既存業務に組み込む | 権限、タイムアウト、監査、プロンプトインジェクション |
| Wave 3 | 音声・会議、任意のクラウドコネクタ | 利用範囲を広げる | VRAM、保存、外部送信の明示、運用負荷 |

## 8. 取り組まない方がよいこと

- ChatGPTやGensparkと同じ数のWeb検索・クラウド連携を一度に実装すること
- 顧客資料を外部LLMへ自動送信するWeb検索・要約を既定にすること
- 書き込み・削除・メール送信を確認なしでエージェントに許可すること
- スライドや画像の見た目を先に作り込み、引用・更新・監査を後回しにすること
- モデルを増やすだけで精度が上がると判断すること
- 既存の顧客資料を再埋め込みせずにembeddingモデルを交換すること

## 9. 最終提案

OTE-RAGは、「何でもできるAI」ではなく、次の5点を深く実現する製品として差別化するのがよい。

1. **Local**: 顧客資料を外部へ送らず、Windowsだけで動く。
2. **Japanese**: 日本語の法務・士業・業務文書を、表・段組み・スキャンを含めて扱う。
3. **Evidence-first**: 回答、引用抜粋、ページ、元資料を一体で確認できる。
4. **Workflow**: 検索結果を比較表・調査メモ・FAQ・報告書へ変換する。
5. **Controlled integration**: ローカルMCP/OpenAPIで既存業務に接続し、権限・確認・監査を維持する。

この順番なら、ChatGPT/Gensparkの「成果物化」、NotebookLM/Perplexityの「根拠確認」、Claudeの「プロジェクト継続性」、Open WebUI/LM Studio/Ollamaの「ローカル拡張性」、国内業務RAGの「権限・運用」を、OTE-RAGの顧客配布・完全ローカル方針に合わせて段階的に取り込める。

## 10. 参照情報

### 海外サービス

- [ChatGPT Apps / Connectors](https://help.openai.com/en/articles/11487775-connectors-in)
- [Genspark Super Agent](https://www.genspark.ai/helpcenter?doc=general_What_is_Super_Agent)
- [Genspark AI Slides](https://www.genspark.ai/docs/ai_slides_changelog)
- [NotebookLMの機能](https://support.google.com/notebooklm/answer/16164461)
- [NotebookLM Sources](https://support.google.com/notebooklm/answer/16215270?co=GENIE.Platform%3DDesktop&hl=en)
- [NotebookLM Citation](https://support.google.com/notebooklm/answer/16179559?hl=en)
- [Perplexity Internal Knowledge Search](https://www.perplexity.ai/help-center/en/articles/10352958-what-is-internal-knowledge-search-for-enterprise)
- [Perplexity File Connectors](https://www.perplexity.ai/help-center/en/articles/10672063-introduction-to-file-connectors-for-enterprise-organizations)
- [Claude Projects](https://support.anthropic.com/en/articles/9517075-what-are-projects)
- [Claude Connectors](https://support.anthropic.com/en/articles/11817150-connect-your-tools-to-unlock-a-smarter-more-capable-ai-companion)
- [Anthropic Model Context Protocol](https://docs.anthropic.com/en/docs/mcp)
- [Microsoft 365 Copilot Agents FAQ](https://learn.microsoft.com/en-us/microsoft-365/copilot/agent-essentials/m365-agents-faq)
- [Gemini Connected Apps](https://support.google.com/gemini/answer/14959807?co=GENIE.Platform%3DDesktop&hl=en)

### ローカル・自己ホスト系

- [Open WebUI Features](https://docs.openwebui.com/features/)
- [Open WebUI Knowledge](https://docs.openwebui.com/features/workspace/knowledge/)
- [AnythingLLM](https://www.anythingllm.co/)
- [LM Studio App](https://lmstudio.ai/docs/app)
- [LM Studio Integrations](https://lmstudio.ai/docs/integrations)
- [Ollama OpenAI Compatibility](https://ollama.com/blog/openai-compatibility)
- [Ollama Tool Support](https://ollama.com/blog/tool-support)

### 国内の業務RAG・企業向け基盤

- [NEC Generative AI Service](https://jpn.nec.com/techrep/journal/g23/n02/230208.html)
- [NECの図表・RDB連携RAG](https://jpn.nec.com/obbligato/solution/slt-intr_ent_llm.html)
- [PKSHA AIヘルプデスク SharePoint連携](https://www.pkshatech.com/news/20250227/)
- [PKSHA/TOPPANのRAG前処理](https://www.pkshatech.com/news/20240925/)
- [Crew RAG](https://www.gocrew.jp/products/rag)
- [NTT rokadoc](https://rokadoc.ntt.com/)
- [GRAPE Lumia RAG](https://www.grape-eng.com/)

注: 各製品の機能・提供条件・対応プランは変更される。また、アカウント種別、地域、管理者設定、接続先の契約によって利用できる機能が異なる。製品採用時は、公式ドキュメントと顧客環境で再確認する。
