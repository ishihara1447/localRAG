# 調査: 検索粒度ミスマッチ（Retrieval Granularity Mismatch）の既知解法

調査日: 2026-07-28
対象: OTE-RAG（bge-m3 + hybrid + bge-reranker-v2-m3、令和7年版防衛白書544p、166問）
実施: researcherサブエージェント（Write権限が無かったため本ファイルはClaude Codeが保存）

## サマリー

1. 「ページは取れるが文が取れない」は文献上 **未解決の既知問題**として名前が付いており（Dense X Retrieval の "retrieval granularity" 問題、CapRetrieval の "granularity dilemma"）、**k を増やす方向では原理的に解けない**。
2. 実測の `k=4→32 で MRR 0.794→0.753 低下` は、reranker の既知の劣化パターン（Drowning in Documents, arXiv:2411.11767。**bge-reranker-v2-m3 が実際の被験モデル**）と整合。症状の一部は「取りこぼし」ではなく **reranker が候補増で壊れている**可能性がある。
3. 再embed不要で最も期待値が高いのは **「ページ展開 → 文単位再スコア」の coarse-to-fine 二段化**。page_coverage 0.946 が新しい上限になる。
4. **Late Chunking は当製品に適用できない**（bge-m3 は CLS プーリング。独立評価で BGE-M3 は nDCG@5 0.246→0.070 と崩壊）。

---

## 1. 症状の文献上の位置づけ

### 1-1. 「粒度ジレンマ」として明示的に研究されている

- **Dense X Retrieval: What Retrieval Granularity Should We Use?**（Chen et al., arXiv:2312.06648）— 検索単位（document / passage / sentence / proposition）の選択が性能を支配することを示した系統的研究。
- **Dense Retrievers Can Fail on Simple Queries: Revealing The Granularity Dilemma of Embeddings**（arXiv:2506.08592）が最も症状に近い。埋め込みは「細粒度の顕在性」と「全体意味への整合」を**同時には表現できない**という構造的ジレンマ。中国語 CapRetrieval（3,024 passage / 404 query）で検証。
  - BM25 66.54 / BGE-0.1B 78.86 / GTE-7B 86.55 nDCG@10。**モデル規模を上げても解けない**。
  - 提案解（キーワード寄りの学習データ追加）で 91.83 まで改善するが、**代償として広い意味理解を要するデータセットで劣化**。著者自身が「未解決」と明記。
  - → 当製品の「見出し的・抽象的な語は取れる／具体的事実文は取れない」と**症状が一致**。

### 1-2. 「具体的な数値・固有名詞」が dense で落ちるのは既知

- **Simple Entity-Centric Questions Challenge Dense Retrievers**（Sciavolino et al., EMNLP 2021, arXiv:2109.08535）
  - EntityQuestions で **DPR top-20 = 49.7% に対し BM25 = 72.0%**。"Where was [E] born?" では **BM25 が 49.9 ポイント上回る**。
  - 対策としてのデータ拡張は「個別リレーションは改善するが他ドメインで劣化」と**否定的結論**。
  - → 当製品は既に日本語 bi-gram BM25 + RRF を導入済みのため**部分的に実施済み**。それでも取れていないなら原因は別（1-3, 3-1）。

### 1-3. k を増やすと reranker が壊れる（実測 MRR 低下の説明になりうる）

- **Drowning in Documents: Consequences of Scaling Reranker Inference**（arXiv:2411.11767, ReNeuIR 2025 @ SIGIR）
  - **被験 reranker に bge-reranker-v2-m3 が含まれる**。データセット8種。
  - 小さい K では 85–89% のケースで reranker が有効。しかし **academic 実験の 53.3%、enterprise の 44.4% で「K をスケールさせると Recall@10 が retrieval 単独より悪化」**。
  - 最大 recall は K=100 付近で頭打ち。**最大 K が最適だったのは academic 3.3% / enterprise 14.8% のみ**。
  - "phantom hits"（クエリと重なりゼロの文書に高スコア）を失敗モードとして特定。
  - 緩和策: listwise LLM reranking、negative sampling の改善。
  - → 当製品の k=4→32 で MRR 0.794→0.753、nDCG は 0.823→0.845 と乖離する挙動はこれと定性的に整合。**まだ切り分けていない。**

---

## 2. 各手法の評価

### 2-1. Contextual Retrieval（Anthropic, 2024-09）

| 条件 | 数値 |
|---|---|
| 指標 | 1 − recall@20 |
| Contextual Embeddings のみ | 5.7% → 3.7%（−35%） |
| + Contextual BM25 | 5.7% → 2.9%（−49%） |
| + Reranking | 5.7% → 1.9%（−67%） |
| コスト | **$1.02 / 100万文書トークン**（prompt caching使用） |
| 検証ドメイン | codebases, fiction, ArXiv（**英語のみ**） |

- **再embed必須**。**日本語検証事例なし**。
- Anthropic の 35–67% は「失敗率の相対削減」であり、**絶対値では 1–3pt 程度**。
- 独立評価: T2-RAGBench で dense +2.8pp / hybrid +2.2pp（※二次情報、一次未確認）。
- **適合性**: 直すのは「チャンクが文書文脈を失っている」型（例: "その額は34万4,000円" の "その" が不明）。当製品の取りこぼし例は**まさにこの型に見える**。ただし「500字チャンク内に埋もれる」希釈問題は解けない。

### 2-2. Late Chunking（arXiv:2409.04701）— **非推奨**

v1 Table 2（jina-embeddings-v2-small, 256token, nDCG@10）:

| Dataset | Naive | Late |
|---|---|---|
| SciFact | 64.20% | 66.10% |
| TRECCOVID | 63.36% | 64.70% |
| FiQA2018 | 33.25% | 33.84% |
| NFCorpus | 23.46% | 29.98% |

v3集計: 文境界チャンクで **相対 +3.63%（絶対 +1.9pt）**。

**当製品への致命的な適用制約**:
- Late Chunking は「トークン埋め込みを出してからチャンク範囲で **mean pooling**」する手法。
- **bge-m3 の dense 表現は [CLS] の正規化ベクトル**（M3-Embedding 論文 arXiv:2402.03216 に `e_q = norm(H_q[0])` と明記、原文確認済み）。mean pooling ではない。
- 独立評価が裏付ける: **Reconstructing Context**（arXiv:2504.19754）Table 3 で **BGE-M3: early 0.246 nDCG@5 → late 0.070** と壊滅。Stella-V5 も MS Marco で 0.630 → 0.503。
- 同論文の結論「Late Chunking は全モデル・全データセットで一貫して Early を上回るわけではない」。

### 2-3. Proposition-level indexing（arXiv:2312.06648）— **推奨しない**

- 効果（Recall@5）: 教師なし retriever で SimCSE 34.3→46.3、Contriever 43.0→52.7。**教師あり retriever では +2〜4pt に留まる**。
- **long-tail クエリで最大**: EntityQuestions の希少エンティティで Recall@5 相対 +17〜25%。
- **論文自身の否定的結果**: マルチホップ質問では passage 単位より劣化。
- **独立評価での強い反証**: arXiv:2602.16974 で **proposition ベースは in-corpus 検索で paragraph 比 15〜40% 劣化**。
- 日本語での命題抽出品質の検証事例は**見つからなかった**。
- → 採用するなら「既存索引を残して命題索引を追加し RRF」の併用形限定。単独置換は危険。

### 2-4. Multi-vector retrieval（ColBERT / JaColBERT）

**重要事実: bge-m3 は既にマルチベクトル（ColBERT型）ヘッドを内蔵している。**
- M3-Embedding: `E_q = norm(W_mul^T · H_q)`、late interaction `s_mul = (1/N) Σ_i max_j E_q[i]·E_p[j]^T`
- MIRACL 日本語: **dense 72.8 → multi-vector 74.5 nDCG@10（+1.7pt）**
- MLDR（長文書）: multi-vector が dense 比 +5.1pt 超

JQaRA（1,667問、nDCG@10）:

| モデル | nDCG@10 |
|---|---|
| ruri-reranker-large（cross-encoder） | **0.7712** |
| japanese-bge-reranker-v2-m3-v1 | 0.6918 |
| **japanese-splade-base-v1（sparse）** | **0.6441** |
| JaColBERTv2.5（multi-vector） | 0.6420 |
| bge-m3 + colbert | 0.5656 |
| **bge-m3 + dense** | **0.5390** |
| bge-m3 + sparse | 0.5088 |

- bge-m3 の colbert モードは dense 比 **+2.7pt**。改善はするが**粒度ミスマッチが解けるほどの幅ではない**。
- **注目: japanese-splade-base-v1 (0.6441) が bge-m3+sparse (0.5088) を +13.5pt 上回る**。「具体的語句の取りこぼし」は sparse 側の弱さが効いている可能性。

### 2-5. Parent Document Retriever / Small-to-Big — **方向が逆**

- **公開された定量ベンチマークが見つからなかった**。実務ノウハウ止まりで一次研究の裏付けが薄い。
- **方向が症状と逆**: small-to-big は「小さく引いて大きく返す」= 生成側の文脈不足を直す手法。当製品の症状は「大きい単位（ページ）は当たっているのに小さい単位（文）が引けない」なので、必要なのは **big-to-small（coarse-to-fine）**。
- coarse-to-fine の裏付け:
  - **FEVER 系の二段構成**（document retrieval → sentence retrieval → verification）は2018年以来の標準アーキテクチャ。文単位の evidence recall を上げる目的で設計されている。
  - **FunnelRAG**（arXiv:2410.10293）が同じ粗→細を RAG に持ち込んでいる。

### 2-6. チャンクサイズ

**(a) 最適チャンクサイズはクエリ依存**（AI21 Labs）
- **単一チャンクサイズと oracle の recall@1 ギャップは 20–30%、最大 40% 超**。
- 実用近似 = **複数チャンクサイズで索引し RRF 融合**: MTEB +1〜3%、**TRECCOVID +36.7%**（E5-small）。
- **否定的側面**: 索引コストが **2〜5倍**。

**(b) semantic chunking は割に合わない**
- **Is Semantic Chunking Worth the Computational Cost?**（arXiv:2410.13070, NAACL 2025 Findings）: 3タスクで **fixed-size を一貫して上回らず、追加計算コストに見合わない**。
- LumberChunker は **1.11 docs/sec vs paragraph 1,854 docs/sec（1,668倍遅い）**。

**(c) 日本語での500文字の妥当性**
- 日本語専用のチャンクサイズ×再現率の**一次研究は見つからなかった**。
- bge-m3 は 8192 token なので上限は問題ない。**問題は上限ではなく希釈**。
- arXiv:2602.16974: チャンクサイズは in-document 検索性能と中程度の相関（r=0.41–0.57）、in-corpus とは弱い相関（r=0.08–0.18）。**当製品は単一文書内検索（in-document）に近く、チャンクサイズの影響が出やすい領域にいる。**

---

## 3. 指定されていないが優先度が高い論点

### 3-1. PDFパース品質が上限を決めている可能性（最優先の切り分け）

- **OCR Hinders RAG**（OHRBench, arXiv:2412.02592, ICCV 2025）
  - 7ドメイン（教科書・法律・金融・新聞・マニュアル・学術・**行政**）8,561ページ、8,498 QA。
  - 結論: **「現行の OCR ソリューションはどれも RAG 用の高品質ナレッジベース構築に十分ではない」**。
  - **table / formula / chart / reading order** が弱点として名指し。
- 当製品の対象は **544ページの段組みPDF**。取りこぼしアンカーは図表・注記・段組み境界に置かれやすい数値表現。
- **推測（明記）**: これらのアンカー文字列が、パース後のコーパスに**そもそも連続した文字列として存在していない**可能性がある。段組み reading order の乱れ、表セルの分断で分断されると、**どの検索手法を入れても anchor_coverage は上がらない**。
- **検証コストはほぼゼロ**（アンカー文字列を正規化後にgrepするだけ）で、**上限を決める要因**。最初にやるべき。

### 3-2. anchor_coverage の天井は「検索の失敗」か「rerankerの埋没」か未分離

- 切り分け: reranker を通す前の1段目（dense/BM25/RRF後）の anchor_coverage を k=32,64,128 で測る。
- **1段目 coverage >> 最終 coverage** なら問題は reranker、**1段目も 0.71 付近で飽和**なら問題は表現・粒度。
- **この1回の計測で以降の打ち手が半分に絞れる。**

### 3-3. クエリ側の非対称性

- **Doc2Query--: When Less is More**（arXiv:2301.03266, ECIR 2023）: 生成クエリには幻覚が多く、**フィルタで有効性 +16%、実行時間 −23%、索引 −33%**。文書側拡張には**フィルタ必須**。
- All-Hit 0.473（anchor_coverage 0.71 に対して低い）は**複数アンカーを要する質問で全部は揃わない**ことを示す。クエリ分解が定石だが**定量値の一次確認は未了**。

---

## 4. 主要数値一覧（調査日 2026-07-28）

| 内容 | 数値 | 出典 |
|---|---|---|
| Contextual Retrieval, embeddingsのみ | top-20失敗率 5.7%→3.7%（−35%） | anthropic.com |
| 同 + BM25 + reranking | 5.7%→1.9%（−67%） | 同上 |
| 同 コスト | $1.02 / 100万トークン | 同上 |
| Late Chunking 平均改善 | 相対 +2.70〜3.63%（絶対 +1.5〜1.9pt） | arXiv:2409.04701 |
| **Late Chunking, BGE-M3 で劣化** | NFCorpus nDCG@5 **0.246→0.070** | arXiv:2504.19754 |
| Proposition, 教師なし | SimCSE R@5 34.3→46.3 | arXiv:2312.06648 |
| Proposition, 教師あり | **+2〜4ptのみ** | 同上 |
| **Proposition, 独立評価** | in-corpus で **15〜40% 劣化** | arXiv:2602.16974 |
| DPR vs BM25（エンティティ質問） | 49.7% vs 72.0%、最大49.9pt差 | arXiv:2109.08535 |
| 粒度ジレンマ | BM25 66.54 / BGE-0.1B 78.86 / GTE-7B 86.55 | arXiv:2506.08592 |
| **rerankerのKスケール劣化** | academic 53.3% / enterprise 44.4% で retrieval単独以下 | arXiv:2411.11767 |
| bge-m3 MIRACL-ja | dense 72.8 → multi-vector 74.5 | arXiv:2402.03216 |
| JQaRA（抜粋） | ruri-reranker-large 0.7712 / japanese-splade 0.6441 / bge-m3+dense 0.539 | JQaRA |
| JaColBERTv2.5 | 平均 0.754（従来最良 0.720）、110M param | arXiv:2407.20750 |
| マルチスケール索引+RRF | MTEB +1〜3%、TRECCOVID +36.7%、**索引2〜5倍** | ai21.com |
| クエリ依存の最適チャンク | recall@1 ギャップ 20〜30%、最大40%超 | 同上 |
| semantic chunking | fixed-size を一貫して上回らず | arXiv:2410.13070 |
| OCRのRAGへの影響 | 現行OCRはどれも不十分、table/reading order が弱点 | arXiv:2412.02592 |
| Doc2Query-- | 有効性+16%、実行時間−23%、索引−33% | arXiv:2301.03266 |

**信頼度の注記**
- 一次確認済み: Anthropicブログ、arXiv:2409.04701 / 2312.06648 / 2402.03216 / 2411.11767 / 2504.19754 / 2602.16974 / 2506.08592 / 2109.08535 / 2301.03266、JQaRA README、AI21ブログ。
- **二次情報（一次未確認）**: bge-reranker-v2-m3 の JQaRA 0.673、T2-RAGBench での Contextual Retrieval +2.8pp、arXiv:2410.13070 / 2401.18059 / 2406.00456 / 2410.10293 の詳細数値。
- **推測と明記するもの**: (a) 取りこぼしアンカーがパース段階で分断されている可能性、(b) bge-m3 の CLS プーリングが arXiv:2504.19754 の BGE-M3 崩壊の原因である、という因果推定。(b) は「bge-m3 dense = norm(H[0])」という一次事実に基づく強い推論だが、著者がそう述べているわけではない。

---

## 5. 不明点・要追加調査

1. **日本語での粒度ミスマッチの一次研究がほぼ無い**（CapRetrievalは中国語、Dense X/EntityQuestionsは英語）。
2. **「正解ページは取れるが正解文が取れない」を metric として明示的に分離した研究**は見つからなかった。FEVER の evidence recall が最も近い。**この指標対自体が当製品の差別化材料になりうる。**
3. HyDE / query2doc / クエリ分解の一次定量値（検索予算切れで未取得）。
4. Parent Document Retriever の再現可能な定量ベンチマーク（**存在しない可能性が高い**）。
5. 日本語チャンクサイズと再現率の関係を実測した査読付き研究（**見つからなかった**）。
6. 官公庁段組みPDFに対する日本語パーサ比較（PyMuPDF / Docling / Unstructured / MinerU）の実測比較。

---

## 6. 適用優先順位（費用 × 期待効果）

> **原則: anchor_coverage 0.71 という天井が「検索の問題」か「パース or reranker の問題」かが未分離。ここを分けずに手法を投入すると、効かない手法に再embedコストを払うリスクが高い。P0を先にやること。**

| 順位 | 施策 | 再embed | 実装量 | 期待効果 | 根拠 |
|---|---|---|---|---|---|
| **P0-a** | 取りこぼしアンカー文字列がパース済みコーパスに**存在するかgrep検証** | 不要 | 極小（半日） | **上限の判明**。不在分は全手法で回収不能→パース改善が最優先に格上げ | OHRBench |
| **P0-b** | **reranker前（1段目）のanchor_coverage**をk=32/64/128で測定 | 不要 | 極小（半日） | 「検索の失敗」か「rerankerの埋没」かを分離 | Drowning in Documents |
| **P1** | **coarse-to-fine二段化**: 取得ページを全文展開し、ページ内全文をrerankerで再スコア | **不要** | 中 | **理論上限が page_coverage 0.946 に**。現行0.71からの伸び代が最大 | FEVER型二段構成、FunnelRAG |
| **P2** | マルチスケール索引（500字+100〜150字）を追加しRRF融合 | 追加分のみ | 中 | MTEB +1〜3%、TRECCOVID +36.7%。**索引2〜5倍** | AI21 |
| **P3** | bge-m3のmulti-vectorヘッドで候補のみlate-interaction再スコア | 不要 | 小〜中 | **新モデル不要**。ただし上積みは +1.7〜2.7pt程度で**小さい** | arXiv:2402.03216、JQaRA |
| **P4** | 日本語SPLADEをbi-gram BM25に追加/置換 | sparse索引再構築 | 中 | JQaRAで **+13.5pt**。「具体的語句が取れない」症状に筋が良い | JQaRA |
| **P5** | Contextual Retrieval | **全文再embed必須** | 中〜大 | 失敗率−35〜67%（**絶対1〜3pt相当**）。**日本語検証事例なし** | anthropic.com |
| **P6** | クエリ分解 | 不要 | 小〜中 | **All-Hit 0.473 の改善**に直結しうる。**定量的裏付けを一次確認できていない** | Dense X |
| **P7** | JaColBERTv2.5への1段目乗り換え | 全文再インデックス | 大 | 日本語単体SOTA。ただしcross-encoder(0.77)には及ばず | arXiv:2407.20750 |
| **P8（推奨しない）** | Proposition-level indexing | 全文再embed+LLM | 大 | **独立評価でin-corpus 15〜40%劣化**という強い反証 | 2312.06648 vs 2602.16974 |
| **P9（非推奨）** | Late Chunking | 実質モデル差し替え | 大 | **bge-m3はCLSプーリングのため適用不可**。BGE-M3で0.246→0.070 | 2402.03216、2504.19754 |
| **P10（対象外）** | semantic chunking | 再embed必要 | 大 | NAACL2025で「コストに見合わない」と否定 | 2410.13070 |

### 実行推奨シーケンス

1. **P0-a と P0-b**（合計1日以内、再embedゼロ）。**この2つの結果次第でP1以降の優先順位が変わる**ため必ず先に。
2. **「パース欠損が主因」なら**: PDFパーサ比較（Docling / MinerU / PyMuPDF）に投資。検索アルゴリズムへの投資は後回し。
3. **「1段目では取れているがrerankerが沈めている」なら**: P1が最短ルート。再embedゼロで天井を0.946まで引き上げられる。
4. **「1段目でも0.71で飽和」なら**: P2 + P4 が本命。P5はその後。

### この調査で最も重要な発見

1. **Late Chunking は当製品にそのまま適用できない**。bge-m3 の dense が CLS プーリングという一次事実と、独立評価での BGE-M3 崩壊（0.246→0.070）が一致する。**工数を投じる前に止められたのが最大の実利。**
2. **k を増やすと reranker が壊れるのは既知現象**で、被験モデルに bge-reranker-v2-m3 が含まれる。実測の MRR 低下はこれで説明できる可能性があり、**まだ切り分けていない**。
3. **粒度ジレンマは学界でも未解決**。「単一の手法で anchor_coverage が 0.71 → 0.9 に跳ぶ」という期待は持つべきでない。**現実的な打ち手は、page_coverage 0.946 という既に取れている資産を二段構成で刈り取ること**（P1）。
