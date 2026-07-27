# 調査: クエリと文書の語彙ギャップ（lexical gap / vocabulary mismatch）

調査日: 2026-07-27 / 担当: Claude Code（調査担当）／対象: OTE-RAG Q02型の失敗
位置づけ: 文献先行の原則（`NEXT_PLAN_2026-07-27.md` §0-a）にもとづく実装前調査。

## サマリー

1. **最大の発見は文献ではなくコードにあった。** OTE-RAG は `LANCE_HYBRID_SEARCH=true` の経路で**チャンク単位のクロスエンコーダ再順位付けを一度も実行していない**（`lance/index.js:690` が `if (rerank) … else if (hybridSearchEnabled)` の**排他分岐**）。ハイブリッドは候補32件をRRFで融合し**そのままtopN=8に切り捨て**、bge-reranker は切り捨て**後**のチャンク内で「文」を選ぶだけ。**Q02の正解チャンクは候補32件に入っているのに、リランカーの入力にすら到達していない。**
2. **dense retrieval は語彙ギャップを原理的に解決しない**（EntityQuestions で DPR が BM25 に大差で敗北）。効く順は「候補プールを広げて cross-encoder に渡す」＞「索引時の文書側拡張」＞「クエリ側拡張（LLM）」。**クエリ側LLM拡張は強い検索器ほど害になる**という2025 SIGIRの実証がある。
3. 索引時LLM大量呼び出しが不可という制約下では **doc2query/HyDE は本命ではない**。本命は (a) リランク段の是正、(b) LLM不要の見出し・目次メタデータ注入、(c) 日本語SPLADE。

---

## 0. 既記載との差分

| 項目 | 状態 |
|---|---|
| Contextual Retrieval / Late chunking / RAPTOR / GraphRAG / 目次インデックス / 日本語N-gram BM25 | **既記載**（`RESEARCH_STRUCTURE_AWARE_RAG_2026-07-26.md`）。本レポートは語彙ギャップの観点から再評価のみ |
| doc2query / docTTTTTquery / Doc2Query-- / Doc2Token / TILDE / HyDE / query2doc / LLM-QEの負の実証 / EntityQuestions / Drowning in Documents / 日本語SPLADE / T2-RAGBench / HetDocQA | **すべて新規** |
| **リランク段が排他分岐で無効化されている件** | **新規（コード実測）** |

---

## 1. dense が語彙ギャップを救わない実証

呼称は **vocabulary mismatch problem**（Furnas et al. 1987）、近年は **lexical gap** / **semantic gap**。Q02は教科書的事例。

- **Sciavolino, Zhong, Lee, Chen, EMNLP 2021（arXiv:2109.08535）**: EntityQuestions で「**dense retrievers drastically under-perform sparse methods**」。原因は「**dense は訓練時に見た質問パターンでない限り、頻出エンティティにしか汎化しない**」。データ拡張では直らない。→ **「巻頭特集」のような低頻度の組版語彙で dense は構造的に弱い**
- **COIL（NAACL 2021）**: 単一ベクトル密検索は次元圧縮が低域通過フィルタとして働き、**厳密な語彙特徴（固有名詞・型番・低頻度語）を消す**。だから exact lexical match を復活させる設計（COIL/ColBERT/SPLADE）が要る
- **逆にBM25も救えない**のがQ02の要点。「巻頭」「テーマ」が文書に無ければ何もできない。**dense と sparse の失敗モードが同じ方向に揃っている**ケースで、RRFは両者の合意を強めるだけなので効かない。**ハイブリッドの原理的限界**であり、実測（クッションON/OFF 4条件で完全同値）と整合する

---

## 2. 文書側を拡張する手法

| 手法 | 報告効果量 | 索引時コスト | オフライン12Bで現実的か |
|---|---|---|---|
| **doc2query → docTTTTTquery**（Nogueira & Lin 2019） | MS MARCO **MRR@10: BM25 0.184 → 0.218 → 0.277（+50%相対）** | **チャンク数×40サンプル生成**。1,793チャンクなら7万回超 | **不可** |
| **Doc2Query--**（ECIR 2023, arXiv:2301.03266） | **反証側。** seq2seqが**hallucinate**した質問が検索効果を害す。低品質な生成質問を**捨てる**と **効果+16%、実行時間−23%、索引−33%** | doc2query＋フィルタ用モデル | 不可。ただし「**生成物の大半は捨てるべきノイズ**」は重要な知見 |
| **Doc2Token**（Walmart, arXiv:2406.19647） | doc2query比 nROUGE F1 +3.95%、本番A/Bで売上+0.28%。**doc2queryの生成トークンのうち新規語は20%のみ** | 欠落トークンのみ予測。doc2queryより大幅に安い | 概念は可。**日本語の既製品なし** |
| **TILDE / TILDEv2**（arXiv:2108.08513） | 文書側の語彙拡張をBERT語彙上の重み付けで実施。**計算コストは docT5query の1/140**。索引99%削減、再順位付けで+24% | **BERT 1パス／チャンク**（生成なし） | 可。**日本語の学習済みTILDEなし** |
| **日本語SPLADE**（`hotchpotch/japanese-splade-v2`, **MIT**, 0.1B） | JMTEB retrieval Avg **0.7309 vs multilingual-e5-large 0.6685**。v1のJQaRA nDCG@10 **0.6441 vs BM25 0.458 / bge-m3(sparse) 0.5088 / bge-m3(all) 0.576** | **BERT-base 1パス／チャンク**。1,793チャンクなら数分 | **最も現実的**。ただし**512トークン上限**と**転置索引の自前実装**（LanceDB FTSはスパースベクトルを直接扱わない）が壁 |
| **見出し・メタデータ前置** | T2-RAGBench で Contextual Hybrid **R@5 0.717 vs Hybrid 0.695**（arXiv:2604.01733）。Dense Hierarchical Retrieval（arXiv:2110.15439）は**階層見出しをカンマ区切りで本文に前置するのが最良**とアブレーションで確認 | **LLM 0回** | **可能・最安** |

> **注（推測）**: Q02で doc2query 的手法が効くかは疑わしい。正解チャンクは**目次ページで20.8%が組版由来の文字化け**。この入力から12Bが安定した質問を生成できるとは考えにくく、Doc2Query-- が指摘する hallucination リスクが最大になる領域。**日本語目次ページでのdoc2query実証は発見できなかった。**

---

## 3. クエリ側の拡張と、既存P1との差分

| 手法 | 報告効果 | P1との関係 |
|---|---|---|
| **query2doc**（EMNLP 2023, arXiv:2303.07678） | **BM25を+3〜15%**（MS MARCO/TREC DL）。fine-tuning不要 | **重複しない。** P1は「言い換えた質問文」で引き直すが、query2docは**擬似文書を元クエリに連結**する |
| **HyDE**（ACL 2023, arXiv:2212.10496） | 教師なしdenseを大きく上回る | **P1とほぼ同型で、P1の方が安全**。HyDEは仮想文書**だけ**で引くため、ハルシネーションが検索を丸ごと誤誘導する |
| **PRF** | He & Ounis, ECIR 2009 が「**一部クエリでQEが効果を害する**」と体系化（query drift） | Q02は1位が誤った序文チャンクなので**PRFは誤りを増幅する**（推測） |

**★P1との明確な差分**: P1は**拒否が発生してから**発火する事後的機構であり、**1回目の検索の順位を一切変えない**。**Q02は拒否されず「1/4だけ正しい回答」が返るため、P1は原理的に発火しない。** したがって**P1はQ02型を救えない**（実装仕様からの論理的帰結）。

---

## 4. 🔴 リランカーが救えない理由 — 本レポートの中核

### 4-1. OTE-RAG固有の原因（コード実測・確定）

`anything-llm/server/utils/vectorDbProviders/lance/index.js`:

```js
// L690
if (rerank) {                       // ← workspace.vectorSearchMode === "rerank" のときだけ真
  result = await this.rerankedSimilarityResponse({...});  // 候補をcross-encoderで再順位付け（dense-only）
} else if (this.hybridSearchEnabled) {                    // ← 製品はこちら
  result = await this.hybridSimilarityResponse({...});    // cross-encoder 呼び出しなし
}
// L96  hybridCandidateLimit(topN) { return Math.min(50, Math.max(20, topN * 4)); }  // topN=8 → 32
// L398 const fused = reciprocalRankFusion(denseResults, ftsResults, { limit: topN });  // 32→8に切り捨て
// L674 rerank = false,   ← 既定
```

**確定した事実**:
- `rerank` と `hybridSearchEnabled` は**排他**。**`LANCE_HYBRID_SEARCH=true` のとき、チャンク単位のクロスエンコーダ再順位付けは一切走らない**
- 製品既定は `LANCE_HYBRID_SEARCH=true`（`windows-native/config/server.env.template:35` と `runtime/docker-compose.yml:92` の両方）
- ハイブリッドは**候補32件**を作りながら、**RRFの順位だけで8件に切り捨てている**
- bge-reranker-v2-m3 が使われるのは `sentenceCushion.js` のみ＝「**すでに選ばれた8チャンクの中の文**」を選ぶ処理。**rank 9〜32 のチャンクはリランカーの入力に存在しない**
- `rerankedSimilarityResponse` は `.vectorSearch()` のみで**BM25を使わない**。現状「ハイブリッド」と「チャンク単位リランク」は**同時に使えない**

> **「リランカーが救えない」のではなく「リランカーに見せていない」。** Q02は `anchor_coverage@16 = 1.00` なので正解チャンクは候補32件に確実に存在する。**RRF融合後・切り捨て前に cross-encoder を挟むだけで解ける可能性が高い**（強い推測。**要A/B実測**）。
>
> **同梱3モデルのうち1つ（bge-reranker-v2-m3, 571MB）が、本来の役割を果たしていない。**

### 4-2. 一般的知見（文献）

- **「Drowning in Documents」arXiv:2411.11767**（Databricks+UIUC）。**bge-reranker-v2-m3を含む**4モデルを検証。**Kを増やすと効果は一旦上がってから低下**。最高性能がK=5000で出たのは学術データセットの**3.3%**のみ。**K=100→5000で Recall@10 が「検索単独より悪化」したのが学術53.3% / 企業44.4%**。原因は **phantom hits**（リランカーが語彙的にも意味的にも重ならない文書に高スコアを付ける）。→ **候補は広げるべきだが青天井は逆効果。K=32〜50が妥当**
- **Rau & Kamps, ECIR 2022（arXiv:2204.07233）**: cross-encoderの有効性は**query-passage cross-attention**由来。→ **クエリ語が文書に1語も無い場合、依拠する手がかりが乏しい**
- **「Beyond the Reranker」arXiv:2606.28367**（HetDocQA 762問/MuSiQue/QASPER）: cross-encoderを外すと **nDCG@10 が 0.644 → 0.034 に崩壊**。一方、強いリランカーがある前提では **RAPTOR階層・グラフ拡張・rank fusion・ルーティング・CRAG はいずれも +0.5 F1未満で有意差なし**。**唯一 HyDE だけが +6.7 F1（p<0.001）**

---

## 5. 日本語特有の論点（新規分）

- **bi-gram BM25 の限界**: 辞書不要な反面ノイズが出る。「巻頭」を bi-gram で引くと「巻」「頭」由来の偽陽性が混ざる。**ただしQ02のように語が存在しないケースでは bi-gram/形態素の別は無関係で、これはQ02の主因ではない**（重要）
- **日本語SPLADEが現実的な唯一の「文書側語彙拡張」**（MIT, 0.1B, 索引時BERT 1パス、LLM生成ゼロ）。制約は512トークン上限と転置索引の自前実装
- **bge-m3のsparseは既存語への重み付けであって新語の追加ではない**ため、Q02型の語彙ギャップには効かない。**SPLADEは語彙全体へ展開するので効く。この区別は重要**
- 日本語のHyDE検証は**すべて個人ブログ・ベンダー記事で統制実験なし**。共通所見は「HyDEは抽象的な質問に強く、**固有名詞・専門用語ではハイブリッド検索が最良**」（**査読なし**）

---

## 6. 🔴 否定的な研究・反証（最優先）

1. **Abe, Takeoka, Kato, Oyamada「LLM-based Query Expansion Fails for Unfamiliar and Ambiguous Queries」SIGIR 2025（arXiv:2505.12694）** — **査読付き・最重要**
   - **「高性能な検索器ほどQEで悪化する」**
   - Contriever+Q2D、BioASQ、LLMが知識不足のとき **nDCG@10 −10.02**／E5-base-v2+Q2E、AmbigQA高曖昧クエリで **−9.04**
   - 失敗モード: (a) LLMの知識不足で存在しない実体・無関係語を混入、(b) クエリ曖昧時に多数派解釈へ偏り検索範囲を狭める
   - **BM25の方がQEに頑健。dense側ほど壊れる**
   - → **我々のP1は、gemma4が対象文書の固有語彙を知らない領域では検索を悪化させる方向に働きうる。P1のA/Bを再検証すべき**
2. **「From BM25 to Corrective RAG」arXiv:2604.01733**（T2-RAGBench 23,088クエリ）: **HyDEが逆効果**。R@5 **HyDE 0.544 < Dense 0.587 < BM25 0.644 < Hybrid 0.695 < Contextual Hybrid 0.717 < Hybrid+Rerank 0.816**。Multi-Queryも 0.640 で Hybrid に劣る。**Hybrid+Rerank が単独最大の改善（MRR@3 相対+39.7%）**
3. **Doc2Query--（ECIR2023）**: doc2queryの生成物は hallucination を含み、そのままでは害
4. **Doc2Token**: doc2queryの生成トークンの**80%は文書に既にある語**＝索引時計算の大半が無駄
5. **Drowning in Documents**: 候補を増やしすぎると検索単独より悪化（学術53.3%）
6. **Beyond the Reranker**: 強いリランカーがあれば RAPTOR・グラフ拡張・rank fusion・ルーティング・CRAG は**有意な効果なし**
7. **HyDEの効果は2026年の2論文で結論が正反対**（+6.7F1 / 悪化）。ドメイン依存と読むのが妥当だが**推測**

---

## 7. OTE-RAGへの適用推奨度

| # | 手法 | 人日 | 期待効果 | 根拠の質 | 推奨 |
|---|---|---|---|---|---|
| 1 | **RRF融合後・topN切り捨て前に cross-encoder を挟む**（候補32→rerank→8）。**現状は排他分岐でリランカーが完全に不在** | **1〜2** | ★★★ 正解は候補32件内に存在（@16=1.00）。リランカーは nDCG@10 を 0.034→0.644 に変える最大要素／Hybrid+Rerank が R@5 +17.4% | **実証＋コード実測**。OTE-RAGでの改善は**推測、要A/B** | **A+** |
| 2 | **候補プールKの掃引（16/32/50）を評価に組み込む** | 1 | ★★ Kは上げすぎると検索単独より悪化 | 実証 | **A+** |
| 3 | **目次・見出しの構造抽出＋メタデータ注入**（既記載Track Bと同一） | 2〜5 | ★★★ Q02は本質的に「検索問題」ではない | 実証＋既記載 | **A+** |
| 4 | **チャンクへの見出し/sectionPath前置** | 1〜3 | ★★ Contextual Hybrid +2.2pt R@5。**LLM不要版** | 実証 | **A** |
| 5 | **文字化け（`�`）の索引前正規化** | 1〜2 | ★★ ノイズ2割は全段で不利。cross-encoderのphantom hit誘発要因 | **推測** | **A** |
| 6 | **P1の適用条件を絞る／A/Bで再検証** | 1〜2 | ★★ 「強い検索器ほどQEで悪化」 | **実証（SIGIR2025）** | **A−** |
| 7 | **日本語SPLADE をBM25の置換または第3チャネルに** | **8〜15** | ★★★ 語彙ギャップへの唯一の根本策で索引時LLM不要 | 実証（作者ベンチ。第三者検証は未確認） | **B+** |
| 8 | **query2doc** | 2〜3 | ★ BM25 +3〜15%。元クエリを保持するので事故が小さい | 実証 | **B** |
| 9 | **HyDE** | 2〜3 | ± 2026年の実証が正反対 | **矛盾** | **C** |
| 10 | **doc2query / docTTTTTquery** | 8〜12 | ★★ MRR@10 +50%（英語・専用モデル） | **索引時7万回超の生成＝実質不可** | **C** |
| 11 | **PRF / 古典的クエリ拡張** | 2〜3 | ± Q02では誤りを増幅（推測） | 実証（負の側） | **C** |
| 12 | **Doc2Token / TILDE** | 15+ | ★★ 概念は最適だが**日本語の学習済みモデルが存在せず自前学習が必要** | 実証（英語のみ） | **C** |

### 推奨する着手順

**#1 → #2 → #5 → #3 → #4** を1つの波（6〜13人日）として実施し、各ステップで paired A/B を取る。
**#1はコード変更が局所的（`hybridSimilarityResponse` の融合後に `reranker.rerank()` を1回挟む）で、再embed不要、最も安く最も効く可能性が高い。**
#7（日本語SPLADE）は#1〜#5で足りないことが実測されてから判断する。**doc2query系は本件の解ではない。**

---

## 不明点・要追加調査

1. **#1を実装したときQ02が実際に直るか。** 「候補32件に存在する」ことと「cross-encoderが上げてくれる」ことは別。**目次ページ（文字化け20.8%・断片的な行）は cross-encoder にとって明確にOOD**で、真の正解を低く付ける可能性がある。**実測必須**
2. **`rerankedSimilarityResponse` がBM25を使わない**設計をどう統合するか（現状ハイブリッドとリランクが両立しない）。upstream追従の観点も要検討
3. **`SENTENCE_CUSHION` と #1 の相互作用**
4. **japanese-splade-v2 の第三者ベンチが見つからない**（作者自身の評価のみ）。ONNX化可否・LanceDBでのスパース索引実装コストも未確認
5. **日本語の目次ページ／組版ノイズを含むチャンクに対する検索の実証研究が皆無**
6. **P1の既存A/B結果**をSIGIR2025の知見に照らして再解釈すべき

## 参考文献

[arXiv:2109.08535 EntityQuestions (EMNLP2021)](https://aclanthology.org/2021.emnlp-main.496/) ／ [arXiv:2301.03266 Doc2Query-- (ECIR2023)](https://arxiv.org/abs/2301.03266) ／ [docTTTTTquery](https://cs.uwaterloo.ca/~jimmylin/publications/Nogueira_Lin_2019_docTTTTTquery-v2.pdf) ／ [arXiv:2406.19647 Doc2Token](https://arxiv.org/abs/2406.19647) ／ [arXiv:2108.08513 TILDEv2](https://arxiv.org/abs/2108.08513) ／ [arXiv:2212.10496 HyDE (ACL2023)](https://aclanthology.org/2023.acl-long.99/) ／ [arXiv:2303.07678 query2doc (EMNLP2023)](https://aclanthology.org/2023.emnlp-main.585/) ／ [**arXiv:2505.12694 LLM-QE Fails (SIGIR2025)**](https://arxiv.org/abs/2505.12694) ／ [arXiv:2411.11767 Drowning in Documents](https://arxiv.org/html/2411.11767v2) ／ [arXiv:2204.07233 Rau & Kamps (ECIR2022)](https://arxiv.org/abs/2204.07233) ／ [arXiv:2606.28367 Beyond the Reranker](https://arxiv.org/html/2606.28367v1) ／ [arXiv:2604.01733 From BM25 to Corrective RAG](https://arxiv.org/html/2604.01733v1) ／ [arXiv:2110.15439 Dense Hierarchical Retrieval](https://arxiv.org/pdf/2110.15439) ／ [COIL (NAACL2021)](https://aclanthology.org/2021.naacl-main.241.pdf) ／ [hotchpotch/japanese-splade-v2](https://huggingface.co/hotchpotch/japanese-splade-v2) ／ [He & Ounis (ECIR2009)](http://terrierteam.dcs.gla.ac.uk/publications/he09ecir.pdf)

## 意思決定ログ

| 日付 | 内容 | 担当 |
|---|---|---|
| 2026-07-27 | Q02型（語彙ギャップ）の先行研究を調査。**調査の過程で、製品がハイブリッド検索経路でチャンク単位のcross-encoder再順位付けを一度も実行していないことをコードで発見**（`lance/index.js:690` の排他分岐）。同梱リランカー（571MB）は文単位クッションでしか使われていない。文献は cross-encoder を最大の効果要素と実証しており（nDCG@10 0.034→0.644）、**#1（融合後・切り捨て前にリランクを挟む）を最優先と結論**。あわせて **SIGIR2025 が「強い検索器ほどクエリ拡張で悪化する」と実証**しており、**既存P1の再検証が必要**と判明 | Claude（調査担当） |
