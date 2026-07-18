# エージェントスキル/ツール 安全監査 (2026-07-18)

対象: OTE-RAG (Mintplex-Labs/anything-llm fork, branch `product/customer-rag-base`)
製品前提: **完全オフライン**・**非エンジニアが使用**・用途は**RAG (登録文書へのQ&A) に特化**。
監査範囲: `server/utils/agents/aibitat/plugins/index.js` にある全14種のエージェントスキル(プラグイン)と、
既定でLLMに露出する経路の実コード確認。**本監査ではコード変更を行っていない (調査・提案のみ)**。

---

## 0. 結論サマリー (最重要)

- **フレッシュインストール時にLLMへツールとして露出するのは `rag-memory` (memory) ただ1つ**。
  これは実コードで確認済み。`DEFAULT_SKILLS = [AgentPlugins.memory.name]` (`defaults.js:15`)、かつ
  `default_agent_skills` / `disabled_agent_skills` 設定はいずれも既定 `"[]"` (DBシード無し、`getValueOrFallback` フォールバック)。
- 既に無効化済みの `document-summarizer` と `web-scraping` は **backendの `DEFAULT_SKILLS` から除去済みで、現状LLMに露出しない**ことを再確認した。
- `websocket` と `chat-history` は**常時アタッチされるが、LLMツールとしては露出しない**インフラ用プラグイン (後述 §3)。
- それ以外 (create-chart, web-browsing, sql-agent, filesystem-agent, create-files-agent, gmail/outlook/google-calendar-agent, request-user-input) は
  **既定OFF**。管理者が明示的に有効化しない限りLLMへ露出しない。
- 追加のハードニング提案は §5。**「今すぐ必須」の危険な既定露出は無し**(既存ハードニングが有効に機能している)。

---

## 1. 既定でLLMに露出しているスキル (事故源になり得る箇所)

実コード上、ユーザー(管理者)操作なしにLLMのツール一覧へ入るのは以下のみ:

| slug | プラグイン名 | 露出経路 | 危険度 |
|------|-------------|----------|--------|
| `rag-memory` | memory | `DEFAULT_SKILLS`(`defaults.js:15`) に含まれ、`disabled_agent_skills` に入っていない限り露出 | 低 (ローカル完結・RAGの中核) |

補足:
- `request-user-input` (clarifying questions) は `agent_clarifying_questions_enabled === "true"` の時のみ露出。**既定 `"false"`** なので既定では非露出。
- imported plugins / Agent Flows / MCP servers は、それぞれ保存ディレクトリ/設定が空なら露出無し。**既定で空** = 既定非露出。

> 注: そもそもエージェント(=これらツール)が起動するのは、ユーザーが `@agent` を付けて発話するか、
> ワークスペースが `automatic` チャットモードかつネイティブtool calling対応プロバイダの場合のみ (`server/utils/agents/index.js` `isAgentInvocation`)。
> 通常の `chat` モードのQ&AではRAG検索は通常のリトリーバル経路を通り、エージェントツールは起動しない。
> 非エンジニアが素の質問をする限り露出面は限定的だが、`@agent` 入力や automatic モードで到達しうる。

---

## 2. スキル一覧表 (全14種)

「外部通信」= そのツールがインターネット/外部サービスへ出るか。「既定で有効」= フレッシュインストールでLLMへ露出するか。

| # | slug (tool名) | 何をするツールか | 外部通信 | 既定で有効(露出経路) | 本製品での推奨 | 推奨理由 | 無効化/制御の具体的方法 |
|---|--------------|-----------------|:--------:|--------------------|:-------------:|----------|------------------------|
| 1 | `web-scraping` | 指定URLのWebページ本文を取得(collector経由fetch)、長文なら要約 | **あり** | **無効** (DEFAULT_SKILLS から除去済) | **無効化(現状維持)** | オフライン方針(DISABLE_WEB_SCRAPING)と矛盾。外部fetch発生 | 既に `DEFAULT_SKILLS` 非収録。加えて `default_agent_skills` にも入れない |
| 2 | `web-browsing` | 検索エンジンでWeb検索(既定エンジン=**DuckDuckGo、APIキー不要で即動作**) | **あり** | 無効 (`default_agent_skills` 既定`[]`) | **無効化(現状維持)** | オフライン方針に真っ向から反する。DuckDuckGoは鍵不要のため有効化=即外部送信 | `default_agent_skills` に含めない。§5でUI非表示化も提案 |
| 3 | `websocket` | フロントとのWS通信・introspect・ツール承認/質問カードのインフラ | なし(ローカルWS) | 常時アタッチ**だがLLM非露出** | **残す** | LLMツールではなく通信基盤。無効化不可・無害 | 対象外(制御不要) |
| 4 | `document-summarizer` | ワークスペース全文書を列挙し、指定文書を**全文セクション単位でLLM要約** | なし(ローカルLLM多数回呼出) | **無効** (DEFAULT_SKILLS から除去済) | **無効化(現状維持)** | RAG質問が「Summarizing section N of M」の全文要約に化ける事故防止(既定義済) | 既に `DEFAULT_SKILLS` 非収録。`default_agent_skills` にも入れない |
| 5 | `chat-history` | エージェント応答をDBへ保存・スレッド自動リネームのインフラ | なし(ローカルDB) | 常時アタッチ**だがLLM非露出** | **残す** | LLMツールではなく永続化基盤。無害 | 対象外(制御不要) |
| 6 | `rag-memory` | ローカルベクタDBを類似検索(RAG)/長期メモリへ保存 | なし(ローカル) | **有効** (DEFAULT_SKILLS) | **残す** | RAGの中核。登録文書へのQ&Aそのもの | 残す。`store` の副作用のみ §5-Watch参照 |
| 7 | `create-chart` (rechart) | 数値データからチャート(棒/線/円等)をUIに描画 | なし(ローカル描画) | 無効 (`default_agent_skills`) | **無効化(現状維持)推奨** | RAG特化用途に不要。非エンジニアには混乱要因。無害だが露出面を絞る | `default_agent_skills` に含めない |
| 8 | `sql-agent` | 設定済みSQL DBへ接続し、スキーマ取得・**任意SQL実行(参照/更新)** | 環境次第(外部DB) | 無効 (`default_agent_skills`) | **無効化(現状維持)** | 外部/社内DBへの接続・書込リスク。RAG用途外 | `default_agent_skills` に含めない。§5でUI非表示化提案 |
| 9 | `filesystem-agent` | ホストFSの読取/書込/編集/移動/コピー/ディレクトリ作成等 | なし(ローカルFS) | 無効 (`default_agent_skills` + 可用性チェック) | **無効化(現状維持)** | 任意ファイル書込は重大リスク。RAG用途外 | `default_agent_skills` に含めない。可用性は `isToolAvailable()` でも門番 |
| 10 | `create-files-agent` | pptx/pdf/xlsx/docx/txt を生成しファイル出力 | なし(ローカルFS書込) | 無効 (`default_agent_skills` + 可用性チェック) | **無効化(現状維持)** | ファイル生成書込。RAG(Q&A)用途外 | `default_agent_skills` に含めない |
| 11 | `gmail-agent` | Google OAuthでGmailの検索/閲覧/下書き/**送信**/ゴミ箱移動等 | **あり** | 無効 (`default_agent_skills` + OAuth可用性) | **無効化(現状維持)** | 外部送信・OAuth。オフライン/RAG方針に反する | `default_agent_skills` に含めない。§5でUI非表示化提案 |
| 12 | `outlook-agent` | Microsoft OAuthでOutlookの検索/閲覧/下書き/**送信** | **あり** | 無効 (`default_agent_skills` + OAuth可用性) | **無効化(現状維持)** | 同上(外部メール送信) | 同上 |
| 13 | `google-calendar-agent` | Google OAuthでカレンダー閲覧/**イベント作成・更新** | **あり** | 無効 (`default_agent_skills` + OAuth可用性) | **無効化(現状維持)** | 外部カレンダー書込・OAuth | 同上 |
| 14 | `request-user-input` | 対話フォームでユーザーに追質問(URL/選択肢等) | なし(ローカルUI) | 無効 (`agent_clarifying_questions_enabled` 既定`false`) | 残す(無害)/任意 | ローカルUIのみ。外部通信なし。有効化してもRAG用途で害は小 | `agent_clarifying_questions_enabled` を `false` のまま |

### 危険度による区分
- **インフラ的/無害** (LLM非露出、または外部通信なしのローカルUI): `websocket`, `chat-history`, `request-user-input`, `create-chart`, `rag-memory`
- **外部/危険** (外部通信 or ホスト資源操作): `web-browsing`, `web-scraping`, `sql-agent`, `filesystem-agent`, `create-files-agent`, `gmail-agent`, `outlook-agent`, `google-calendar-agent`
- **RAG事故源** (外部通信なしだがRAGを壊す): `document-summarizer` (全文要約への化け)

---

## 3. 「常時アタッチ」される websocket / chat-history の扱い (露出の実態確認)

`server/utils/agents/index.js` の `createAIbitat()` で、以下2つは設定に関係なく**毎回アタッチ**される:

- `this.aibitat.use(AgentPlugins.websocket.plugin({...}))` (`index.js:827`付近)
- `this.aibitat.use(AgentPlugins.chatHistory.plugin())` (`index.js:840`付近)

ただし両者は `aibitat.function(...)` で**ツール(function)を登録しない**。
- `websocket.js`: `onError` / `onMessage` / `onInterrupt` / `socket.*` / `requestToolApproval` / `requestUserClarification` などの**ハンドラを設定するだけ**。
- `chat-history.js`: `onAbort` / `onMessage` で**チャット保存を行うだけ**。

したがって、これらは**LLMのツール一覧には現れず、LLMが呼び出せる「スキル」ではない**。
「常時アタッチされるが露出はしない」= 制御不要・そのまま残す。

他方、LLMツール一覧を組むのは `WORKSPACE_AGENT.getDefinition()` → `agentSkillsFromSystemSettings()` (`defaults.js:124`) で、
その中身は `DEFAULT_SKILLS` (=memoryのみ) と `default_agent_skills` (既定空) に厳密に限定される。
→ **rechart や sqlAgent 等が「裏で常時attach」される経路は存在しない**ことをコードで確認した。

---

## 4. フロント Agent Skills 設定画面の既定トグル状態

`frontend/src/pages/Admin/Agents/skills.jsx` と `index.jsx` を確認:

- **Default skills** (`getDefaultSkills`): `rag-memory` / `document-summarizer` / `web-scraping` の3つを表示。
  トグルの `enabled` は `!disabledAgentSkills.includes(skill)` で判定。`disabled_agent_skills` 既定 `[]` のため、
  UI上は**3つとも「ON」表示**になる。
- **Configurable skills** (`getConfigurableSkills`): `filesystem-agent` / `create-files-agent` / `create-chart` / `web-browsing` / `sql-agent`。
  `enabled = agentSkills.includes(skill)` (=`default_agent_skills`)。既定 `[]` のため**全てOFF表示**。
- **App integration** (`getAppIntegrationSkills`): `gmail-agent` / `google-calendar-agent` / `outlook-agent`。同上、**OFF表示**。

### ⚠ フロントとバックエンドの不整合 (Watch)
`skills.jsx` の `getDefaultSkills` は **`document-summarizer` と `web-scraping` を依然「Default(既定ON)」として表示**する。
しかしバックエンド `DEFAULT_SKILLS` からは両者が除去済みのため、**UIでONに見えても実際にはLLMへ露出しない**
(逆に、管理者がUIでこれらを「有効」のつもりでも動作しない)。
- セキュリティ上は **フェイルセーフ(閉じる側に倒れる)** ので問題なし。
- ただし非エンジニア管理者に「有効化したのに使えない/実は無効」という**誤解を与える**。§5-C参照。

---

## 5. 追加ハードニング提案 (優先度付き・コード変更は未実施)

### A. [推奨/低リスク] 既定で残すべき最小セットの確定
オフライン非エンジニア向けRAGとしての**既定露出は `rag-memory` のみで十分**。現状がまさにこの状態であり、追加の必須変更は無い。
`request-user-input` は無害なため任意。それ以外は全て既定OFFを維持する。

### B. [推奨] 「多層防御」— UI非表示だけでなくbackend allowlistを維持
現状のガードは `DEFAULT_SKILLS` と `default_agent_skills` の2点。危険スキル(web-browsing/sql/filesystem/create-files/gmail/outlook/gcal)は、
管理者がUI(またはAPI `system::default_agent_skills`)で有効化すると露出しうる。非エンジニア誤操作・サポート時の事故を防ぐには、
`agentSkillsFromSystemSettings()` 側に**「許可リスト外のスキルは `default_agent_skills` に入っていても無視する」フィルタ**を追加する案がある
(例: `ALLOWED_SKILLS = ["rag-memory"]` で最終ゲート)。これによりUI/API経由の有効化も無効化できる。
※ 実装は任意。CLAUDE.md方針「UI非表示だけでなくbackend側でallowlist化」と整合する。

### C. [推奨] フロントの陳腐化トグルを整理 (§4の不整合)
`skills.jsx` の `getDefaultSkills` から `document-summarizer` / `web-scraping` を削除するか、無効表示にする。
非エンジニアが「ONなのに効かない」誤解を持つのを防ぐ。**表示のみの問題でセキュリティ影響なし**。

### D. [任意] 危険スキルのUIエントリ自体を隠す
`getConfigurableSkills` / `getAppIntegrationSkills` から `web-browsing` / `sql-agent` / `gmail` / `outlook` / `google-calendar` を
ビルド時に除外すれば、管理画面から有効化する導線自体が消える。Bのbackend allowlistと併用すると堅牢。

### E. [Watch] `rag-memory` の `store` アクションの副作用
`memory` ツールは `action:"store"` で**任意テキストをワークスペースのベクタDBへ書き込める** (`memory.js:125`)。
LLMが「記憶して」と解釈すると、顧客の正規文書セットにエージェント生成メモが混入しRAG結果を汚染しうる(外部送信は無し)。
純粋なQ&A用途では `search` のみで足りるため、将来的に `store` を無効化(または管理者トグル化)する検討余地あり。**今すぐの必須対応ではない**。

---

## 6. 参考: エージェント以外の初期有効なエージェント的機能 (軽く確認)

深追いはしていない。既定状態の分かる範囲:

- **Community Hub (スキルのダウンロード/import)**: imported plugins は保存ディレクトリが空なら露出無し = 既定で機能せず。CLAUDE.md方針でも「既定無効」。**未確認**: UI導線からのimportを完全に塞ぐ実装が入っているかは本監査では未検証。
- **Agent Flows**: `AgentFlows.activeFlowPlugins()` はflowsディレクトリ依存。既定で空=露出無し。
- **MCP**: `activeMCPServers()` はMCP設定依存。既定で空=露出無し。オフライン方針と要整合(外部MCPサーバは禁止対象)。
- **Swagger docs**: CLAUDE.md方針で既定無効。本監査では設定状態を**未確認**。
- **外部LLMプロバイダ**: CLAUDE.md方針で provider を backend allowlist 化しローカル(ollama)のみ許可。本監査では allowlist 実装状態を**未確認**(スキル監査の範囲外)。

これらは本監査(エージェントスキル)の主対象外。必要なら別途、provider allowlist / Community Hub import導線 / Swagger の実コード確認を推奨。

---

## 付録: 主要な根拠ファイル(実読済み)

- `server/utils/agents/defaults.js` — `DEFAULT_SKILLS=[memory]`、`agentSkillsFromSystemSettings`、`default_agent_skills`/`disabled_agent_skills` 既定`[]`、clarifying questions 既定off
- `server/utils/agents/index.js` — `createAIbitat` で websocket/chat-history を常時attach(ただしLLM非露出)、`#attachPlugins` の露出経路
- `server/utils/agents/aibitat/plugins/index.js` — 全14スキルのエクスポート
- 各プラグイン本体: web-browsing.js / web-scraping.js / websocket.js / summarize.js / chat-history.js / memory.js / rechart.js / request-user-input.js / sql-agent/index.js / filesystem/index.js / create-files/index.js / gmail/index.js / outlook/index.js / google-calendar/index.js
- `server/models/systemSettings.js` — `default_agent_skills`/`disabled_agent_skills` のvalidation(既定`[]`、DBシード無し)
- `frontend/src/pages/Admin/Agents/skills.jsx` / `index.jsx` / `DefaultSkillPanel/index.jsx` — UIの既定トグル状態
