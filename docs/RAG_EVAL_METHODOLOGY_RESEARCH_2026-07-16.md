# RAG評価方法論 調査結果
調査日: 2026-07-16
調査担当: researcherエージェント（WebSearchによる一次情報調査）

## サマリー（3行以内）
- 業界標準は「retrieval評価とgeneration評価の分離」「LLM-as-judgeによるsemantic採点」「ground truthベースのgolden dataset（実務的最小50〜100問、100〜200問で本格運用）」であり、現行の「30問手作り＋正規表現/キーワードマッチ＋単発実行」は入口としては妥当だが3点で標準から乖離している。
- 最大の弱点は(1)キーワードマッチによる偽陰性、(2)retrieval/generationの未分離、(3)単発スコア比較に信頼区間がないこと。特に19/30→24/30のような差はn=30では統計的に有意とは言えない可能性が高い。
- オフライン制約下でもPrometheus 2 (7B) 等のローカルLLM-as-judge、retrieval指標(Hit Rate/MRR)の自動計算、複数回実行＋Wilson信頼区間の導入で、クラウド不要のまま大幅に厳密化できる。

---

## 1. 標準的なRAG評価フレームワーク

### 全体像
RAGAS・TruLens・DeepEvalが3大OSSフレームワーク。用途の棲み分けは概ね次の通り。
- **RAGAS**: RAG特化の4指標を提供。ground truthなしでも一部指標が動く軽量セットアップ。合成テストセット生成機能あり。「高速な実験」向き。
- **DeepEval**: 50超の指標ライブラリ、Pytestネイティブでlocal実行・CI/CD統合向き。「CIゲート」向き。
- **TruLens**: feedback functions + OpenTelemetryトレーシング。「本番モニタリング」向き。
- **ARES**: Stanfordの学術フレームワーク。合成データで軽量LM judgeをfine-tuneし、少数の人手アノテーション＋PPI（後述）で信頼区間付き評価を行う。

出典: [Atlan: LLM Evaluation Frameworks Compared](https://atlan.com/know/llm-evaluation-frameworks-compared/), [Medium: Choosing the Right LLM Evaluation Framework 2025](https://medium.com/@mahernaija/choosing-the-right-llm-evaluation-framework-in-2025-deepeval-ragas-giskard-langsmith-and-c7133520770c), [particula.tech: DeepEval vs Ragas vs TruLens](https://particula.tech/blog/deepeval-vs-ragas-vs-trulens-rag-evaluation-stack)（調査日 2026-07-16）

### RAGAS 4指標の定義と算出方法（重要）
RAGASのほとんどの指標は「LLMを構造化グレーダー（judge）として使い、その構造化判定を数値スコアに変換する」設計。

| 指標 | 測るもの | 算出方法 | Ground truth要否 | LLM呼び出し |
|------|---------|---------|-----------------|------------|
| **Faithfulness（忠実性）** | 回答が検索文脈に根拠づけられているか（ハルシネーション検出） | 回答をatomic statementに分解→各statementが文脈からentailされるかNLI判定→支持された割合 | 不要（文脈に対して判定） | 2回以上 |
| **Answer Relevancy（回答関連性）** | 回答が質問に的確に答えているか | 回答からLLMでn個（既定3）の質問を逆生成→元質問と各生成質問のembeddingコサイン類似度の平均 | 不要 | 1回＋embedding |
| **Context Precision（文脈精度）** | 検索チャンクが有用/関連的か（ノイズの少なさ） | 各チャンクを「有用か」二値判定→average precisionで集約（上位の有用チャンクを重く） | 不要 | チャンク数分 |
| **Context Recall（文脈再現率）** | 回答に必要な情報が検索文脈に含まれるか | reference回答をstatementに分解→各statementが文脈に帰属可能か判定→帰属割合の平均 | **必要（reference回答）** | 1回以上 |
| **Factual Correctness** | 回答が正解と事実整合するか | 回答をclaimに分解→referenceに対しNLI検証→precision/recall/Fβ | **必要** | 1回以上 |

- Faithfulness式: `支持statement数 / 全statement数`
- Answer Relevancy: 「回答が正しく質問に答えているなら、回答だけから元質問を復元できるはず」という直感に基づく。的外れだと復元質問が発散し類似度が下がる。
- Context Precision式: `AP = Σ(P@i × v_i) / (Σv_i + ε)`
- 実装は全てJSON schema＋few-shot＋パース失敗時のretryループを使う構造化プロンプト。

出典: [Ragas Docs Metrics](https://docs.ragas.io/en/v0.1.21/concepts/metrics/), [Ragas Response Relevancy](https://docs.ragas.io/en/stable/concepts/metrics/available_metrics/answer_relevance/), [saulius.io: Ragas Metrics Explained](https://saulius.io/blog/ragas-rag-evaluation-metrics-llm-judge)（調査日 2026-07-16）

### ARESのPPI（統計的裏付け）
ARESは合成学習データで軽量LM judgeをcontrastive learningでfine-tune。RAGシステムのquery-document-answer三つ組をサンプル採点し、**少数（数百件）の人手preference検証セットを使ったprediction-powered inference (PPI)**で各RAGシステムの品質に**信頼区間**を与える点が特徴。KILT/SuperGLUE/AIS等8タスクで数百アノテーションのみで機能。個人開発には重いが「judgeの誤りを人手少数で補正し信頼区間を出す」思想は参考価値大。

出典: [ARES arXiv 2311.09476](https://arxiv.org/abs/2311.09476), [stanford-futuredata/ARES GitHub](https://github.com/stanford-futuredata/ARES)（調査日 2026-07-16）

---

## 2. Golden datasetの作り方ベストプラクティス

### 作り方（human vs LLM vs hybrid）
推奨は**ハイブリッド**: まずLLMで「silver（合成）」データを作り、SMEレビュー・評価者間一致チェック・バイアス監査を経て「gold」に昇格させる。SMEを厚く関与させたgolden datasetは高コストで大規模構築は非現実的なため、silverで開発を回しつつgoldを育てる。合成の利点は質問分布を制御できること（例: 各チャンクに同数の質問を割り当てて一様分布をシミュレート）。

出典: [jakobs.dev: Evaluating RAG with synthetic QA generation](https://jakobs.dev/evaluating-rag-synthetic-dataset-generation/), [Microsoft Data Science: The path to a golden dataset](https://medium.com/data-science-at-microsoft/the-path-to-a-golden-dataset-or-how-to-evaluate-your-rag-045e23d1f13f), [statsig: Golden datasets](https://www.statsig.com/perspectives/golden-datasets-evaluation-standards)（調査日 2026-07-16）

### 質問タイプの分布設計（重要）
体系的taxonomyとして **fact_single / summary / reasoning / unanswerable** の4クラスが提唱されている。fact_singleとsummaryは文脈に明示的な答えが必要、reasoningは不要。multi-hopでは comparison / inference / compositional / bridge-comparison 等。
**negative/unanswerable質問は必須**: RAGは「範囲外・回答不能なクエリを拒否できるか」も評価対象で、これがないと過信・ハルシネーションを見逃す。合成データの多様性はN-gram Diversity・Self-Repetition・Homogenizationスコアで測る。

出典: [Know Your RAG: Dataset Taxonomy (arXiv 2411.19710)](https://arxiv.org/html/2411.19710v1), [Evaluating RAG on Unanswerable, Multi-hop Queries (arXiv 2510.11956)](https://arxiv.org/html/2510.11956v1), [Synthetic QA Datasets for RAG (emergentmind)](https://www.emergentmind.com/topics/synthetic-qa-datasets-for-rag)（調査日 2026-07-16）

### 何問あれば十分か（実務コンセンサス）
- 出発点: **30〜50問**の実クエリ（現行30問はここに該当＝入口としては妥当）
- 開発コア: **50〜100問**（全問にreference回答付き）が「妥当な最小」。約100問で資源を圧迫せず十分な多様性、という記述が複数。
- 本格運用: **100〜200問**（各問にgold chunk＋gold answer）
- 本番ゲート: **100〜500問**でprompt/model変更をgate

出典: [dev.to: How to Evaluate Your RAG System](https://dev.to/kuldeep_paul/how-to-evaluate-your-rag-system-a-complete-guide-to-metrics-methods-and-best-practices-18ne), [buildmvpfast: RAG Evaluation](https://www.buildmvpfast.com/blog/rag-evaluation-retrieval-quality-answer-accuracy-2026), [Apptension: RAG Quality Guide](https://apptension.com/guides/rag-quality-guide-evaluation-that-holds-up)（調査日 2026-07-16）

---

## 3. 採点方法の是非（キーワードマッチ vs semantic vs LLM-as-judge）

### Exact Match / キーワードマッチの限界
Exact Matchは表層形の一致に依存し、正当な語彙・構成のバリエーションを扱えず、**意味的に正しい回答を誤って減点する（偽陰性）**。lexical手法は安価だが偽陰性が多く微妙な意味差を見落とす。→ 現行の正規表現/キーワードマッチはこの弱点を直接抱える。

### Semantic similarity（BERTScore/BLEURT）
文脈embeddingで意味類似を捉えるが、微妙な意味的等価性の判別に限界。表現が大きく異なると人間判断との相関は中程度にとどまり、正解性に不可欠な細部を見落とすことがある。

### LLM-as-judge
自由形式QAで最も人間に近いが万能ではない: パラフレーズや長文回答を人間と比べ誤判定することがあり、システムのランキングを誤る・ハルシネーションに敏感・計算コスト高・バイアスを持つ。**人間評価が依然として最も信頼できる基準**。実務的には reference-guided（正解回答をjudgeに与える）方式が精度を上げる。

出典: [Reference-Guided Verdict (arXiv 2408.09235)](https://arxiv.org/html/2408.09235v3), [Reassessing Extractive QA with LLM-as-Judge (arXiv 2504.11972)](https://arxiv.org/pdf/2504.11972), [SMILE: Composite Lexical-Semantic Metric (arXiv 2511.17432)](https://arxiv.org/html/2511.17432)（調査日 2026-07-16）

### LLM-as-judgeの既知バイアス（導入時の注意）
- **Position bias**: 提示順で先頭を好む。→ 順序を入れ替えて平均する。
- **Verbosity bias**: 長い回答を高評価。position biasより除去困難（学習表現に埋め込まれている）。
- **Self-preference bias**: judgeが自分自身の出力を高評価。→ 評価対象と系統の異なるjudgeを使う（ただし完全ではない。judgeプールが同じ学習系統だと系統的に生じる）。
これらは丁寧なプロンプト設計とfine-tuneで部分緩和できるが完全除去は不可。

出典: [Position Bias in LLM Judges (mbrenndoerfer)](https://mbrenndoerfer.com/writing/position-bias-in-llm-judges), [Self-Preference Bias in LLM-as-a-Judge (arXiv 2410.21819)](https://arxiv.org/html/2410.21819v1), [Can LLMs Be Trusted for Evaluating RAG (arXiv 2504.20119)](https://arxiv.org/pdf/2504.20119)（調査日 2026-07-16）

---

## 4. 統計的信頼性の作法（現行の最大の穴）

### 小規模評価セットでの有意差判断
- **Wilson score interval**: 二項比率の信頼区間。標準正規近似はnが小さいとカバレッジが名目値を下回るが、Wilsonは**n=10程度でも**名目カバレッジに近い。成功率（例: 24/30）の区間推定に最適。
- **Bootstrap**: サンプル単位で復元抽出し1,000回程度リサンプル→95%信頼区間。差の95%CIが0を含まなければ有意とみなす実務が一般的。
- **判定則**: 2システムの95%CIが重ならなければ優劣の強い証拠。大きく重なる場合、差はランダム変動の可能性。
- **警告**: LLM評価の信頼区間は系統的に狭すぎる傾向があり、D-study等でより正直な区間を回復できる。

**現行への含意**: n=30で19/30(63%)→24/30(80%)。Wilson近似の概算では63%の95%CIはおよそ±17ポイント、80%はおよそ±14ポイント程度で区間が重なりうる。単発実行の差は「改善の示唆」ではあっても「統計的に有意」とは断定しにくい。最低限、複数回実行＋Wilson/bootstrap区間の併記が必要。

出典: [Cameron Wolfe: Applying Statistics to LLM Evaluations](https://cameronrwolfe.substack.com/p/stats-llm-evals), [Medium: The Statistical Reality of LLM Evaluation](https://medium.com/@juanc.olamendy/the-statistical-reality-of-llm-evaluation-what-works-what-doesnt-and-when-it-matters-7d9ba6ecdfca)（調査日 2026-07-16）

---

## 5. retrieval評価とgeneration評価の分離

多くのRAG研究はIR部分をgenerationと一体でend-to-end評価するが、これは(1)retrieval固有の寄与を隠す、(2)文脈ごとに毎回生成が要り計算コスト高、という欠点がある。**分離が重要**。

- **Retrieval指標**（生成不要・安価・決定的）:
  - **Hit Rate@k**: 上位k件に少なくとも1つ関連文書が入る割合。kが小さいUX評価に有用。
  - **MRR**: 最初の関連文書の順位の逆数の平均。top-1/2では「最初の項目が役立つか」の明快な指標。MRR≥0.6が体感的に「的確」の目安。
  - **nDCG@k**: 段階的関連度を順位重み付きで評価。理想ランキングとの近さ。[0,1]。
  - 他にPrecision/Recall/F1。
- **Generation指標**: faithfulness, answer correctness/relevancy（LLM-as-judge系）、参考にBLEU/ROUGE/METEOR/BERTScore/Perplexity。

分離の効果: 「検索が悪いのか、検索は良いが生成が悪いのか」を切り分けられる（RAGASのContext系 vs Faithfulness/Relevancy系の対比と同じ思想）。

**現行への含意**: 「正解チャンクとのマッチ」を採点している現行手法は、実はretrieval評価に近いものをgeneration正誤と混同している可能性がある。gold chunk IDを用意してHit Rate/MRRを別立てで測ると、改善が「検索改善」か「生成改善」かを分離できる。防衛白書546ページのような単一大規模文書では、gold chunkの定義（ページ/セクション単位）を決めればretrieval指標は自動計算可能で安価。

出典: [Redefining Retrieval Evaluation in the Era of LLMs (arXiv 2510.21440)](https://arxiv.org/html/2510.21440v1), [MultiHop-RAG (arXiv 2401.15391)](https://arxiv.org/pdf/2401.15391), [Deconvolute Labs: Retrieval Metrics](https://deconvoluteai.com/blog/rag/metrics-retrieval)（調査日 2026-07-16）

---

## 6. 日本語RAG特有の注意点

### 日本語評価データセット/ベンチマーク
- **JQaRA**（hotchpotch）: 検索拡張(RAG)評価のための日本語Q&A データセット。RAG精度評価目的で構築。日本語のretriever/reranker評価に直接使える。
- **JMTEB**（SB Intuitions）: 日本語テキスト埋め込みベンチマーク。embeddingモデル選定の評価基盤。
- **Allganize RAG Leaderboard（日本語）**: 金融/情報通信/製造/公共/流通小売の5ドメインで日本語RAG性能を評価。ドメイン別の実務ベンチ。

出典: [JQaRA GitHub](https://github.com/hotchpotch/JQaRA), [JMTEB SB Intuitions Blog](https://www.sbintuitions.co.jp/blog/entry/2024/05/16/130848), [Allganize 日本語RAG Leaderboard解説](https://blog-ja.allganize.ai/about_rag_leaderboard/)（調査日 2026-07-16）

### 日本語のチャンク分割・評価上の既知課題
- 見出しと本文の分離、表タイトルと表本体の分離、FAQの質問と回答の分離など「知識単位そのものの破壊」が回答不安定化の主因。防衛白書のような図表・見出し豊富な文書では特に注意。
- 実務例: 256文字ごと分割＋100文字オーバーラップで文意欠落を防ぐ手法。
- reranker導入で日本語検索精度が向上する（NVIDIA技術ブログの日本語検証あり）。
- **注意**: キーワード/正規表現マッチ採点は日本語で特に危険。表記ゆれ（漢字/かな、送り仮名、全角半角、同義語）で偽陰性が増幅する。日本語では意味ベース採点の必要性が英語以上に高い。

出典: [Zenn: RAGのチャンク分割法（発展編）](https://zenn.dev/serio/articles/fb3b6da8e09d17), [NVIDIA: リランキングモデルによる日本語RAG精度向上](https://developer.nvidia.com/ja-jp/blog/rag-with-sota-reranking-model-in-japanese/), [Microsoft Learn: RAGチャンク化フェーズ](https://learn.microsoft.com/ja-jp/azure/architecture/ai-ml/guide/rag/rag-chunking-phase)（調査日 2026-07-16）

---

## 7. オフライン・ローカルLLM運用での現実解

### ローカルLLM-as-judgeは実用段階
- **Prometheus 2 (7B)**: GPT-4-as-a-judgeのオープン代替。カスタムrubricで長文採点でき、人間評価とのPearson相関0.897。7B版は**16GB VRAM（コンシューマGPU）**で動作、Llama-2-70B超・Mixtral-8x7B同等。人間判断との一致72〜85%。
- **M-Prometheus**: 3B〜14Bの多言語judgeスイート。direct assessmentとpairwise両対応。日本語を含む多言語評価にはこちらが候補。
- **prometheus-eval**はvLLMでローカル推論可能。

出典: [Mozilla.ai: Local LLM-as-judge with Prometheus](https://blog.mozilla.ai/local-llm-as-judge-evaluation-with-lm-buddy-prometheus-and-llamafile/), [prometheus-eval GitHub](https://github.com/prometheus-eval/prometheus-eval), [Prometheus 2 (HuggingFace)](https://huggingface.co/papers/2405.01535), [M-Prometheus (OpenReview)](https://openreview.net/forum?id=Atyk8lnIQQ)（調査日 2026-07-16）

### 個人開発・小規模での「妥当な落とし所」
- retrieval指標（Hit Rate/MRR/nDCG）はLLM不要・決定的・安価。**まずここを自動化するのが費用対効果最大**。
- generation採点は「ローカルjudge（Prometheus系/手元LLM）＋reference-guided（正解回答をjudgeに渡す）」でクラウドなしでも意味ベース採点に移行可能。ただしローカルjudge自体のバイアス・信頼性は要検証（人手少数のスポットチェックでキャリブレーション）。
- 完全な人手golden＋大規模＋PPIは個人には重い。ARESのPPIやfine-tuned judgeは「知っておくが今は見送り」レベル。

---

## 今回の簡易評価手法に対する改善提案（優先度付き）

### A. すぐ導入すべき（低コスト・高効果・オフラインで完結）
1. **retrieval評価の分離＆自動化**: 各評価質問にgold chunk（ページ/セクションID）を紐付け、Hit Rate@k・MRR・nDCG@kを自動計算。LLM不要・決定的で、改善が「検索」か「生成」かを切り分けられる。防衛白書は単一文書なのでgold chunk定義が容易。
2. **複数回実行＋信頼区間の併記**: 単発スコアをやめ、同一条件で複数回実行し、Wilson score interval（n=30でも妥当）またはbootstrapで95%CIを出す。19/30→24/30が有意かをCIの重なりで判断。
3. **キーワード/正規表現採点の脱却（部分的に今すぐ）**: まず「表記ゆれ吸収（正規化・同義語辞書）」を入れて偽陰性を減らす。同時に手元LLMによるreference-guided二値判定（正解回答を渡して合否）をパイロット導入し、キーワード採点との乖離を測る。
4. **評価セットの質問タイプ明示＆negative追加**: 30問をfact/summary/reasoning/unanswerable(範囲外)に分類し、最低数問のunanswerable/negativeを追加（過信・ハルシネーション検出のため）。

### B. コストが見合えば検討すべき
5. **評価セットを50〜100問へ拡張**: 実務コンセンサスの「開発コア最小」。手作りコアをLLM合成（silver）で補い、自分でレビューしてgold化するハイブリッド。統計的検出力も上がる。
6. **ローカルLLM-as-judge本格導入**: Prometheus 2 (7B, 16GB VRAM) またはM-Prometheus (日本語向け)をvLLMで運用し、faithfulness/answer correctnessをrubricベースで採点。position/verbosityバイアス対策（順序入替平均、長さ正規化）と人手スポットチェックによるキャリブレーションをセットで。
7. **retrieval/generation指標のダッシュボード化**: Context Precision/Recall相当（検索）とFaithfulness/Answer Relevancy相当（生成）を分けて時系列記録し、変更のregressionを検知。RAGAS/DeepEvalの指標定義を自前実装 or ローカルモデルで再現。

### C. オフライン制約上、現状は現実的でない/見送り
8. **クラウドGPT-4-as-judge**: ローカル完結制約に反する。ローカルjudgeで代替。
9. **ARESフルパイプライン（fine-tuned judge＋PPI）**: 数百件の人手アノテーションとjudge学習が必要で個人開発には重い。思想（人手少数で信頼区間補正）だけ借用し、実装は見送り。
10. **数百〜数千問の大規模golden＋SME厚関与**: 個人リソースで維持困難。silver中心で運用し、実クエリが出たら随時goldを追加する漸進戦略で代替。
