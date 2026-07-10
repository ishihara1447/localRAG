# RAG検索精度チューニングポイント棚卸し（fork調査 2026-07-10）

対象: `repos/localRAG/anything-llm/`（branch: `product/customer-rag-base`, HEAD: fd67e830）
調査方法: コード読解のみ（変更なし）。パスはすべて `anything-llm/` からの相対。

現在の運用構成（`runtime/docker-compose.yml`）:
- LLM: `LLM_PROVIDER=ollama` / `llm-jp-4-8b-thinking-gguf:Q4_K_M`（token limit 8192, L89）
- Embedding: `EMBEDDING_ENGINE=ollama` / `mxbai-embed-large:latest` / `EMBEDDING_MODEL_MAX_CHUNK_LENGTH=500`（L95-98）
- Vector DB: LanceDB（既定）

---

## 0. 既定値一覧表（サマリー）

| パラメータ | 現在値/既定値 | 定義場所 | スコープ | 変更手段 |
|---|---|---|---|---|
| `topN` | 4 | `server/prisma/schema.prisma:138`（DB default）+ `server/models/workspace.js:90-96`（validation fallback） | ワークスペース | UI（WS設定→ベクトルDB→最大コンテキスト断片, 1〜200）/ API |
| `similarityThreshold` | 0.25 | `server/prisma/schema.prisma:135` + `server/models/workspace.js:82-89` | ワークスペース | UI（選択肢 0 / 0.25 / 0.5 / 0.75 のみ）/ API（0〜1連続値可） |
| `vectorSearchMode` | `"default"`（リランクOFF） | `server/prisma/schema.prisma:144` + `server/models/workspace.js:126-134`（`"default"`/`"rerank"` のみ許可） | ワークスペース | UI（WS設定→ベクトルDB→検索モード）/ API |
| `chatMode` | DB default `"chat"` だが新規作成時に `"automatic"` を明示セット | `server/prisma/schema.prisma:139` / `server/models/workspace.js:217` | ワークスペース | UI / API（`chat`/`query`/`automatic`, `workspace.js:36`） |
| `openAiHistory`（履歴数） | 20 | `server/prisma/schema.prisma:131` | ワークスペース | UI / API |
| チャンクサイズ `text_splitter_chunk_size` | 未設定→embedder上限にキャップ（現構成では**実効500**） | system_settings（DB）。フォールバック連鎖: `lance/index.js:346-351` → `TextSplitter.determineMaxChunkSize`（`server/utils/TextSplitter/index.js:47-57`）→ 最終既定1000（`index.js:159`） | グローバル | 管理UI（設定→テキスト分割）/ admin API（`server/endpoints/admin.js:389-394`） |
| チャンクオーバーラップ `text_splitter_chunk_overlap` | 20（文字） | system_settings。fallback指定 `lance/index.js:352-355`、最終既定 `TextSplitter/index.js:160-162` | グローバル | 同上 |
| `EMBEDDING_MODEL_MAX_CHUNK_LENGTH` | 500（runtime設定） | env。`server/utils/helpers/index.js:560-569`（未設定時1000）、envキー登録 `server/utils/helpers/updateENV.js:258` | グローバル(env) | env変数 |
| チャンク分割セパレータ | `["\n\n", "\n", " ", ""]`（langchain既定、**日本語句読点なし**） | `server/node_modules/@langchain/textsplitters/dist/text_splitter.js:226`。fork側ラッパは未指定（`server/utils/TextSplitter/index.js:184-187`） | グローバル(コード) | **コード修正のみ**（下記 §2） |
| 距離指標 | cosine（明示指定） | `server/utils/vectorDbProviders/lance/index.js:129, 193` | 固定 | コード修正のみ |
| リランカーモデル | `Xenova/ms-marco-MiniLM-L-6-v2`（ハードコード） | `server/utils/EmbeddingRerankers/native/index.js:18` | グローバル(コード) | コード修正のみ |
| リランク時の候補取得数 | `max(10, min(50, 全embedding数の10%))` | `lance/index.js:123-126` | 固定 | コード修正のみ |
| 既定システムプロンプト | 日本語ハルシネーション抑止プロンプト（fork改修済み） | `server/models/systemSettings.js:40-48`（`saneDefaultSystemPrompt`）。新規WS作成時に `default_system_prompt`（system_settings）→ これの順で適用（`server/models/workspace.js:206-211`） | グローバル既定＋WS上書き | 管理UI or WS設定 |
| `queryRefusalResponse` | null（→英語の既定文言 `stream.js:96-97`） | `server/prisma/schema.prisma:143` | ワークスペース | UI / API |

---

## 1. 検索パラメータ（topN / similarityThreshold）

### 変数名と既定値の定義場所

- 変数名はワークスペースカラムそのままの **`topN`** と **`similarityThreshold`**（`similarityTopN` という名前は存在しない）。
- **DBスキーマdefault**: `server/prisma/schema.prisma:135`（`similarityThreshold Float? @default(0.25)`）、`:138`（`topN Int? @default(4)`）。新規ワークスペース作成（`Workspace.new`, `server/models/workspace.js:194-232`）はこれらのフィールドを渡さないため、**Prismaのdefaultがそのまま新規WSの既定値になる**。
- **モデル層のvalidation fallback**: `server/models/workspace.js:82-89`（threshold: null→0.25, 範囲0〜1にクランプ）、`:90-96`（topN: null→4, 最小1）。これは更新API経由の値検証用。
- **検索実行側のフォールバック**: `server/utils/vectorDbProviders/lance/index.js:97-98, 180-181, 414`（引数デフォルト `topN=4, similarityThreshold=0.25`）。チャットからは常にワークスペースの値が渡される（`server/utils/chats/stream.js:183-184`）ので、通常こちらは効かない（WS値がnullのときのみ）。

### similarityThreshold の適用方法（LanceDB）

- LanceDBはcosine**距離**を返し、`distanceToSimilarity()`（`lance/index.js:43-48`）で `similarity = 1 - distance` に変換。
- **フィルタは検索後のポスト処理**: `lance/index.js:197-199`（通常検索）、`:137-138`（リランク検索）で `similarity < threshold` の行を捨てる。つまり「topN件取得→閾値未満を除外」なので、**閾値により実際のコンテキストはtopN未満になり得る**（ANN検索自体には閾値は渡らない）。

### 「新規WSの既定値」をサーバー側で変える最小変更点

**env変数化はされていない。完全にハードコード。** 変更候補（小さい順）:

1. **`server/models/workspace.js:194`（`Workspace.new`）に既定additionalFieldsをマージ** — 1ファイル小修正。例: `additionalFields = { topN: 8, similarityThreshold: 0.0, vectorSearchMode: "rerank", ...additionalFields }`。DBマイグレーション不要、既存WSに影響なし。env読み込みにすれば実質env化できる（例: `process.env.DEFAULT_TOPN`）。
2. `server/prisma/schema.prisma:135,138,144` のdefault変更 — マイグレーション必要（`prisma migrate`）。upstream追従時にconflictしやすい。
3. validation fallback（`workspace.js:82-96`）も揃えて変えると一貫するが必須ではない。

※ 既存ワークスペースはUI/APIで個別変更（`topN` UIは1〜200まで入力可: `frontend/src/pages/WorkspaceSettings/VectorDatabase/MaxContextSnippets/index.jsx:20-22`。thresholdのUIは0/0.25/0.5/0.75の4択のみ: `.../DocumentSimilarityThreshold/index.jsx:24-29`。中間値はAPI `POST /v1/workspace/:slug/update` でなら設定可能）。

---

## 2. チャンキング（TextSplitter）

実装: `server/utils/TextSplitter/index.js`（langchain `RecursiveCharacterTextSplitter` の薄いラッパ）。

### 既定値と決定ロジック

チャンクサイズは vectorize 時（LanceDBの `addDocumentToNamespace`, `lance/index.js:344-358`）に決まる:

```
chunkSize = TextSplitter.determineMaxChunkSize(
    system_settings.text_splitter_chunk_size,   // DB設定（未設定ならnull）
    EmbedderEngine.embeddingMaxChunkLength      // 現構成では 500
)
```

- `determineMaxChunkSize`（`TextSplitter/index.js:47-57`）: DB設定値とembedder上限の**小さい方**を採用。DB未設定なら embedder 上限そのもの。→ **現構成の実効チャンクサイズは500文字**（単位は文字数。langchain既定のlengthFunctionは文字長）。
- オーバーラップ: `system_settings.text_splitter_chunk_overlap`、fallback 20（`lance/index.js:352-355`）。
- 最終セーフティ: `TextSplitter/index.js:159-162`（NaNなら chunkSize=1000 / overlap=20）。

### 変更手段

- **グローバルのみ**（ワークスペース単位のチャンク設定は存在しない）。管理UI「テキスト分割」→ system_settings に保存（`server/endpoints/admin.js:389-394`）。validation は `server/models/systemSettings.js:128-156`。
- 注意: この設定を更新すると **vectorキャッシュが全パージされる**（`systemSettings.js:132,148` の `purgeEntireVectorCache()`）。既存文書は再アップロード（再embed）しないと新チャンクサイズにならない。

### 日本語・条文単位分割の余地

- ラッパは `RecursiveCharacterTextSplitter` に **`chunkSize`/`chunkOverlap` しか渡していない**（`TextSplitter/index.js:184-187`）。セパレータはlangchain既定の `["\n\n", "\n", " ", ""]`（`server/node_modules/@langchain/textsplitters/dist/text_splitter.js:226`）で、**「。」「、」や「第◯条」区切りは効かない**。日本語はスペースがないため、実質「改行がなければ500文字でぶつ切り」になる。
- インストール済みパッケージは `separators` と `keepSeparator` をサポート済み（`text_splitter.js:228-229`）。**`TextSplitter/index.js:184-187` に `separators: ["\n\n", "\n", "。", "．", "、", " ", ""]` 等を1行足すだけで日本語文境界分割が効く**（1ファイル小修正）。条文単位なら正規表現ベースの前処理（`第\d+条` の直前に `\n\n` を挿入する等）をcollector側か splitText 前段に足すのが現実解（中規模修正）。
- チャンクヘッダ: 各チャンク先頭に `<document_metadata>`（タイトル・日付等）が付与される（`TextSplitter/index.js:64-118, 135-147`）。これも500文字の内数ではなく**チャンク分割後に前置**される点に注意（`index.js:196-199`、createDocumentsのchunkHeader）。つまり実際にembedされるテキストはchunkSizeより長くなる。

---

## 3. リランカー対応 — **存在する（ローカルONNX実行）**

- 実装: `server/utils/EmbeddingRerankers/native/index.js`。`@xenova/transformers`（transformers.js, ONNX/CPU）で **`Xenova/ms-marco-MiniLM-L-6-v2`** をローカル実行（`index.js:18`）。**外部APIではない**。モデルは初回にHF（失敗時 `cdn.anythingllm.com`, `index.js:13`）から `STORAGE_DIR/models/` へダウンロード・キャッシュ（`index.js:19-30`）→ **オフライン配布ではモデルファイルの事前同梱が必要**（顧客配布要件と関わる）。
- 有効化: **ワークスペースごと**に `vectorSearchMode = "rerank"`（UI: WS設定→ベクトルDB→検索モード。モデル層validation `server/models/workspace.js:126-134`）。チャット時に `rerank: workspace?.vectorSearchMode === "rerank"` として渡る（`stream.js:186`, `apiChatHandler.js:329,705`, `openaiCompatible.js`, `embed.js` も同様）。
- 動作（`lance/index.js:92-163`）:
  1. ベクトル検索で `max(10, min(50, 全embedding数×10%))` 件を取得（`:123-126`）
  2. cross-encoderでリランクし `topK=topN` 件に絞る（`:133-134`、`EmbeddingRerankers/native/index.js:224-252`）
  3. その後に similarityThreshold フィルタ（**リランクスコアではなく元のベクトル距離ベース**で判定: `lance/index.js:137`。スコア表示は `rerank_score` 優先: `:146-147`）
- 対応プロバイダはこの native 1種のみ（`server/utils/EmbeddingRerankers/` 配下は `native/` のみ）。モデル差し替えは `native/index.js:18` の1行修正（ただしms-marcoは英語学習モデルで**日本語ペアの品質は未保証**。日本語なら例えば `hotchpotch/japanese-reranker-*` 系ONNX化 or BGE-reranker-v2-m3等への差し替え検討価値あり=中規模修正）。
- 注意: threshold>0 のままrerankを使うと「ベクトル距離で足切り→rerank結果が減る」二重フィルタになる。rerank使用時はthreshold=0運用が素直。

---

## 4. LanceDBアダプタの検索実装

`server/utils/vectorDbProviders/lance/index.js`:

- 検索は `performSimilaritySearch`（`:410-460`）→ `similarityResponse`（`:176-217`）または `rerankedSimilarityResponse`（`:92-163`）。
- **純粋ベクトル検索のみ**: `collection.vectorSearch(queryVector).distanceType("cosine").limit(topN)`（`:191-195`）。**full-text search / hybrid検索のコードパスは存在しない**（`fts`/`hybrid`/`fullText` のgrepヒットなし）。
- ただし依存パッケージ `@lancedb/lancedb: 0.15.0`（`server/package.json:27`）は FTS（BM25, `table.createIndex` + `query().fullTextSearch()`）と hybrid query をライブラリとしてはサポートしているため、**hybrid化はアダプタ内改修だけで実現可能**（`text` カラムにFTSインデックス作成＋検索パス追加。日本語はデフォルトトークナイザが効かないためN-gram tokenizer設定が必要。大改修寄りの中規模）。
- 距離指標: **cosine距離**（明示指定 `:129, :193`）。`similarity = 1 - distance` 変換は `:43-48`。
- クエリのembed: `LLMConnector.embedTextInput(input)`（`:431`）→ LLMプロバイダ経由で設定済みembedderに委譲（`server/utils/AiProviders/ollama/index.js:499-500`）。**クエリ側プレフィックスは付かない**（ollama embedderに `embeddingPrefix` 実装なし。mxbai-embed-large 推奨の query prompt `"Represent this sentence for searching relevant passages: "` は未適用。ドキュメント側prefixも同様に無し）。

---

## 5. クエリモード（`mode: "query"`）のフロー

`server/utils/chats/stream.js`（API経由は `apiChatHandler.js` にほぼ同一実装）:

1. **embedding 0件の早期リターン**: WSにベクトルが1つもない場合、`queryRefusalResponse`（WS設定, 未設定なら英語既定文 "There is no relevant information..."）を即返す（`stream.js:94-121`）。
2. ピン留め文書＋parsed files を無条件でコンテキストに追加（`:142-175`）。
3. ベクトル検索実行（`:177-192`）。`similarityThreshold`/`topN`/`rerank` はすべてワークスペース値。
4. **バックフィル**: 検索結果がtopN未満のとき、`fillSourceWindow`（`server/utils/helpers/chat/index.js:382-442`）が**過去チャット（直近 openAiHistory=20件）の引用ソースから不足分を補充**する（`stream.js:207-222`）。→ query modeでも「今回の検索が0件でも過去ターンのソースで回答が続く」ことがある。精度検証時はこの挙動に注意（新規スレッドで試すこと）。
5. **query mode の拒否判定**: 検索＋バックフィル＋ピン留めの合計 `contextTexts.length === 0` のときだけ `queryRefusalResponse` を返して終了（`stream.js:227-254`）。閾値が高すぎて0件になるとここに落ちる。
6. **履歴の扱い**: query modeでも会話履歴はプロンプトに**含まれる**（`chatHistory` を `compressMessages` に渡す, `stream.js:265-274`。履歴取得は `recentChatHistory`, `chats/index.js:61-82`, 上限 `openAiHistory`）。chat/queryの差は「コンテキスト0件時に拒否するか否か」と上記1の早期リターンのみで、**retrievalロジック自体は同一**。
7. コンテキスト注入形式: system promptに `[CONTEXT n]: ... [END CONTEXT n]` 形式で連結（ollamaプロバイダ `server/utils/AiProviders/ollama/index.js:123`、汎用 `server/utils/helpers/chat/convertTo.js:235`）。
8. `chatMode="automatic"` は fork系の新モード（`workspace.js:36`, 新規WS既定 `:217`）。retrieval面はchatと同じで、agent tooling判定に使われる（`chats/agents.js:49-51`）。embed widgetでは `automatic`→`chat` に落とす（`chats/embed.js:23`）。

---

## 6. EMBEDDING_MODEL_MAX_CHUNK_LENGTH（現在500）の効き方

- 読み取り: `maximumChunkLength()`（`server/utils/helpers/index.js:560-569`）。env未設定または不正なら**1000**。envキー登録は `server/utils/helpers/updateENV.js:258`（UIの埋め込み設定 "EmbeddingModelMaxChunkLength" からも変更可）。
- Ollama embedder は これを `this.embeddingMaxChunkLength` に採用（`server/utils/EmbeddingEngines/ollama/index.js:21`）。効く場所は2つ:
  1. **チャンクサイズの上限**: §2の通り `determineMaxChunkSize` の第2引数（`lance/index.js:350`）。→ 500 が実効チャンクサイズ上限。
  2. **Ollama embed呼び出しの `num_ctx`**: `EmbeddingEngines/ollama/index.js:104-110` で `options.num_ctx = 500` として渡す。ここは**トークン数**の意味。mxbai-embed-large の最大系列長は512トークンで、日本語500文字は概ね400〜700トークン相当のため、**「500文字チャンク＋メタデータヘッダ」が num_ctx=500 を超えて末尾切り捨てになるリスクがある**（文字数とトークン数の単位混在がこの設計の弱点）。チャンクヘッダ分（§2末尾）も上乗せされる。
- 関係整理: `実効チャンクサイズ(文字) = min(text_splitter_chunk_size, EMBEDDING_MODEL_MAX_CHUNK_LENGTH)`、かつ同じ値がollamaのnum_ctx(トークン)に流用される。値を上げる場合は embed モデルの系列長（mxbai=512tok）を超えない範囲で。

---

## 7. ワークスペース単位 vs グローバルの区分け

| スコープ | パラメータ |
|---|---|
| **ワークスペース単位**（UI/APIで個別設定） | `topN`, `similarityThreshold`, `vectorSearchMode`(rerank), `chatMode`, `openAiHistory`, `openAiPrompt`(システムプロンプト), `queryRefusalResponse`, `openAiTemp` |
| **グローバル: system_settings（DB, 管理UI）** | `text_splitter_chunk_size`, `text_splitter_chunk_overlap`, `default_system_prompt`(新規WS用既定) |
| **グローバル: env** | `EMBEDDING_MODEL_MAX_CHUNK_LENGTH`, `EMBEDDING_ENGINE`, `EMBEDDING_MODEL_PREF`, `EMBEDDING_BASE_PATH`, `OLLAMA_EMBEDDING_BATCH_SIZE`（`EmbeddingEngines/ollama/index.js:18-20`）, `STORAGE_DIR` |
| **コード固定（ハードコード）** | 新規WSの `topN`/`threshold` 既定値, 距離指標(cosine), TextSplitterのセパレータ, リランカーモデル名, リランク候補数(10〜50), バックフィル挙動 |

チャンク設定はグローバルなので「ワークスペースAは条文向け・Bは議事録向け」のような分割ポリシーの出し分けは現状不可（vectorize時に一律適用）。

---

## 8. 精度向上のための変更候補（変更規模つき）

| # | 変更 | 場所 | 規模 | 期待効果 |
|---|------|------|------|------|
| 1 | **日本語セパレータ追加**（`separators: ["\n\n", "\n", "。", "！", "？", "、", " ", ""]` + 必要なら`keepSeparator`調整） | `server/utils/TextSplitter/index.js:184-187` | **1ファイル小修正**（数行） | 文中ぶつ切りembedの解消。日本語RAGでは効果大 |
| 2 | **リランク有効化**（既存WSはUI/APIで `vectorSearchMode="rerank"`、その際 threshold=0 に） | 設定変更のみ（コード変更ゼロ） | **設定のみ** | 上位候補の並べ替えで文脈適合度向上。ただしms-marcoは英語モデルのため日本語での効果は要実測 |
| 3 | **新規WS既定値の底上げ**（topN=6〜10, threshold=0.0 or 0.25維持, rerank既定ON等）をenv読み込みで | `server/models/workspace.js:194-232`（`Workspace.new`にマージ） | **1ファイル小修正**（env追加込み） | 配布先で顧客がWSを作っても常にチューニング済み設定になる |
| 4 | チャンクサイズ/オーバーラップの見直し（例: overlap 20→50-100文字。管理UIから設定、vectorキャッシュパージ＋再embed必要） | 管理UI（system_settings） | **設定のみ**（再embedコスト有） | 500文字は条文には妥当だが文脈切れ対策にoverlap増は有効 |
| 5 | mxbai用クエリプレフィックス付与（`embedTextInput` 時のみ `"Represent this sentence for searching relevant passages: "` を前置） | `server/utils/EmbeddingEngines/ollama/index.js`（`embedTextInput`, L58-63付近） | 1ファイル小修正（ただし**既存文書の再embed不要**=クエリ側のみ） | mxbaiの推奨運用に一致、retrieval精度改善の可能性。日本語文書での効果は要実測 |
| 6 | 日本語リランカーへの差し替え（ONNX化した日本語cross-encoder） | `server/utils/EmbeddingRerankers/native/index.js:18` ＋モデル同梱 | 中規模（モデル選定・オフライン同梱・検証） | 日本語ペアのリランク品質向上 |
| 7 | 条文プリチャンキング（`第\d+条` 境界で改行挿入する前処理） | collector側 or `TextSplitter.splitText` 前段 | 中規模 | 法令・規程文書で条文単位の検索単位が保てる |
| 8 | LanceDB hybrid検索（FTS/BM25＋ベクトル、日本語はN-gram tokenizer） | `server/utils/vectorDbProviders/lance/index.js` 検索パス追加 | **大改修** | 固有名詞・条番号などキーワード一致の取りこぼし対策。効果は大きいが工数大 |
| 9 | num_ctx単位混在の是正（`EMBEDDING_MODEL_MAX_CHUNK_LENGTH` とは別に num_ctx を512固定 or 余裕を持たせる） | `server/utils/EmbeddingEngines/ollama/index.js:104-110` | 1ファイル小修正 | チャンク末尾のサイレント切り捨て防止 |

### 検証時の注意

- チャンク設定変更は `purgeEntireVectorCache()` が走るだけで**既存ベクトルは残る**。効かせるには文書の削除→再アップロード（再embed）が必要。
- query modeの精度測定はバックフィル（§5-4）の影響を避けるため新規スレッドで行う。
- rerank初回実行時にモデルDLが走る（オフライン環境では事前に `STORAGE_DIR/models/Xenova/ms-marco-MiniLM-L-6-v2` を配置）。
