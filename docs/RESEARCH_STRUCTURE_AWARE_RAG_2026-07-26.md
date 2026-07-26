# 調査結果: 文書構造を考慮したRAGと評価設計

調査日: 2026-07-26 / 担当: Claude Code（調査担当）
対象: OTE-RAG（AnythingLLM fork, gemma4:12b + bge-m3 + BM25ハイブリッド + bge-reranker-v2-m3, LanceDB, Recursive 1000字フラット）

## サマリー
1. 2026年の実証は「LLMを使う高度なチャンキングはコスト対効果が悪い」側と「構造がある文書では効く」側で割れており、決定要因は**対象文書に階層構造があるか**。士業文書（条文・章節）は後者に該当する可能性が高い。
2. 「目次を教えて」型は top-k では原理的に解けず、recall を上げると逆に悪化する実証がある。定石は**クエリルーティング＋事前構築した構造インデックス**で、LLM呼び出しゼロで実装できる。
3. 最大のボトルネックは手法ではなく評価。現行30問では95%信頼区間が±17ポイントあり、17ポイント改善すら有意と言えない。

## 0. OTE-RAG固有の制約（採否を決定づける）

| 制約 | 内容 | 帰結 |
|---|---|---|
| Ollama embedding | `/api/embed` は入力あたりプールされた1ベクトルのみ返す。トークン単位出力のエンドポイントは存在しない | **late chunking / bge-m3 sparse・ColBERT は現行アーキでは不可**。bge-m3をONNX/transformersで自前推論すれば全て同時に解禁される |
| ローカル12B×1GPU | インデックス時LLM呼び出しは全てユーザーGPUを占有。プロンプトキャッシュ課金の恩恵なし | GraphRAG系（数千回呼び出し）は不可 |
| 非中国系LLM方針 | 2026-07-14決定 | HiChunk（Qwen3-4Bベース）等はそのまま採用不可 |
| 完全オフライン | web検索不可 | CRAGの中核（低信頼時web検索）は不可 |

---

## 1. 手法別要約表（効果量／インデックスコスト／オフライン可否）

| 手法 | 報告された効果量（データセット・指標） | インデックス時LLM呼び出し | gemma4:12b・完全オフラインで現実的か |
|---|---|---|---|
| **Late chunking** (arXiv:2409.04701, SIGIR2025) | nDCG@10: NFCorpus 23.46→29.98(+6.52)、SciFact 64.20→66.10、TRECCOVID 63.36→64.70、FiQA 33.25→33.84、Quora 87.19→87.19(±0)。3モデル×4DS平均で相対+3.63%(絶対+1.9pt) | **0回**（embedding計算のみ） | **現行不可**。Ollama経由でトークン単位ベクトルが取れない。embedding自前推論に移行すれば可（同時にsparse/ColBERTも解禁） |
| **Contextual Retrieval** (Anthropic 2024, **ベンダー主張・査読なし**) | top-20検索失敗率 5.7%→2.9%（−49%）、reranker併用で1.9%（−67%）。自社9ドメイン評価 | **チャンク数ぶん（600チャンク文書なら600回）** | 原法（各チャンクに文書全体を渡す）は12Bのctxに入らず不可。**節コンテキストに縮退すれば可**。索引時間は筆者概算で40〜60分/546ページ（**実測必要**） |
| **Parent-Document / Auto-Merging** (LlamaIndex; HiChunk論文のAM部分) | LlamaIndex公式デモ: GPT-4がtop-kより65%選好（**統制実験でない**）。HiChunk論文のAuto-Merge込みで evidence recall +7〜8pt | **0回** | **完全に可能**。LanceDBに`parentId`/`sectionPath`を追加し検索後展開するだけ |
| **HiChunk（階層チャンキング）** (arXiv:2509.11552) | 分割点F1(Lv1): Qasper HC 0.6742 vs LumberChunker 0.5481 vs Semantic 0.0759 / GovReport HC 0.9505 vs LC 0.1795。HiCBench T₁ evidence recall 74.06→81.03、fact coverage 63.20→68.12。T₂ 72.95→80.65 / 60.87→66.36 | 4Bモデル1通し。**Qasper 1.50s/doc、GutenQA 60.19s/doc**（LumberChunkerは132.49s） | 技術的には可だが**ベースがQwen3-4B**で方針衝突。配布+2.5GB。**日本語公文書なら正規表現＋PDFしおりでルールベース代替が有望** |
| **RAPTOR** (ICLR2024) | **QuALITY 絶対精度+20%**（GPT-4併用）。NarrativeQA/QASPERでもSOTA | **元チャンク数の30〜50%（600チャンクなら200〜300回の要約生成）** | 縮退版（節単位1層要約）なら可。筆者概算で25分/文書。**12Bの日本語要約品質が上位ノード品質を直接決めるためリスク** |
| **GraphRAG** (arXiv:2404.16130) | naive RAG比で comprehensiveness / diversity 大幅改善（**指標はLLM-as-judgeのwin-rateで正答率ではない**） | **教科書1冊で約4,000回・35分**（Microsoft公式）。DeepSeek-R1 70Bで297万入力トークン・5.2時間の報告 | **不可** |
| **LightRAG** (arXiv:2410.05779, EMNLP2025) | **著者主張**: 検索時 GraphRAG 61万トークン・数百API呼び出し → LightRAG <100トークン・1回。増分更新も差分のみ | 検索は軽いが**グラフ構築時のエンティティ・関係抽出コストはGraphRAG同等** | 実質不可（索引コストが本質） |
| **Document Summary Index** (LlamaIndex / Ragie) | 「top-k結果が単一・少数文書に偏る」問題への対処。Ragieは`top_k/max_chunks_per_document`件の文書を先に選ぶ2段構成 | 文書数ぶん（数十回） | **可能**。文書単位なので呼び出し回数が桁違いに少ない |
| **MultiDocFusion** (EMNLP2025) | **検索精度+8〜15%、ANLS QA+2〜3%**（長い産業文書） | VLM+OCR+LLM節階層再構築 | VLM必須でオフライン配布は重い。C |
| **MoC (Mixture of Chunkers)** (ACL2025) | Meta-chunker-1.5B: CRUD(single-hop) BLEU-1 **0.3754** vs LumberChunker(Qwen2.5-14B) 0.3456 | 1.5Bモデル1通し | 中国系モデル。C |
| **BookRAG** (arXiv:2512.03413) | 「retrieval recall / QA accuracy でSOTA」（**具体数値は本調査で抽出できず要精読**） | 未確認 | 概念（階層ツリー＝目次インデックス＋エンティティグラフ＋クエリ分類エージェント）がOTE-RAGの課題に直撃。**ツリー部分の部分採用が有望** |
| **STC（表の構造考慮チャンキング）** (arXiv:2605.00318) | 行単位Row Tree、構造境界に沿ったトークン制約分割。数値未確認 | 0回 | 可能。白書の統計表に直結 |

### 反証（必ず併記すべき）
- **arXiv:2606.00881**（2026-06、8手法×10データセット）: 証拠検索 Accuracy@5 は **Recursive Semantic 89.36% vs Fixed-size 87.71%（差1.65pt）**。計算コストは **Fixed-size <1秒 / LumberChunker 平均8.37時間 / DenseX 平均15時間**（後2者は48時間上限を頻繁に超過し完走せず）。結論: "more computationally expensive chunking methods do not yield meaningful effectiveness improvements"。
- 逆に **arXiv:2602.16974**（2026-02）は structure-aware/semantic が fixed-size を有意に上回り、**明確な階層構造を持つ文書で一貫した利得**があると結論。**数値表は未抽出（要精読）**。
- 両者の食い違いは対象文書の構造の有無で説明できる可能性が高い（筆者の仮説）。2606.00881の主対象は小説・オープンドメインQA、OTE-RAGの対象は白書・規程集。

---

## 2. 集約型クエリ（目次・構成・全体要約）の定石

### 原理的に解けない根拠
- GraphRAG論文の問題設定そのもの: "RAG fails on global questions directed at an entire text corpus"。「主要テーマは何か」は特定チャンクに答えが書かれていないため類似度検索が定義上機能しない。
- **arXiv:2602.01355**（2026-02, Aggregation Queries benchmark）: 「**top-kを単に大きくしても集約タスクは解決しない。チャンクレベルrecallは向上するが集約精度はほとんど改善せず、ノイズ蓄積でむしろ悪化する場合がある**」。
- LlamaIndexの指摘: データセットが大きくなるほど top-k が単一・少数文書に偏る構造的バイアス。

### 標準的な4アプローチ
| # | アプローチ | 概要 | OTE-RAGでのコスト |
|---|---|---|---|
| A | **クエリルーティング（local/global）** | GraphRAGのlocal search / global searchが原型。global判定時はベクトル検索をバイパス | LLM 0〜1回。日本語は「目次/構成/全体/概要/まとめ/何章/どんな内容」等の正規表現でかなり取れる |
| B | **構造インデックス／文書サマリインデックス** | 文書ごとに目次テキストor要約を1レコード生成し、そちらを引く | 目次抽出はLLM不要（PDFしおり・フォントサイズ・`第[一二三四五六七八九十０-９0-9]+[部章節条]`） |
| C | **階層要約 / map-reduce** | RAPTOR上位ノード、GraphRAGコミュニティ要約。「全体の要約」を事前生成 | 節数ぶんのLLM呼び出し（1層に限れば数十回） |
| D | **エージェント型集約** | 反復検索・中間結果検証・追加検索（arXiv:2602.01355）。top-kベースラインを大幅に上回る | レイテンシと非決定性の代償が大きい |

### 推奨: 「目次質問は検索問題ではなくメタデータ問題として扱う」
1. 取り込み時に見出し階層を抽出し `documents.outline` として保存
2. クエリ分類がglobal判定→ベクトル検索の代わりに `outline`＋文書メタデータを注入
3. 「第3章を要約して」は類似度でなく `sectionPath LIKE '第3章%'` の**列挙的フィルタ検索**→map-reduce要約

→ **LLMインデックス呼び出し0回、オフライン完結、2〜5人日**で、現在0点のカテゴリが丸ごと立ち上がる。改善ではなく新規解決なので期待効果は最大。

---

## 3. マルチホップ・複雑質問

| 手法 | 報告効果 | オフライン・12Bでの可否 |
|---|---|---|
| **Query decomposition / Multi-query** | ケース依存 | **可能**。LLM1回でサブ質問生成→各々検索→マージ。既存rerankerでノイズ抑制 |
| **IRCoT** (ACL2023, arXiv:2212.10509) | GPT-3で**検索最大+21pt、下流QA最大+15pt**（HotpotQA/2Wiki/MuSiQue/IIRC）。固定予算下で+11〜21 recallポイント | 可能だが1質問あたりLLM 3〜5回＋検索3〜5回で**応答が数十秒〜分**。士業UXとして厳しい |
| **Self-RAG** (ICLR2024) | Self-RAG 7B/13BがLlama2・標準RAGを大幅に上回る | **不可**（reflection tokenのファインチューニング必須） |
| **CRAG** | retrieval evaluatorで採点、低信頼ならweb検索 | **中核は不可**。ただし「**既存bge-rerankerのスコアを閾値判定に使い、低信頼なら『文書に記載がありません』と返す**」縮退版は追加モデル不要で極めて安価 |
| **Adaptive-RAG** (NAACL2024) | 小型分類器で「検索不要/1段/多段」を振り分け | **可能**。日本語はルールベース＋LLM分類で代替。無駄な多段を避けレイテンシを守る |
| **Agentic RAG** (survey arXiv:2501.09136) | reflection/planning/tool use/multi-agentの分類学 | 部分的に可能。安定性・レイテンシ・デバッグ困難性がリスク |

### 2025〜2026年の動向
- 静的パイプライン→**推論駆動アーキテクチャ**への明確なシフト。「いつ・何を・どう検索するか」をモデルの推論軌跡で決める（arXiv:2506.10408, ACL Findings 2025）。同論文は **predefined reasoning（規則駆動）** と **agentic reasoning（自律判断）** に二分。**OTE-RAGは動作が決定的で検証可能な predefined 側を選ぶべき**。
- **arXiv:2606.21553**（2026-06, "Dissecting Agentic RAG: A Component Ablation for Multi-Hop QA with a Local 7B Model"）: ローカル7BでもHotpotQAでagentic意思決定の恩恵が実質的にあり、特にroutingの寄与が大きい。「大型モデルのみがオーケストレーションを必要とする」という前提への反証。**数値表は本調査で未抽出**。
- 新しい失敗モードも同定: **arXiv:2512.10787**（Context Dilution in Multi-Hop RAG）— 反復検索でコンテキストが希釈され逆に精度が落ちる。
- 設計フレーム: arXiv:2601.00536（Four-Axis Design Framework）。

### 推奨: predefinedな2段構成に留める
クエリ分類（単純/マルチホップ/集約）→ マルチホップ時のみ**深さ1固定・サブ質問2〜3個**に分解 → 既存ハイブリッド検索＋reranker → スコア閾値未満なら「記載なし」。応答時間の悪化を2〜3倍に抑えつつ、マルチホップカテゴリを立ち上げられる。

---

## 4. 日本語特有の論点

### ⚠ YomiToku のライセンス問題（最重要・要対応）
日本語特化AI OCR「YomiToku」は段落構造・見出し・表を解析しHTML/JSON/Markdown/CSVで構造保持出力でき、約7,000字種・縦書き対応、オンプレ動作可。**しかし本体のライセンスは CC BY-NC-SA 4.0（非商用）**。商用利用にはMLism社の商用ライセンス（YomiToku-Pro）が必要。**OTE-RAGは顧客配布製品であるため無償版の同梱は不可**。`docs/COMMERCIAL_LICENSE_MEMO.md` への追記を推奨。

### 構造解析の現実解
日本語の公文書・規程集は `第[一二三四五六七八九十０-９0-9]+[部章節条]`、`（1）`、`①` 等の**表層マーカーが極めて規則的**で、PDFのしおり・フォントサイズ・インデントも併用できる。**ルールベースの費用対効果がLLM/VLM系より圧倒的に高い**。マルチモーダル（PDF→画像→VLM→Markdown）で改善したという国内事例はあるが、いずれも自社ブログで統制実験ではない。

### 条文単位チャンキング（士業ドメイン直結）
- 「契約書・法務文書は正確性要求が極めて高く、チャンキングは条文単位の分割が有効」
- 「固定長では**規程文書の条文と例外条件が分断される**。検索対象の知識単位そのものが壊れ、回答が不安定になる」
- 「条項単位のチャンク化と版管理が不可欠。有効期間・改訂版番号・所管部署をメタデータ付与」
- **含意: 主対象が規程・法令・通達なら「条文＝チャンクの自然な単位」であり、1000字固定分割は明確なミスマッチ**。
- 数値主張（**いずれも自社ブログ由来、標本30問規模、第三者検証不能**）: 社内規程RAGで正解率73.3%→100%（最良はチャンク3000字/overlap900字）、検索精度62%→79%（ハイブリッド）→91%（リランキング）。

### 日本語トークナイズ
BM25側はTantivy既定がCJK非対応でN-gram設定必須（社内実装済）。SudachiPyのA単位/C単位の使い分けが議論されている。**2026年の国内推奨デフォルトは Recursive 400〜512トークン + 10〜20% overlap で Recall 82〜90%**（個人ブログ由来、一次ベンチ未確認）。**OTE-RAGの1000字（≒500〜700トークン）はこの推奨よりやや大きい**。

### 国内の研究・発表
| 出典 | 内容 |
|---|---|
| 石井愛・井之上直也・鈴木久美・関根聡「構造化知識RAG・文書ベースRAGを段階的に利用したマルチホップQAに対するLLMの精度向上」**NLP2025 Q7-1** | 構造化知識ベース→文書RAG→LLMの**段階的利用**。OTE-RAGのルーティング設計の直接の参考。**数値は要精読** |
| 亀井遼平・坂田将樹ら「**JHARS**: RAG設定における日本語Hallucination評価ベンチマークの構築と分析」**NLP2025 Q2-17** | 日本語RAGのハルシネーション評価。「出典必須・文書外は不明」方針の効果測定に直結 |
| **NLP2026**（第32回、2026-03 宇都宮）参加報告 | GraphRAGの各モジュール設計がQA性能に与える影響の分析があり、**知識グラフを中程度の粒度でコミュニティ分割すると検索性能・多段推論が改善**と報告 |
| **SB Intuitions「Sarashina3 rerank」**（2026-07-03） | 日本語**指示付きリランキング**。現行bge-reranker-v2-m3（BAAI＝中国系）の代替候補。**ライセンス・サイズ・ONNX化可否は未確認、要追加調査** |
| **J-RAGBench**（NEOAI） | §5参照 |

---

## 5. ベンチマーク

| ベンチマーク | 問題数・規模 | 何を測るか | オフラインで回せるか |
|---|---|---|---|
| **JQaRA** | 質問ごとに候補100件（1件以上正解） | 検索精度。主要指標 **nDCG@10** | **可能**。社内でベースライン取得済（`JQARA_RETRIEVAL_BASELINE_2026-07-16.md`） |
| **JaCWIR** | 5,000問＋約50万Webページ（タイトル・冒頭文） | Web記事検索・リランキング。作者自身が「きちんと構築されたものではなくカジュアルなデータセット」と明言 | 可能。ただし**短文タイトル検索で長文構造理解は測れない**。OTE-RAGの課題とはズレる |
| **JEMHopQA** (LREC-COLING2024) | 日本語Wikipedia由来 | **日本語説明可能マルチホップQA**。回答＋**derivation（導出ステップ・エンティティ関係の半構造化表現）**を出力させるため「どこで間違えたか」が分かる | **可能。マルチホップ評価の中核にすべき** |
| **llm-jp-longbench (JEMHop)** | 最大**65,536トークン**入力 | JEMHopQAにWikipedia記事を付与した**長文脈QA** | 可能（vLLM部分は自前実装に差し替え） |
| **J-RAGBench** (neoai-inc/Japanese-RAG-Generator-Benchmark) | **114問・5カテゴリ**（情報統合／推論／論理条件の解釈／表形式の解釈／回答拒否）・15モデル評価済 | **日本企業のRAG実務を想定したGenerator評価**。GPT-5総合0.872が最高。**オープンモデルは「マルチホップ推論で回答拒否する傾向」「表形式解釈の弱さ」「セル結合対応不足」** | **可能。検索基盤の改修なしに即実行できる** |
| **JHARS** (NLP2025) | 未確認 | 日本語RAGハルシネーション | **公開状況が未確認** |
| **ELYZA-tasks-100** | 100問・5点満点・採点基準付き | 汎用日本語指示追従。**RAGベンチではない**。judge LLMが「不自然な日本語は減点」指示を反映していない限界の指摘あり（PFN） | 可能。サニティチェック用 |
| **MultiHop-RAG** (arXiv:2401.15391) | — | RAG設定に特化したマルチホップ | 英語 |
| **FanOutQA** (ACL2024 short) | — | **fan-out型（エンティティ列挙→各々について集約）**。「必要文書の合計長がコンテキスト長を超えモデルが元の質問を忘れる」失敗を観測 | 英語。**問題設計の型はOTE-RAGの集約クエリ課題に最も近く流用価値が高い** |
| **HotpotQA / 2WikiMultiHopQA / MuSiQue** | — | 2ホップ／構造化多ホップ／ショートカット耐性 | 英語 |
| **HiCBench / GovReport / QuALITY** | — | **証拠密（evidence-dense）**な問題でチャンキング品質を測る。GovReportは政府報告書＝白書に最も近い | 英語 |

### 現行評価の問題（定量）
- **30問で正答20問（66.7%）のとき、Wilson score 95%信頼区間は約[48.1%, 81.4%]、幅33ポイント（±約17pt）**（筆者計算）。**「62%→79%」の17ポイント改善ですら有意と言えない**。100問でも±約9pt。
- 文献推奨は250 QAペアで95%CI幅±0.04程度、n=50でWilson幅5〜15pt（arXiv:2605.02520）。
- **HiChunk論文が指摘する evidence sparsity 問題**（1〜2文で答えが出る問題ばかりだとチャンキング戦略の差が現れない）に、現行30問が完全に該当している。

### 推奨する評価設計
```
レイヤ1（LLM非依存・決定的・高速）
  JQaRA nDCG@10 + 自作「正解チャンクID付き」問題100問以上 → Recall@k / MRR / nDCG@10
  問題種別タグ: ①単一事実 ②マルチホップ ③構造理解 ④集約 ⑤回答拒否 → 種別ごとに集計
レイヤ2（judge必要）
  J-RAGBench 114問（Generator単体・検索なし）← 即実行可能
  JEMHopQA / llm-jp-longbench-JEMHop（マルチホップ・長文脈）
  自作問題に RAGAS faithfulness / answer relevancy
レイヤ3（統計）
  改修前後は必ず同一問題セットの paired design
  McNemar検定 + ペアードブートストラップ（10,000リサンプル）で95%CI
  「N問中M問正解」の生スコアだけを報告しない
```
**LLM-as-judgeの注意**: CoTで人間相関 Spearman ρ 0.51→0.66、Prometheus 13Bはカスタム採点基準でPearson 0.897（GPT-4級）→ **13Bクラスでもjudgeとして機能しうる**。ただし arXiv:2606.19544 が一貫性・バイアスの体系的問題を報告しており「安定」と「正しい」は別。**回答生成も採点もgemma4:12bだと自己評価バイアスの危険があるため、judgeは別モデルにすべき**。RAGASは Instance-Specific Rubrics（問題ごとの採点基準）を推奨。

---

## 6. OTE-RAGへの適用推奨度（ROIベースで再評価）

実装人日は筆者見積もり（1人日＝集中8時間）。**期限制約は考慮せず、人日あたりの品質改善で評価**。

| # | 手法 | 人日 | 期待効果 | オフライン可否 | 推奨度 |
|---|---|---|---|---|---|
| 1 | **評価基盤の再構築**（種別タグ付き100問+paired検定+J-RAGBench 114問） | 4〜6 | ★★★ 改善の可否を初めて判定できる。これ無しでは他の全項目が博打 | 可 | **A+** |
| 2 | **目次インデックス＋クエリルーティング** | 2〜5 | ★★★ 現在0点のカテゴリが立ち上がる。「改善」でなく「新規解決」 | 可（LLM 0〜1回） | **A+** |
| 3 | **条文/見出し境界を尊重した構造分割**（正規表現＋PDFしおり） | 2〜4 | ★★★ 士業では知識単位＝条文。1000字固定は明確なミスマッチ | 可（LLM不要） | **A** |
| 4 | **Parent-Document / Auto-Merge**（子300字検索→親/節展開） | 3〜5 | ★★ evidence recall +7〜8pt相当。既存rerankerと相性良 | 可（LLM不要） | **A** |
| 5 | **階層メタデータ付与**（`sectionPath`をchunkHeaderとBM25対象に） | 1〜3 | ★★ 年度・章の取り違え減。既存`chunkHeader`機構の拡張 | 可（LLM不要） | **A** |
| 6 | **CRAG縮退版**（rerankerスコア閾値で「記載なし」） | 1〜2 | ★★ 誤答をハルシネーションでなく「不明」に。士業では正答率向上より価値が高い場合あり | 可 | **A** |
| 7 | **チャンクサイズ/overlap再チューニング**（→400〜512トークン, overlap 10〜20%） | 1＋再index | ★★ 国内外推奨域から現行は外れている。#3と同時設計 | 可 | **A−** |
| 8 | **Contextual Retrieval（節コンテキスト縮退版）** | 5〜8 | ★★★ 原法で失敗率−49%（ベンダー主張）。効果量は本調査中で最大級。**縮退版の効果は要ローカル検証** | 可。索引40〜60分/文書（概算）のUXコスト | **A−** |
| 9 | **Query decomposition（深さ1固定）＋Adaptive-RAG型ルーティング** | 5〜8 | ★★★ マルチホップカテゴリが立ち上がる。ルーティングで単純質問のレイテンシを守る | 可。応答2〜3倍 | **B+** |
| 10 | **表の構造対応チャンキング（STC的な行単位化）** | 5〜8 | ★★ J-RAGBenchでオープンモデルの表解釈弱点が実証済。白書の統計表に直結 | 可（collector改修） | **B+** |
| 11 | **embedding自前推論への移行（ONNX/transformers）＋late chunking** | 8〜15 | ★★ late chunking単体は+1.9pt平均だが、**同時にbge-m3のsparse/ColBERTも解禁**され将来の打ち手が広がる。アーキ投資としてのROIは高い | 移行後は可。全再index必須 | **B+** |
| 12 | **節単位1層要約インデックス（RAPTOR縮退版）** | 4〜6 | ★★ 集約クエリ用。ただし#2で大部分カバーできるため限界効用は低い | 可（LLM=節数回） | **B** |
| 13 | **HiChunk相当の階層チャンカー（自前・非Qwen）** | 8〜12 | ★★ evidence recall +7〜8pt。ただし#3のルールベースで大半を再現できる見込み | 可 | **B−** |
| 14 | **RAPTOR フル** | 8〜12 | ★★ QuALITY +20pt（GPT-4での結果）。12Bの日本語要約品質がリスク | 索引25分〜/文書（概算） | **C** |
| 15 | **IRCoT** | 5〜8 | ★★★ 検索+11〜21pt、QA+15pt（GPT-3）。効果は大きいが**応答が数十秒〜分で士業UXとして不成立** | 可だが実用外 | **C** |
| 16 | **GraphRAG** | 15〜25 | ★★ global sensemakingで優位 | **不可**（教科書1冊で4,000呼び出し） | **C** |
| 17 | **LightRAG** | 12〜20 | ★★ | 検索は軽いがグラフ構築コストが本質。実質不可 | **C** |
| 18 | **Self-RAG** | — | ★★ | **不可**（要ファインチューニング） | **C** |
| 19 | **フルAgentic RAG** | 15〜25 | ★★ ローカル7Bでも効果ありとの報告（arXiv:2606.21553） | 可だがレイテンシ・非決定性・デバッグ困難性で製品リスク | **C** |

### 着手順序（ROI順）
- **第1波（9〜17人日）**: #1 評価基盤 → #6 CRAG縮退版 → #5 階層メタデータ → #2 目次インデックス＋ルーティング
  - #1がないと以降の効果を判定できない。#2は「改善」でなく「新規解決」なのでROIが突出。
- **第2波（6〜10人日）**: #3 条文境界分割 → #4 Parent/Auto-Merge → #7 チャンク再調整（#3と同時設計）
- **第3波（10〜16人日、第1波の評価結果で取捨）**: #8 Contextual Retrieval縮退版 → #9 分解＋ルーティング → #10 表対応
- **アーキ投資（8〜15人日、独立に判断可）**: #11 embedding自前推論。late chunking単体でなく sparse/ColBERT 解禁とセットで評価すべき。

---

## 不明点・要追加調査
1. **BookRAG（arXiv:2512.03413）の具体的数値**とTOC抽出にLLMが要るか。OTE-RAGの方向性に最も近く精読必須。
2. **HiChunkの数値の再確認**（arXiv HTML v3からの自動抽出のため表の読み違いの可能性）。
3. **arXiv:2602.16974 の実測数値**。arXiv:2606.00881と結論が食い違うため、両方の実験設定を精読して適用条件を切り分ける必要がある。
4. **NLP2025 Q7-1（石井ら）の具体的手法と数値**。
5. **JHARSの公開状況**。
6. **Sarashina3 rerank のライセンス・サイズ・ONNX化可否**（bge-reranker-v2-m3の非中国系代替になりうるか）。
7. **gemma4:12b の実測スループット**（RTX 5070 Ti相当、Q4、prefill/generation）。本レポートのインデックス時間概算は全てここに依存し、#8/#12/#14の可否判断ができない。
8. **gemma4:12b の日本語要約品質**（#8/#12の前提）。
9. **Contextual Retrieval のローカルモデルによる独立再現実験**が英語・日本語とも発見できず、Anthropicの自社主張以外の裏付けがない。
10. **日本語での構造考慮チャンキングの統制実験が存在しない**。国内事例は全て自社ブログ由来の30問規模で、OTE-RAGの現行評価と同じ統計的問題を抱えている。→ **OTE-RAGが信頼できる日本語構造理解ベンチを持てば、それ自体が差別化資産になりうる**。

---

## 参考文献

- [arXiv:2409.04701 Late Chunking](https://arxiv.org/abs/2409.04701)
- [arXiv:2509.11552 HiChunk](https://arxiv.org/abs/2509.11552)
- [arXiv:2404.16130 GraphRAG](https://arxiv.org/abs/2404.16130)
- [arXiv:2410.05779 LightRAG](https://arxiv.org/abs/2410.05779)
- [arXiv:2212.10509 IRCoT](https://arxiv.org/abs/2212.10509)
- [arXiv:2501.09136 Agentic RAG Survey](https://arxiv.org/abs/2501.09136)
- [arXiv:2506.10408 Reasoning-driven RAG (ACL Findings 2025)](https://arxiv.org/abs/2506.10408)
- [arXiv:2601.00536 Retrieval–Reasoning Four-Axis Framework](https://arxiv.org/pdf/2601.00536)
- [arXiv:2401.15391 MultiHop-RAG](https://arxiv.org/pdf/2401.15391)
- [ACL 2024: FanOutQA](https://aclanthology.org/2024.acl-short.2/)
- [LREC-COLING 2024: JEMHopQA](https://aclanthology.org/2024.lrec-main.831/)
- [GitHub: JEMHopQA](https://github.com/aiishii/JEMHopQA)
- [GitHub: JQaRA](https://github.com/hotchpotch/JQaRA)
- [GitHub: JaCWIR](https://github.com/hotchpotch/JaCWIR)
- [GitHub: llm-jp-longbench](https://github.com/llm-jp/llm-jp-longbench)
- [NLP2025 Q7-1 構造化知識RAG・文書ベースRAGを段階的に利用したマルチホップQA](https://www.anlp.jp/proceedings/annual_meeting/2025/pdf_dir/Q7-1.pdf)
- [NLP2025 Q2-17 JHARS](https://www.anlp.jp/proceedings/annual_meeting/2025/pdf_dir/Q2-17.pdf)
- [NLP2026 参加報告 (HACK The Nikkei)](https://hack.nikkei.com/blog/nlp2026/)
- [J-RAGBench (Speaker Deck)](https://speakerdeck.com/koki_itai/j-ragbench-ri-ben-yu-ragniokeru-generatorping-jia-bentimakunogou-zhu)
- [J-RAGBench 解説 (Zenn/NEOAI)](https://zenn.dev/neoai/articles/0998f81c39a583)
- [SB Intuitions: Sarashina3 rerank](https://www.sbintuitions.co.jp/blog/entry/2026/07/03/100056)
- [PFN: 日本語の自然さを測る評価手法の検証](https://tech.preferred.jp/ja/blog/llm-as-a-judge-for-japanese/)
- [ELYZA-tasks-100 横断評価 (Qiita)](https://qiita.com/wayama_ryousuke/items/105a164e5c80c150caf1)
- [arXiv:2510.09738 Judge's Verdict](https://arxiv.org/pdf/2510.09738)
- [arXiv:2606.19544 Reliability without Validity](https://arxiv.org/pdf/2606.19544)
- [arXiv:2605.02520 Benchmarking Retrieval Strategies for Biomedical RAG](https://arxiv.org/pdf/2605.02520)
- [Ragas: Align an LLM as a Judge](https://docs.ragas.io/en/stable/howtos/applications/align-llm-as-judge/)
- [RAG Evaluation with Confidence Intervals](https://saulius.io/blog/guide-to-rag-evaluation-with-confidence-intervals)
- [LlamaIndex: Auto Merging Retriever](https://docs.llamaindex.ai/en/latest/examples/retrievers/auto_merging_retriever/)
- [LlamaIndex: Document Summary Index](https://www.llamaindex.ai/blog/a-new-document-summary-index-for-llm-powered-qa-systems-9a32ece2f9ec)
- [Ragie: Summary Index](https://docs.ragie.io/docs/summary-index)
- [Microsoft: GraphRAG Costs Explained](https://techcommunity.microsoft.com/blog/azure-ai-foundry-blog/graphrag-costs-explained-what-you-need-to-know/4207978)
- [Ollama Embedding API (DeepWiki)](https://deepwiki.com/ollama/ollama/3.3-embedding-api)
- [YomiToku-Pro (MLism)](https://www.mlism.com/products/yomitoku-pro)
- [YomiToku 解説 (一創)](https://www.issoh.co.jp/tech/details/6169/)
- [RAGチャンキング戦略2026 (Zenn)](https://zenn.dev/0h_n0/articles/5137ee7d4dd05d)
- [日本語RAGの精度向上：形態素解析とセマンティックチャンキング](https://media.tcdigital.jp/ai-knowledge-flow/articles/japanese-rag-semantic-chunking/)
- [法律×RAG (AQUA)](https://www.aquallc.jp/legal-rag-guide/)
- [RAGチャンキング最適化 構造認識と可変長設計 (arpable)](https://arpable.com/artificial-intelligence/rag-chunking-optimization/)
- [RAGの精度が73%から100%に向上した話 (Qiita)](https://qiita.com/oharu121/items/1d06fb2fd01aca05a1a4)
- [Contextual Retrievalとは (スクーティー)](https://blog.scuti.jp/contextual-retrievalrag/)
- [PDFをマルチモーダル画像解析してRAGの精度を検証 (Zenn)](https://zenn.dev/never_inc_dev/articles/1c65cedfce4f12)
- [日本語OCR YomiToku を活用したRAG構築 (Zenn)](https://zenn.dev/rounda_blog/articles/313b7166d49efc)
