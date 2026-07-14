# RAG精度改善 手法調査（実装優先）2026-07-14

担当: Claude Code（技術リサーチャー）
対象システム: 完全ローカル日本語RAG（AnythingLLM fork + Ollama、LLM=gemma系12B、Embedding=`bge-m3`、Vector DB=LanceDB、dense検索・topN=8・チャンク最大500字）
課題: 546ページの数値密な日本語PDF（防衛白書）で、本文にある正解が検索・回答から漏れる。似た数値・年度が散在する文書で精度が出ない。

このレポートは、既存の社内調査（`RAG_ACCURACY_IMPROVEMENT_2026-07-11.md`、fork棚卸し `RAG_TUNING_POINTS_FORK_2026-07-10.md`）を前提に、**この構成で実装できる次の一手**を出典ベースで整理したもの。fork内の該当コード位置は棚卸しレポートから引用している。

---

## 0. 課題の構造（なぜ数値密文書で落ちるか）

現状は **純dense検索のみ**（LanceDBアダプタに full-text / hybrid のコードパスが無い＝`lance/index.js` に `fts`/`hybrid` 実装なし）。dense検索は意味的類似で強いが、**「令和5年度の艦艇数」「2.1兆円」「第○条」のような固有トークン・数値・年度の厳密一致に弱い**。防衛白書のように「似た数値・年度が多数散在」する文書では、意味ベクトルがどれも近接し、正解チャンクが埋没する（典型的なdenseの弱点）。この構造的欠点を埋める第一候補が **ハイブリッド検索（dense + BM25）** と **リランキング** である。

- 「疎（キーワード）は厳密一致に強く、密（意味）は言い換えに強い。両者は相補的で、併用がBM25単独・dense単独を上回る」— [BGE-M3 hybrid 検証](https://pristren.com/blog/bge-m3-embeddings-multilingual/) / [Hybrid RAG (Atlan)](https://atlan.com/know/hybrid-rag/)
- 「数値密文書ではdenseがキーワード一致を取りこぼす。BM25がrecallを救う」— [Hybrid Search + Reranking Playbook](https://optyxstack.com/rag-reliability/hybrid-search-reranking-playbook)

---

## 1. チャンク戦略

### 1-1. 日本語セパレータ（実施済み・確認）
- **概要**: `RecursiveCharacterTextSplitter` のセパレータに `。！？、` を追加し、日本語文境界で切る。
- **期待効果**: 文中ぶつ切りembedの解消。日本語RAGでは効果大。
- **実装可能性**: 実施済み（`TextSplitter/index.js` 1行修正）。→ 継続。
- 出典: [Advanced Chunking 2025 (Ailog)](https://app.ailog.fr/en/blog/news/chunking-strategies-2025)

### 1-2. 親子（Parent-Document）検索 ★推奨
- **概要**: 小チャンク（例256〜300字）で**精密に検索**し、LLMに渡すのは**その親チャンク（1024字前後 or 条文単位）**。検索単位と生成単位を分離する。
- **期待効果**: 「検索精度 vs 文脈量」のトレードオフを解消。数値の周辺文脈（年度・単位・主語）が親チャンクに含まれるので、数値だけ取れて意味を取り違える事故が減る。Stanford系検証で「parent-context が precision/recall のバランス最良」。
- **実装可能性**: **中規模改修**。AnythingLLMは「小チャンクembed→そのままLLMに注入」なので、①埋め込み時に `parentId`/`parentText` をメタデータに持たせ、②検索後に子→親へ展開する後処理を `lance/index.js` の検索応答（`similarityResponse`/`rerankedSimilarityResponse`）に追加する必要がある。LanceDBのスキーマにカラム追加＋展開ロジックで実現可能。upstreamに機能が無いのでfork独自実装。
- 出典: [日本語RAG精度向上事例（親子チャンキング, リベルクラフト）](https://liber-craft.co.jp/column/rag-accuracy-improvement-case-study) / [Denser.ai Chunking Strategies](https://denser.ai/blog/rag-chunking-strategies/)

### 1-3. チャンクサイズ / オーバーラップの最適値
- **概要**: 複雑・表混じり文書では 512〜1024トークンが最適域。オーバーラップは日付列・小計・見出し-値の関係を断ち切らない量（現行overlap=20字は小さい）。
- **期待効果**: recursive 512トークン分割が end-to-end 精度でトップ（69%）という2026ベンチもある。セマンティックチャンキングは平均43トークンの断片を生み逆効果になった例あり＝**「意味分割」より「素直な固定+適切なoverlap」が勝つことが多い**。
- **実装可能性**: **設定のみ**（管理UI「テキスト分割」）。ただし現構成の実効チャンクは `min(text_splitter_chunk_size, EMBEDDING_MODEL_MAX_CHUNK_LENGTH=500)` で頭打ち。bge-m3は最大8192トークンなので `EMBEDDING_MODEL_MAX_CHUNK_LENGTH` を上げれば512〜1024トークン級に拡張できる（※現状ここが num_ctx 兼用で文字/トークン単位混在＝§棚卸し#9の是正とセットで）。**変更後は全文書の再embedが必須**（vectorキャッシュパージ）。オーバーラップは 20→80〜120字を推奨実測。
- 出典: [Firecrawl: Best Chunking 2026](https://www.firecrawl.dev/blog/best-chunking-strategies-rag) / [langcopilot chunk size & overlap](https://langcopilot.com/posts/2025-10-11-document-chunking-for-rag-practical-guide) / [Semantic chunking はコスト見合わない (NAACL2025知見の紹介)](https://denser.ai/blog/rag-chunking-strategies/)

### 1-4. 表・数値を含む文書の扱い ★防衛白書に直結
- **概要**: 表は prose 用チャンカーだと行の途中で割れ、見出し-値の関係が壊れる。**表専用抽出（各行を「列名: 値」の自然文 or JSON化）してテキストチャンクとは別経路で保存**し、行単位・表単位で切る（date列・小計・数式チェーンを跨がない）。
- **期待効果**: table-aware chunking で検索失敗が対prose比 −35%。「$10.2M と $10,200,000.00 の不一致」のような数値の厳密性問題を緩和。
- **実装可能性**: **中〜大規模**。collector（文書パース側）の改修が必要。防衛白書PDFの表を pdfplumber/camelot 等で行抽出→「令和5年度 護衛艦 ○隻」のような行テキストに正規化してから投入。fork本体でなく前処理パイプラインで対応するのが現実解。優先度は表由来の失敗が評価で顕著な場合に上げる。
- 出典: [KX: table-heavy documents RAG](https://kx.com/blog/mastering-rag-precision-techniques-for-table-heavy-documents/) / [Daloopa: RAG for financial tables](https://daloopa.com/blog/analyst-best-practices/rag-systems-for-financial-tables-enhancing-excel-data-with-ai-context)

### 1-5. 見出し / メタデータ付与
- **概要**: 各チャンクに「章・節・見出し・年度・文書名」をメタデータとして付与し、検索スコアやLLM文脈に混ぜる。AnythingLLMは既に各チャンク先頭に `<document_metadata>`（タイトル・日付）を前置している。
- **期待効果**: セクション分類ラベルを付けて検索スコアに使うと精度がさらに伸びる、という金融RAG事例。数値密文書で「どの年度・どの章の数値か」を曖昧さ解消できる。
- **実装可能性**: **小〜中**。既存の `chunkHeader` 機構（`TextSplitter/index.js`）を拡張し、PDFの見出し階層（防衛白書なら「第○部 第○章」）をヘッダに含める。パース側で見出しを拾えれば低コスト。
- 出典: [Metadata enhancement for high-precision RAG (Medium)](https://medium.com/@shyamsundarmuthu/unlocking-high-precision-rag-the-role-of-metadata-enhancement-parsing-and-document-structuring-d5d17364b894)

---

## 2. 検索の高度化

### 2-1. ハイブリッド検索（dense + BM25）★最有力
- **概要**: bge-m3のdenseベクトル検索と、LanceDBのBM25全文検索（FTS）を併用し、**RRF（Reciprocal Rank Fusion）で結果を融合**。
- **期待効果**: 「ハイブリッド導入だけで検索精度62%→79%、さらにリランキングで91%」という日本語事例。BM25が「令和5年度」「2.1兆円」「第○条」などの厳密一致を拾い、denseが言い換えを拾う。**防衛白書の数値埋没問題に最も効く一手**。
- **実装可能性**: **中〜大規模だが道は明確**。
  - LanceDB（`@lancedb/lancedb` 0.15.0、fork同梱）は **BM25 FTS（Tantivy）とhybrid query・RRFRerankerをライブラリとしてサポートずみだがforkはこのパスを呼んでいない**。`lance/index.js` に「`text`カラムにFTSインデックス作成 + `fullTextSearch()` パス + RRF融合」を追加すれば実現できる。
  - **日本語の壁**: TantivyのデフォルトトークナイザはCJKを分かち書きできない。**N-gram（bi-gram）トークナイザ設定が必須**（設定しないと日本語BM25が機能しない）。LanceDBのFTSインデックスでtokenizer指定する。
  - **重要な制約**: bge-m3 の sparse/ColBERT ヘッドは **Ollama経由では取得できない**（OpenAI互換embedding APIはdenseのみ返す）。よって「bge-m3のsparseで疎検索」ルートは**この構成では不可**。疎側はLanceDBのBM25で担うのが正解。sparse/ColBERTを使いたければFlagEmbeddingを別プロセスで動かす必要があり、オフライン配布の複雑度が跳ね上がるため非推奨。
- 出典: [LanceDB hybrid search + BM25](https://www.lancedb.com/blog/hybrid-search-combining-bm25-and-semantic-search-for-better-results-with-lan-1358038fe7e6) / [LanceDB rerankers eval](https://docs.lancedb.com/reranking/eval) / [日本語RAG事例 62→79→91%](https://liber-craft.co.jp/column/rag-accuracy-improvement-case-study) / [bge-m3はOllama/OpenAI APIだとdenseのみ](https://huggingface.co/Xenova/bge-m3/discussions/4)

### 2-2. bge-m3 の sparse / multi-vector 活用
- **概要**: bge-m3は本来 dense/sparse/ColBERT を1モデルで同時出力し、sparse併用でBM25を上回る。
- **期待効果**: 疎密融合でBM25単独を上回る（原論文・検証）。
- **実装可能性**: **この構成では実質不可（要注意）**。前述の通りOllamaのembedding APIは dense のみ。sparse/ColBERTを得るには `FlagEmbedding` をPythonで直接動かす別サービスが要り、完全ローカル・単一バイナリ配布の方針と衝突。→ **sparseはbge-m3ではなくLanceDB BM25で代替する（2-1）**のが合理的。この項目は「やらない理由」を明記する目的で記載。
- 出典: [bge-m3 dense/sparse/colbert（BAAI）](https://huggingface.co/BAAI/bge-m3) / [Ollama/OpenAI APIはdenseのみ (Intel Community)](https://community.intel.com/t5/Intel-Distribution-of-OpenVINO/Bge-m3-model-output-dense-sparse-and-colbert-embeddings/m-p/1654371)

### 2-3. クエリ変換（HyDE / multi-query / step-back / 分解）
- **概要**:
  - **HyDE**: 質問から仮想回答文を生成し、その埋め込みで検索（語彙ギャップに強い）。
  - **multi-query**: 質問を複数の言い換えに展開して検索recallを上げる。
  - **step-back**: 具体質問を一段抽象化した問いに変換（前提知識の取得に有効）。
  - **分解**: 複合質問をサブ質問に割る。
- **期待効果**: recall向上。ただし**「直す失敗モードを特定してから足す」ことが原則**（無闇に足すとレイテンシだけ増える）。数値ピンポイント検索ではHyDEが的外れ回答文を生む懸念があり、むしろ**multi-query（年度・単位・同義語のバリエーション展開）や分解**が防衛白書向き。
- **実装可能性**: **中規模だが完全ローカルで可能**。追加LLM呼び出し（同梱gemmaで生成）→ 生成クエリで既存検索を複数回叩き結果マージ。fork本体の検索前段（`stream.js` のretrieval前）にフックを足す。ローカルLLMなのでAPIコストはゼロだがレイテンシは増える（1クエリ→N回embed+検索）。**リランカーとセットで使わないとノイズも増える点に注意**。
- 出典: [Query Transformation 実効性 (Alex Chernysh)](https://alexchernysh.com/blog/query-transformation-for-rag) / [multi-query/decomposition/step-back解説 (DEV)](https://dev.to/jamesli/in-depth-understanding-of-rag-query-transformation-optimization-multi-query-problem-decomposition-and-step-back-27jg) / [RAG精度改善 HyDE/Reranking（日本語）](https://chotdekiru.com/learn/courses/rag-basics/rag-improvement-retrieval)

---

## 3. リランキング

### 3-1. 日本語リランカーへの差し替え ★推奨（fork機構あり）
- **概要**: forkは既にリランカー機構（`vectorSearchMode="rerank"`）を持つが、モデルが **`Xenova/ms-marco-MiniLM-L-6-v2`（英語学習・日本語品質未保証）** でハードコード。これを**日本語対応cross-encoder**に差し替える。
- **候補モデル（JaCWIRベンチ, map@10 / hit_rate@10）**:
  | モデル | map@10 | hit@10 | 備考 |
  |---|---|---|---|
  | `hotchpotch/japanese-bge-reranker-v2-m3-v1` | 高（bge-v2-m3を日本語微調整し上回る） | — | bge-reranker-v2-m3の日本語強化版 |
  | `cl-nagoya/ruri-reranker-large` | 0.9463 | 0.99 | 日本語IRトップ級 |
  | `BAAI/bge-reranker-v2-m3` | 0.9343 | 0.9914 | 多言語標準 |
  | `hotchpotch/japanese-reranker-*-v2`（tiny/xsmall/small/base） | 軽量・ONNX量子化対応・CPU可 | — | **オフライン単一バイナリ配布に最適** |
- **期待効果**: dense上位候補の並べ替えで文脈適合度が上がる。日本語事例で「ハイブリッド79%→リランキングで91%」。NVIDIAの日本語検証でもリランカー追加で nDCG@10 が +3.7pt。**リランカーは「recallは取れているが順位が悪い」ときに効く／そもそも正解が候補に入っていないときは効かない**（＝ハイブリッドで候補を広げてからリランクするのが定石）。
- **実装可能性**: **中規模**。fork のリランカーは `@xenova/transformers`（ONNX/CPU）でローカル実行。モデル名を差し替え（`EmbeddingRerankers/native/index.js:18`）＋**ONNX化した日本語モデルをオフライン同梱**（`STORAGE_DIR/models/` に事前配置）。hotchpotchの `japanese-reranker-*-v2` はONNX量子化版が用意されCPUで軽量に回るため、GPU非搭載リスクのある士業PCとも相性が良い。**候補取得数**は現状 `max(10, min(50, 全embedding数×10%))`。リランク前候補は30〜100件が定石（多いほどrecall↑だがレイテンシ↑）。リランク使用時は `similarityThreshold=0` 運用（二重フィルタ回避）。
- 出典: [NVIDIA 日本語リランキング検証（nDCG@10 +3.7pt, 2段階top50→top10）](https://developer.nvidia.com/ja-jp/blog/rag-with-sota-reranking-model-in-japanese/) / [hotchpotch/japanese-bge-reranker-v2-m3-v1](https://huggingface.co/hotchpotch/japanese-bge-reranker-v2-m3-v1) / [hotchpotch/japanese-reranker-tiny-v2（ONNX/CPU）](https://huggingface.co/hotchpotch/japanese-reranker-tiny-v2) / [cl-nagoya/ruri-reranker-large](https://huggingface.co/cl-nagoya/ruri-v3-reranker-310m) / [JaCWIRベンチ](https://github.com/hotchpotch/JaCWIR)

### 3-2. 候補数の目安
- bi-encoderで top-30〜100（数値密で埋もれやすいなら広め）を取り、リランク後 top-8〜10 をLLMへ。150取得→15出力の事例もある。**recallとレイテンシのトレードオフを評価セットで実測して決める**。
- 出典: [Best Rerankers 2026 (FutureAGI)](https://futureagi.com/blog/best-rerankers-for-rag-2026/) / [Local reranking guide](https://localaimaster.com/blog/reranking-cross-encoders-guide)

---

## 4. 回答生成

### 4-1. コンテキストの並び順（Lost in the Middle）★低コスト高効果
- **概要**: LLMは長文脈の**先頭と末尾を重視し中央を見落とす**。リランク後、最重要チャンクを先頭または末尾に置く（両端に重要文を配置する reorder）。
- **期待効果**: 位置の最適化だけで回答精度が改善（2026でも1Mトークンモデルで健在の現象）。topN=8で「正解が5番目にある」と埋もれるのを救う。
- **実装可能性**: **小規模**。リランク済みリストをLLMに渡す前に「1位を末尾（or 先頭）に、下位を中央に」並べ替えるだけ。fork の `contextTexts` 構築部（`stream.js`/`convertTo.js`）に並べ替えを1関数追加。リランカー導入とセットで最大効果。
- 出典: [Lost in the Middle は2026も健在 (DEV)](https://dev.to/gabrielanhaia/lost-in-the-middle-is-still-real-in-2026-even-on-1m-token-models-2ehj) / [Solving Lost in the Middle (Maxim)](https://www.getmaxim.ai/articles/solving-the-lost-in-the-middle-problem-advanced-rag-techniques-for-long-context-llms/)

### 4-2. プロンプト設計・出典強制・数値/固有名詞の扱い
- **概要**: 「文書外は不明」「出典（文書名）明示」「内部CONTEXT番号を露出しない」を既定プロンプトで強制（fork改修済み）。数値質問には「**引用した数値は文書の表記のまま（桁区切り・単位・年度）で答える／推計しない**」を追加。
- **期待効果**: ハルシネーション抑止（現構成でハルシネーションゼロ達成済み）。数値の言い換え・丸めによる誤答を防ぐ。
- **実装可能性**: **設定のみ**（既定システムプロンプト追記）。低コスト。数値密文書では即入れる価値あり。
- 出典: [数値の厳密性要件（金融RAG）](https://vinayakajyothi.com/blog/2026-03-31-rag-financial-documents-accuracy/) / 社内実績 `RAG_ACCURACY_IMPROVEMENT_2026-07-11.md`

---

## 5. 日本語RAG特有の注意点

- **トークナイズ**: 日本語はスペース区切りが無いため、①`RecursiveCharacterTextSplitter`のセパレータに句読点必須（実施済み）、②**BM25/FTSにはN-gram（bi-gram）トークナイザ必須**（デフォルトのCJK非対応トークナイザでは日本語キーワード検索が機能しない）。ハイブリッド化の隠れた必須条件。
- **embedding選定**: mxbai（英語特化）は日本語言い換え検索で正解をtop8に入れられず、bge-m3で解消済み（社内実測 d:0/5→3/5）。bge-m3は**クエリ/パッセージのプレフィックス不要**（旧BGEと違い instruction 付与は不要）＝forkの「プレフィックス無し」実装は bge-m3 では正しい。将来 `cl-nagoya/ruri-v3` 系（日本語特化embed）がOllamaで成熟したら比較評価の価値あり。
- **reranker選定**: §3-1の通り日本語対応必須。ms-marco英語モデルのままでは日本語で伸びない。
- 出典: [bge-m3はprefix不要（BAAI discussion）](https://huggingface.co/BAAI/bge-m3/discussions/35) / [Best Ollama Embedding Models 2026](https://www.morphllm.com/ollama-embedding-models) / 社内実測 `RAG_ACCURACY_IMPROVEMENT_2026-07-11.md`

---

## 6. 評価手法

### 6-1. 評価セットの作り方（既に社内で実践中）
- **概要**: 実運用を模した Q&A セット。社内では30問（単一事実10 / 紛らわしい数値判別10 / 文書外＝不明期待5 / 言い換え5）を構築済み。防衛白書向けには「似た数値・年度の判別問題」を厚くし、各問に**正解チャンク（gold context）と正解文書名**を紐付ける。
- **推奨規模**: 50〜200問（多様性が無いと数を増やしても効用逓減）。
- **retrieval単体指標**: **Hit Rate@k（正解チャンクが上位kに入るか）** と **MRR** を、施策ごとに（dense単独 / +BM25 / +rerank / +並べ替え）で計測。回答生成前の retrieval を切り分けて評価するのが改善の勘所。
- 出典: [Ragas metrics guide 2026](https://qaskills.sh/blog/ragas-rag-evaluation-metrics-complete-guide) / [RAGAS 評価データセット 50-200問](https://superlinked.com/blog/evaluating-retrieval-augmented-generation-ragas)

### 6-2. RAGAS 指標
- **Faithfulness**（回答が文脈に忠実か）と **Answer Relevancy**（質問への適合）は ground truth 不要で本番トラフィックにも使える。
- **Context Recall**（必要情報を検索できたか）と **Context Precision** は retrieval 品質の指標。Context Recall のみ人手 ground truth が必要。
- **実装可能性**: RAGASはLLM-as-judge。**完全ローカル制約**では judge に外部APIを使えないため、**同梱ローカルLLM（gemma）or 評価専用のローカルモデルを judge に据える**か、開発時のみ（顧客環境外の手元PCで）評価する運用が現実的。retrieval指標（Hit Rate/MRR）はLLM不要で回せるので**まずはHit Rate/MRR中心**、faithfulnessは補助。
- 出典: [RAG評価指標 (Confident AI)](https://www.confident-ai.com/blog/rag-evaluation-metrics-answer-relevancy-faithfulness-and-more) / [RAGAS docs: test set評価](https://docs.ragas.io/en/v0.1.21/getstarted/evaluation.html)

---

## まず試すべき施策 上位5つ（効果 × 実装容易性）

| 順位 | 施策 | 効果 | 実装容易性 | 根拠 |
|---|---|---|---|---|
| **1** | **日本語リランカーへ差し替え + リランク有効化**（`hotchpotch/japanese-reranker-*-v2` ONNX or `japanese-bge-reranker-v2-m3-v1` を同梱、`vectorSearchMode="rerank"`、threshold=0） | 大 | 中（fork機構あり・モデル差替＋同梱） | fork既に機構保有・ms-marcoは英語。日本語事例+リランクで大幅改善、NVIDIA検証 nDCG+3.7pt。GPU非搭載でもCPU ONNXで回る |
| **2** | **コンテキスト並べ替え（Lost in the Middle 対策）** | 中〜大 | 小（数十行） | リランク結果の最重要を両端に。位置最適化のみで改善、施策1と相乗。最小工数 |
| **3** | **ハイブリッド検索（dense + LanceDB BM25/FTS, N-gramトークナイザ）** | 大（数値密文書の本丸） | 中〜大（`lance/index.js`に検索パス追加＋日本語トークナイザ） | 数値・年度・固有名詞の厳密一致をBM25が救う。日本語事例62→79%。LanceDBが機能を保有（呼んでいないだけ） |
| **4** | **数値厳密プロンプト + チャンクoverlap増（20→80〜120字）+ メタデータ見出し付与** | 中 | 小〜中（設定＋パース） | 数値の丸め・言い換え誤答を抑止。overlap増で数値の周辺文脈（年度・単位）の断裂を防ぐ。設定中心で低リスク |
| **5** | **親子（Parent-Document）検索**（小チャンク検索→親チャンク注入） | 大 | 中（メタデータ＋展開ロジック） | 数値だけ取れて文脈取り違える事故を構造的に防ぐ。1と3で頭打ちになったら着手。検証/工数は最大 |

**推奨ロードマップ**: まず **1→2** を入れて評価セット（Hit Rate/MRR）で効果測定（低工数・高確度）。次に数値密問題の本丸 **3** を入れる（トークナイザ検証が要）。**4** は並行で随時。**5** は 1・3 で伸び代が頭打ちになった段階で。クエリ変換（HyDE/multi-query, §2-3）は「特定の失敗モードが評価で見えてから」＝**最初は入れない**（レイテンシとノイズのコスト先行）。

> 補足: bge-m3 の sparse/ColBERT を使うハイブリッドは魅力的だが、**Ollama経由ではdenseしか出ないため本構成では非現実的**。疎検索はLanceDBのBM25で代替するのが正しい設計判断（§2-1, 2-2）。

---

### 主要出典（まとめ）
- ハイブリッド/BGE-M3: [pristren BGE-M3](https://pristren.com/blog/bge-m3-embeddings-multilingual/) / [Atlan Hybrid RAG](https://atlan.com/know/hybrid-rag/) / [LanceDB hybrid+BM25](https://www.lancedb.com/blog/hybrid-search-combining-bm25-and-semantic-search-for-better-results-with-lan-1358038fe7e6) / [bge-m3 API dense only](https://huggingface.co/Xenova/bge-m3/discussions/4)
- チャンク: [Firecrawl 2026](https://www.firecrawl.dev/blog/best-chunking-strategies-rag) / [Denser.ai](https://denser.ai/blog/rag-chunking-strategies/) / [表対応 KX](https://kx.com/blog/mastering-rag-precision-techniques-for-table-heavy-documents/) / [親子 リベルクラフト](https://liber-craft.co.jp/column/rag-accuracy-improvement-case-study)
- リランキング: [NVIDIA 日本語](https://developer.nvidia.com/ja-jp/blog/rag-with-sota-reranking-model-in-japanese/) / [JaCWIR](https://github.com/hotchpotch/JaCWIR) / [hotchpotch japanese-bge-reranker-v2-m3-v1](https://huggingface.co/hotchpotch/japanese-bge-reranker-v2-m3-v1)
- Lost in the middle: [DEV 2026](https://dev.to/gabrielanhaia/lost-in-the-middle-is-still-real-in-2026-even-on-1m-token-models-2ehj)
- クエリ変換: [Alex Chernysh](https://alexchernysh.com/blog/query-transformation-for-rag) / [DEV 解説](https://dev.to/jamesli/in-depth-understanding-of-rag-query-transformation-optimization-multi-query-problem-decomposition-and-step-back-27jg)
- 評価: [Ragas guide](https://qaskills.sh/blog/ragas-rag-evaluation-metrics-complete-guide) / [Confident AI](https://www.confident-ai.com/blog/rag-evaluation-metrics-answer-relevancy-faithfulness-and-more)
- 日本語embed: [bge-m3 prefix不要](https://huggingface.co/BAAI/bge-m3/discussions/35)
