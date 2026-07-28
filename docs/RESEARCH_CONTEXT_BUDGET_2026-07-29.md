# 調査: 文脈構築バジェットと生成変換率 — 確立した解法の棚卸し

調査日: 2026-07-29
実施: researcherサブエージェント（Write権限が無かったため本ファイルはClaude Codeが保存）
**制約**: WebSearchのクォータ枯渇後の実施のため、全ソースをURL直接取得で収集。**arXivに偏っており、企業技術ブログ・非arXiv論文の網羅性は低い**。

## サマリー

1. **原因①（固定文数バジェット）にはほぼ完全に一致する既存解法がある。** EXIT（arXiv:2412.12559）の「文を**親チャンク全体を文脈として**スコアリングし、**固定本数ではなく閾値**で切る」設計は、固定バジェット型（RECOMP-extractive）が multi-hop で **−4.7〜−4.9 EM 悪化**したのに対し、無圧縮を **+2.0〜+8.1 EM 上回った**。**レイテンシは無圧縮より短い**（0.79s vs 1.03s, Llama-3.1-8B）。
2. **原因②（変換率0.777）は「バグではなく相場」である可能性が高い。** Sufficient Context の実測で、**十分な文脈があっても** Gemma 2 27B は 25.4% ハルシネート、GPT-4o 12.7%、Claude 3.5 は 11.1% 棄却。当製品の非変換率 22.3% は**公表値の帯域のど真ん中**で、**Gemma系は特に悪い側**。fine-tune不要で動かせる幅は **InstructRAG-ICL（8Bで +1.1〜+6.9pt）** 程度が現実的上限。
3. **「オラクル文脈で22問悪化」は推論設定のアーティファクトの可能性が高い。** The Power of Noise の同型現象は、The Powerless Noise（arXiv:2607.03615, 2026-07）で「**プロンプト文言とデコード長制限の小変更で出現・弱化・消失する**」と否定された。**プロンプト・出力長制限を固定した再測定を推奨。**

---

## A. 文脈構築（原因①）

### A-1. 「候補プールは広く、生成へは狭く」

**正直な結論: 「候補プールのrecallと最終kのrecallの差」を主題化した論文は見つからなかった。** IR分野ではrecall@kカーブとして自明扱いされているためと推測。

| 知見 | 出典 | 数値 |
|---|---|---|
| リランク段の候補集合は**クエリごとに適応的に切る**のが最適 | arXiv:2205.09638 | 1,000件中**平均27件**まで動的に刈っても MRR@10>0.38 を約90%のカバレッジで保証、**約37倍高速化** |
| リランク深度を上げるより**適度なリランク**が費用対効果が高い | arXiv:2601.14224 | 「moderate reranking often yields larger gains than increasing search-time reasoning」。**具体値は未取得** |
| 標準構成 | arXiv:2407.01219 | hybrid → monoT5 → reverse詰め直し → Recomp圧縮 |

### A-2. 🔴 EXIT — 当製品のクッション問題とほぼ同一

**EXIT: Context-Aware Extractive Compression（arXiv:2412.12559, 2024-12）**

| 論点 | EXIT | 当製品の現行クッション |
|---|---|---|
| 文のスコアリング入力 | **クエリ + 親文書全体 + 対象文** | 文単体と推定 |
| 切り方 | **閾値 τ=0.5 による適応選択** | **固定文数バジェット** |
| スコア式 | `r_ij = P("Yes"|q,d_i,s_ij) / (P("Yes")+P("No"))` | cross-encoderスコア |
| 圧縮器 | Gemma-2B-it（並列） | bge-reranker-v2-m3 |

**実測（Llama-3.1-8B リーダー、EM）**

| データセット | 無圧縮 | **EXIT** | **RECOMP-Extr** | LongLLMLingua |
|---|---|---|---|---|
| NQ | 34.6 | **35.9** | 34.6 | 30.2 |
| TriviaQA | 58.8 | **60.8** | 56.5 | 59.4 |
| HotpotQA | 28.1 | **30.6** | **23.4（−4.7）** | 28.0 |
| 2WikiMultihopQA | 16.1 | **24.2** | **11.2（−4.9）** | 21.5 |

70Bでも同傾向（2WIKI: 無圧縮20.8 → EXIT 28.6 / RECOMP-Extr 13.8）。

**最重要点**: **抽出型の文圧縮は「やり方次第で ±8pt 振れる」。** 固定的抽出は multi-hop で無圧縮より**大幅に悪化**し、文脈条件付き＋適応閾値は無圧縮を**上回る**。**当製品のクッション −0.099 は RECOMP型の失敗モードと症状が一致する。**

**レイテンシ**: 8Bで圧縮0.36sを足しても**トータル 1.03s → 0.79s（−23.3%）**。70Bでは 8.4s → 3.5s。

**同系統**
- **Provence**（arXiv:2501.16214, ICLR2025）: 系列ラベリングとして刈り込みを定式化し**リランクと統合**。「dynamically detects the needed amount of pruning」「negligible to no drop」。**追加モデルが必要**
- **Sentinel**（arXiv:2505.23277）: 凍結LLMのattention headをprobe。専用学習不要・非自己回帰1パス
- **RECOMP**（arXiv:2310.04408）: 圧縮率6%でも「minimal loss」と自己申告。**しかし上表の通り multi-hop で明確に損している。論文の自己申告と第三者再評価が食い違う典型例**

**FEVERの「最大5文」制約は一次資料で確認できなかった。「何文が最適か」をablationした研究は見つけられていない。**

### A-3. 固定 vs 適応バジェット

**Adaptive-k（arXiv:2506.08479, Megagon Labs）— 実装コストが最も低い**

アルゴリズム: ①全候補の類似度を計算 ②降順ソート ③**最大の落差の位置を探す** ④その位置+**バッファ5件** ⑤**上位90%に探索を制限**

追加LLM呼び出しゼロ、fine-tuneゼロ、リトリーバ/リーダーの変更ゼロ。

- 評価: HotpotQA/NQ/TriviaQA（128k）、HoloBench（100k）。埋め込み Contriever/BGE/GTE-Qwen2、リーダー GPT-4o/Gemini-2.5-Flash/Llama4系
- 結果: 固定kに**同等以上**、full context比で**最大10倍のトークン削減**、**context recall約70%維持**、集約QAで Self-Route に**最大+9pt**

**負の報告（論文自身が明記）**: 「fixed-k **occasionally outperforms** Adaptive-k, it requires prior knowledge of the optimal n」。**最適な固定kを事前に知っていれば固定が勝つ場合がある。**

**当製品との適合**: 166問がC3比較/C4要約など**型が混在**し、クッション損失がC4に26/59と偏る。**「最適kが型ごとに違う」典型状況**で、Adaptive-kの想定ケースにほぼ一致。

**その他の適応手法（採用推奨度は低い）**

| 手法 | 報告値 | 可否 |
|---|---|---|
| CAR（arXiv:2511.14769） | トークン−60%、レイテンシ−22%、ハルシネーション−10% | 可（統計処理のみ）。査読状況不明 |
| METEORA（arXiv:2505.16014） | recall+13.41%、回答精度+33.34% | **不可**（DPOチューニング必要） |
| DPS（arXiv:2508.09497） | MuSiQue F1 +30.06% | **不可**（学習必要） |
| SEAL-RAG / AdaGATE / Tail-Aware Adaptive-k / AdaGReS / LooComp | 各種+3〜13pt | **要注意**。2025末〜2026年の低被引用プレプリント群で、**互いを唯一のベースラインにしている自己参照的クラスタに見える（推測）**。独立再現の確認が必要 |

### A-4. 文脈を増やすと悪化する境界

**OP-RAG（arXiv:2409.01666）— 逆U字のピーク**

| モデル | データセット | ピーク位置 |
|---|---|---|
| Llama3.1-**8B** | EN.QA / EN.MC | **16K トークン** |
| Llama3.1-**70B** | EN.QA | 48K（47.25 F1） |
| Llama3.1-**70B** | EN.MC | 24K（88.65 acc） |

論文の説明: 「the larger-scale model has a stronger capability to distinguish the relevant chunks from irrelevant distractions」
→ **モデルが小さいほど最適文脈長は短い。12Bは8B寄りと考えるのが妥当（推測）。**

**順序の効果**

| 設定 | vanilla（関連度降順） | OP-RAG（原文書順） | 差 |
|---|---|---|---|
| EN.QA, 128チャンク | 38.40 F1 | 44.43 F1 | **+6.03** |
| EN.MC, 192チャンク | 81.22 acc | 88.65 acc | **+7.43** |
| **8チャンク程度** | — | — | **「advantage is not considerable」（論文原文）** |

**🔴 当製品への含意: 順序保持の効果はチャンク数が大きいときにのみ出る。上位8件しか渡していない現状では、順序をいじっても効果はほぼ期待できない。**

**Long-Context LLMs Meet RAG（arXiv:2410.05983, Google）**
- 検証モデルに **Gemma-2-9B-Chat / Mistral-Nemo-12B-Instruct** を含む（**12B級が入っている数少ない研究**）
- 強いリトリーバ（e5）では **inverted-U**、弱いリトリーバ（BM25）では単調に近い
- 劣化の主因は **hard negatives**（関連度は高いが答えを含まない文書）
- retrieval reordering は「consistently outperforms **when the number of retrieved passages is large**, with **negligible gains for smaller retrieval sets**」← **ここでも小Nでは効かない**
- 学習系は9データセットで一貫改善だが **fine-tune必須で当製品では不可**
- **プロンプトベースの対策は一切検証されていない**（当製品にとっては空白領域）

**The Power of Noise（arXiv:2401.14887, SIGIR2024）**
- モデル: Llama2(7B), Falcon(7B), Phi-2(2.7B), MPT(7B) ← **全て小規模**
- gold位置（Llama2, 関連18件）: **near 0.3781 / mid 0.1795 / far 0.2348**
- **「関連しているが答えを含まない文書」1件で最大 −25%**
- ランダム文書は逆に **+35〜36%**
- 推奨: **3〜5文書**
- 例外: Falconはランダム文書の恩恵パターンに従わなかった

**The Powerless Noise（arXiv:2607.03615, 2026-07）— 上記の追試・反証**
- 元条件では再現するが、**「prompt formulation と decoding limits の小変更で、効果が出現・弱化・消失する」**
- **truncation と malformed output が結果に大きく寄与していた**（出力長制限で答えが切れていた分が「雑音の効能」に化けていた）
- 結論: ランダム文書パディングは**堅牢な手法ではない**

**Context Rot（Chroma, 2025）**
- 18モデル（Claude/GPT/Gemini/**Qwen3 235B/32B/8B**）
- **needle-question類似度が低いほど、長さに対する劣化が急峻**
- **distractorは1個でも性能を下げる**。Claude系は棄却に傾き、GPT系は自信を持って誤答
- **haystackをシャッフルした方が、論理的につながったhaystackより成績が良い**（反直感）
- LongMemEval: **関連情報だけの約300トークンの「focused」プロンプトが、113kトークンのフル文脈を大きく上回る**

**🔴 当製品の観測との緊張**: Context Rot は「短く絞った方が良い」と言っており、**当製品の「オラクル文脈にすると22問悪化」とは逆向き**。追跡すべき。

### A-5. 要約タスク（C4）で証拠が落ちやすい理由

**この現象を「質問タイプ別の圧縮損失」として直接測定した論文は見つからなかった。** 周辺証拠:

| 証拠 | 出典 | 内容 |
|---|---|---|
| 集約系クエリは文脈長に最も脆い | HoloBench (arXiv:2410.11996) | 「tasks requiring aggregation ... show a noticeable drop as context length increases」。**max/min系は頑健**。「the amount of information ... has a bigger influence than the actual context length」 |
| 集約系QAでは最適文脈量が**未知かつ可変** | Adaptive-k | 「Self-RAG and Self-Route ... struggle with aggregation QA, where the optimal context size is both unknown and variable」 |
| 固定的抽出はmulti-hopで大きく損する | EXIT | HotpotQA −4.7 EM, 2WIKI −4.9 EM |
| 同上 | arXiv:2407.01219 | Recomp-extractive: NQ +0.77、TQA +1.71、**HotpotQA 33.92→29.46（−4.46）** |
| 集約推論そのものが弱い | MINTEval (arXiv:2605.18565) | 集約推論を要する質問で**平均正答率 27.9%** |
| 「aggregator noise」が独立の失敗モードとして命名 | arXiv:2506.16411 | cross-chunk dependence と aggregator noise を分離 |

**メカニズムの解釈（推測、実証されていない）**: 固定文数バジェットは**クエリによらない定数**だが、要約質問が必要とする証拠文数は**質問ごとに大きく変動する**。ファクトイドなら1〜2文、要約は10文以上。同一の固定バジェットを両者に適用すれば、損失は構造的に要約側に偏る。**当製品の「クッション損失の44%（26/59）がC4に集中」はこの説明と整合する。**

### A-6. 最適文脈長の実測値

| 出典 | 推奨値 | 条件 |
|---|---|---|
| Power of Noise | **3〜5文書** | Llama2-7B等、英語 |
| OP-RAG | **8B: 約16Kトークン / 70B: 24〜48K** | Llama3.1、チャンク128トークン |
| Searching for Best Practices | hybrid → monoT5 → reverse → Recomp | 英語 |
| Enhancing RAG (arXiv:2501.07391) | **Focus Mode: 80文書から各1文（80Doc80S）** がTruthfulQA最良（ROUGE-L +1.65%） | **Mistral-7B-Instruct** |

**Focus Modeの含意**: **「多数の文書から、文書あたり少数の文だけを抜く」構成が最良**。当製品のクッション設計の方向性自体は正しい。ただし**効果量は1〜2%と小さい**。論文のまとめ「Retrieving fewer sentences can enhance context by reducing noise while retrieving more sentences provides broader coverage but risks diluting relevance」。

**詰め直し順序（arXiv:2407.01219）**

| 順序 | RAG Score |
|---|---|
| forward（関連度降順） | 0.542 |
| reverse（最関連が末尾） | 0.560 |
| sides（最関連を両端） | 0.580 |

⚠️ **抽出記述では「reverseが最良」とされるが数値上はsidesが最高で矛盾している。採用前に原本確認が必要。**

---

## B. 生成の変換率（原因②）

### B-7. 🔴 Sufficient Context — 0.777は「相場」の可能性

**十分な文脈があるケースでの実測（arXiv:2411.06037, Google）**

| モデル | ハルシネーション率 | 棄却率 |
|---|---|---|
| Gemini 1.5 Pro | 14.3% | 1.6% |
| GPT-4o | 12.7% | 4.8% |
| Claude 3.5 Sonnet | 3.2% | **11.1%** |
| **Gemma 2 27B** | **25.4%** | 3.2% |

**当製品の変換率0.777＝非変換22.3%は、この帯域のど真ん中。しかもGemma系は最も悪い側（27Bで失敗率28.6%）。**

> **当製品の0.777は「壊れている」のではなく「gemma系12Bの相場」である可能性が高い。**（解釈だが上表が根拠）

これは「20問での実験値と完全に一致し、文脈の質を上げても動かない」という当製品の観測とも整合する。**この定数はモデル固有の性質であり、文脈側の改善では動かない**という仮説を支持する。

その他:
- 不十分な文脈では棄却率が50〜73%に跳ね上がるが、**それでもハルシネーションは15〜40%残る**
- **文脈なしの方が正答率が高い場合がある**（HotpotQAでGPT-4o 48.0%）
- 「小さいモデルは、十分な文脈があってもハルシネートするか**過剰に棄却する**」← **当製品のover-abstention観測と直結**
- **selective generation**: sufficient contextシグナル+自己確信度で棄却/回答を選択 → **正答率 +2〜10%**

**正直な報告: 「変換率そのものを上げた」と明言しているfine-tune不要の後続研究は見つけられなかった。** selective generation は「棄却すべきときに棄却する」精度を上げるもので、「文脈があるのに答えられない22%」を直接減らすものではない。

### B-8. 小規模モデルでの抽出精度向上（fine-tune不要）

**InstructRAG-ICL（arXiv:2406.13629, ICLR2025）— 最も適合度が高い**

**完全に学習不要**の変種。プロンプトに「質問 → rationale（denoisingの根拠説明）」のペアをN個demonstrationとして入れるだけ。

**Llama-3-8B-Instruct での改善幅**

| データセット | **ICL（学習不要）** | FT（参考） |
|---|---|---|
| PopQA | +1.1% | +5.2% |
| TriviaQA | +5.4% | +4.6% |
| Natural Questions | +5.3% | +9.1% |
| ASQA | +4.7% | +7.6% |
| 2WikiMultiHopQA | **+6.9%** | +1.1% |

**当製品にとって重要な2点**:
1. 「**consistently improves with the increasing number of demonstrations**」— 他のベースラインはdemonstration 1個でピークを打って劣化する
2. 「both variants **are not negatively affected by this increased noise ratio but rather gain further improvement**」— **検索文書数を増やしてノイズ率が上がっても劣化しない**

→ **これはA-1の inverted-U リスクを緩和する手段になりうる。文脈を広げるならInstructRAG-ICLと併用するのが論理的。**

**負の報告**: ASQAのcitation precision/recallではSelf-RAGにわずかに劣る。

**Context-faithful Prompting（arXiv:2303.11315, EMNLP2023 Findings）**
- 追加学習不要の2手法: **opinion-based prompt**（文脈を「ある語り手の発言」として提示し「語り手の意見は何か」を問う）、**counterfactual demonstration**
- 「significant improvement in faithfulness to contexts」、**abstentionも評価対象**
- **具体的な改善率とモデルサイズは未取得（要PDF確認）**

### B-9. over-abstention の抑制

**当製品の「オラクル文脈で22問悪化」について**:

1. **同型現象の存在**: Power of Noise の「gold のみの短い文脈より、無関係文書を足した長い文脈の方が良い（最大+35〜36%）」は構造的に同じ。**7B級での報告である点も一致**
2. **🔴 ただしその現象は否定されている**: Powerless Noise（2026-07）が「**prompt formulation と decoding limits の小変更で出現・弱化・消失する**」「**truncation と malformed output の寄与が大きい**」と結論
   → **当製品の22問悪化も、まずプロンプト文言と出力長制限を統制した再測定で切り分けるべき**（推奨であり、文献が当製品について言っているわけではない）
3. **逆向きの証拠**: Context Rot は「約300トークンのfocused >> 113kフル文脈」。**短い正解文脈の方が良いのが主流の観測。当製品の結果はこれと逆で、異常値として扱うのが妥当**
4. **小規模モデルの棄却傾向は既知**: 「smaller models tend to hallucinate or **abstain excessively even with adequate context**」
5. **プロンプトのみで棄却を減らした報告**: **ReCoVERR**（arXiv:2402.15610）が「VQAv2/A-OKVQAで最大20%多くの質問に精度を落とさず回答」。ただし**VQAでありテキストRAGではない**
6. **fine-tuneを要する手法（当製品では不可）**: GRAIT / CRaFT / ERA / HALT-RAG / Know Before You Fetch。**over-refusalを扱う研究の大半は学習ベース**

**正直な結論: 「文脈が短いと過剰に棄却する」現象を主題とし、プロンプトのみで解決した研究は見つからなかった。調査の空白領域であり、当製品の観測が正しければ報告価値のある新規知見である可能性がある（推測）。**

### B-10. 複数証拠の統合で生成が落ちる問題

当製品: C3比較が検索0.844 → 生成0.630（**−21pt**）。

| 出典 | 内容 |
|---|---|
| HoloBench | 集約系が最も劣化。「grouping relevant information generally improves performance, the **optimal positioning varies across models**」 |
| MINTEval | 集約推論で**平均27.9%** |
| arXiv:2506.16411 | cross-chunk dependence と aggregator noise に分解 |
| **LIT-RAGBench (arXiv:2603.06198)** | **日本語114問**でgenerator能力を5カテゴリ評価: **Integration / Reasoning / Logic / Table / Abstention**。架空エンティティで外部文書への接地を強制。「**no model exceeds 90% overall accuracy**」 |

**LIT-RAGBench は当製品にとって有用な外部ベンチマーク。** 日本語ネイティブで「Integration」「Abstention」という当製品の課題そのものをカテゴリ化している。**「gemma4:12b というモデル選択自体が変換率0.777の天井を決めているのか」を自作166問とは独立に切り分けられる。** ただしモデル別スコアは未取得。

### B-11. 構造化出力の強制

**Let Me Speak Freely?（arXiv:2408.02442, EMNLP2024 Industry）— 強い負の実測**

**推論タスクはJSON-mode（スキーマ制約付き）で大幅に悪化**

| タスク | モデル | 自然言語 | JSON-mode | 差 |
|---|---|---|---|---|
| GSM8K | GPT-3.5-Turbo | 76.6% | 49.3% | **−27.3** |
| GSM8K | Claude-3-Haiku | 86.5% | 23.4% | **−63.1** |
| GSM8K | **LLaMA-3-8B** | 74.7% | 48.9% | **−25.8** |
| Last Letter | **LLaMA-3-8B** | 70.1% | 28.0% | **−42.1** |

**分類タスクでは逆に改善**: DDXPlus で Gemini-1.5-Flash **+18.7**、GPT-3.5 **+11.4**

**有効だった緩和策**

| 緩和策 | 効果 |
|---|---|
| **NL-to-Format**（まず自然言語で答えさせ、別ステップで整形） | 「Nearly identical performance across most models」— **最も確実** |
| **スキーマを外した緩いJSON** | Claude-3-Haiku GSM8K 23.44% → **86.99%（+63.55）** |

> ✅ **2026-07-29 検証済み: 当製品は Ollama に `format` を指定しておらず、JSONスキーマを強制していない。したがってこの仮説は当製品には該当しない。**

**引用強制の効果**

| 出典 | 結論 |
|---|---|
| ALCE (arXiv:2305.14627) | ELI5で「even the best models lack complete citation support **50% of the time**」 |
| **Generation-Time vs Post-hoc Citation (arXiv:2509.21557)** | **トレードオフあり。生成時引用（G-Cite）は precision を優先して coverage を犠牲にする。事後引用（P-Cite）は高coverageと競争力あるcorrectnessを両立** |
| VeriCite (arXiv:2510.11394) | 5つのOSS LLMで「引用品質を大幅改善しつつcorrectnessを維持」 |
| RAGentA (arXiv:2506.16988) | correctness +1.09%、faithfulness +10.72% |

> 🔴 **2026-07-29 検証済み: 当製品は既定プロンプトで「出典必須」を生成時に要求している**（`server/models/systemSettings.js`）。
> **G-Cite の coverage 犠牲が、当製品の要素カバー率を押し下げている可能性がある。生きた仮説。**

---

## C. 実装可能性とレイテンシ

### C-12. 制約下で実行可能なもの

| 手法 | 追加モデル | 再embed | 追加LLM呼び出し | 可否 |
|---|---|---|---|---|
| **Adaptive-k（最大落差カット）** | 不要 | **不要** | ゼロ | **可**。既存スコア配列への算術のみ |
| **EXIT型クッション** | **不要**（bge-reranker-v2-m3を流用） | **不要** | ゼロ | **可**。入力の作り方と切り方の変更のみ |
| rank-1チャンクの文を必ず全採用 | 不要 | 不要 | ゼロ | **可**。数行 |
| 生成へ渡すチャンク数の拡大（8→12〜16） | 不要 | 不要 | ゼロ | **可だがinverted-Uリスク** |
| 原文書順の保持 / reordering | 不要 | 不要 | ゼロ | **可だが小Nでは効果ほぼゼロ（論文明記）** |
| JSONスキーマ緩和 | — | — | — | **該当なし（当製品は強制していない）** |
| **引用を事後パスへ** | 不要 | 不要 | +1回 | **可** |
| **InstructRAG-ICL** | 不要 | 不要 | ゼロ（プロンプト長は増える） | **可** |
| Context-faithful prompting | 不要 | 不要 | ゼロ | **可** |
| Provence | **要**（DeBERTa系） | 不要 | ゼロ | 条件付き（追加モデル制約に抵触） |
| Sentinel | 不要 | 不要 | +1 forward | 条件付き（Ollama経由でattention取得は困難と推測） |
| METEORA / DPS / GRAIT / CRaFT / RL系 | 要学習 | — | — | **不可** |

### C-13. レイテンシ

| 手法 | 実測 | 出典 |
|---|---|---|
| **EXIT** | 圧縮0.36sを足しても**1.03s → 0.79s（−23.3%）**（8B）。70Bでは8.4s → 3.5s | 2412.12559 |
| CAR | トークン−60%、レイテンシ−22% | 2511.14769 |
| Recomp | **+0.73s** | 2407.01219 |
| CompAct | 8.4s（EXITの0.8sに対し10倍） | 2412.12559 |
| リランカ単体 | TILDEv2 **0.02s**(27.83) / monoT5 **4.5s**(31.78) / monoBERT **15.8s**(31.69) / RankLLaMA **82.4s**(32.35) | 2407.01219 |
| Adaptive-k | 「single-pass, **no extra LLM inferences**」 | 2506.08479 |

**含意**: 抽出圧縮は**トークン削減による生成短縮が圧縮コストを上回る**ため**正味でレイテンシは下がる**。ただし**文スコアリング対象を増やす方向だけはコストが線形に増える**。

---

## 適用優先順位

### 前提

- 原因①（クッション −0.099）は**確立した解法があり、実装が軽く、レイテンシがむしろ改善する**
- 原因②（変換率0.777）は**Gemma系12Bの相場である可能性が高く、fine-tune不要で動かせる幅は+2〜7pt程度**
- したがって **①に投資し、②は「安く試せるものだけ」に絞る**

### 優先度1: クッションを「文脈条件付き＋適応閾値」に（EXIT方式）

| 項目 | 内容 |
|---|---|
| 実装量 | 中（既存 bge-reranker-v2-m3 を流用） |
| 再embed | **不要** |
| 追加モデル | **不要** |
| 応答時間 | **改善の可能性が高い**（8Bで1.03s→0.79s）。文スコアリング回数増分は線形増 |
| 期待効果 | クッション損失 −0.099 の大半の回収。EXITは同種の固定的圧縮に対し **multi-hopで+8〜13 EM** |

**3つの変更**: ①**クエリ+親チャンク全文+対象文**を入力に ②**固定文数を廃し閾値による適応選択** ③**rank-1チャンクの文は無条件で全採用**（文献にない当製品固有の対策。実測で1位チャンクの文が落ちているため）

### 優先度2: オラクル文脈での22問悪化の再測定（プロンプト・デコード設定を統制）

**効果ではなく「判断の土台」への投資。** 「オラクル文脈にすると悪化する」は文献の主流と逆であり、**この観測が誤りなら以降の意思決定の前提が崩れる**。特に**出力長制限によるtruncation**とプロンプト文言を疑う。根拠: Powerless Noise、Context Rot。

### 優先度3: 適応k（最大落差カット）でチャンク数を可変に

実装は**極小**（スコア配列への算術のみ）。集約QAで+9pt。**リスク: 論文自身が「最適な固定kを知っていれば固定が勝つ場合がある」と明記。現行の固定8が既に最適に近ければ効果ゼロ。**

**注意**: これは「上位8を増やす」のとは違う。**8のまま質問によって4にも14にもなる**設計。inverted-Uを避けつつrecallを回収できる点が本質。

### 優先度4: 引用を「生成と同時」から「事後パス」に移す

**当製品は既定プロンプトで生成時に出典を要求していることを確認済み。** G-Citeはprecision優先で**coverageを犠牲**にする（arXiv:2509.21557）。要素カバー率の改善が期待できる。**応答時間は+1生成分で明確に悪化**。当製品での再現は未検証。

### 優先度5: InstructRAG-ICL の rationale demonstration

Llama-3-8Bで**+1.1〜+6.9pt**。**検索文書数を増やしてもノイズで劣化しない**性質があり、優先度3と組み合わせると上限が上がる。**応答時間は悪化**（プロンプトが長くなる）。

### 実施しないことを推奨

| 手法 | 理由 |
|---|---|
| **上位8→16等への単純増加** | inverted-Uリスク。8Bは16Kトークンでピーク。hard negativesが主因。**優先度3の適応kで代替すべき** |
| **原文書順の保持 / reordering** | **論文2本が揃って「小Nでは negligible」と明記**。渡す件数を大幅に増やさない限り無駄 |
| **ランダム文書のパディング** | Powerless Noise（2026-07）で否定済み |
| **JSONスキーマ緩和** | **当製品は強制していない（検証済み）。該当なし** |
| Provence / Sentinel / METEORA / DPS | 追加モデルまたは学習が必要 |
| selective generation（フル版） | autorater用の追加呼び出しでレイテンシコストが高く、「文脈があるのに答えられない22%」を直接減らすものではない |
| 2025末以降の適応バジェット系プレプリント群 | 独立再現が確認できていない |

### 外部ベンチマークの推奨

**LIT-RAGBench（arXiv:2603.06198）を一度回すことを推奨。** 日本語114問で Integration / Reasoning / Logic / Table / **Abstention** の5カテゴリ。当製品の課題がそのままカテゴリになっており、**「gemma4:12b というモデル選択自体が0.777の天井を決めているのか」を自作166問とは独立に切り分けられる。**

---

## 不明点・要追加調査

1. **FEVERの「最大5文」制約を一次資料で確認できていない。「何文が最適か」をablationした研究は見つけられていない**（設問2後半は未解決）
2. Rerank Before You Reason（arXiv:2601.14224）の具体値
3. **arXiv:2407.01219 の repacking 実験の数値に矛盾がある**（reverseが最良とされるがsidesの方が高い）。原本確認が必要
4. Context-faithful Prompting の具体的改善率とモデルサイズ
5. **LIT-RAGBench のモデル別カテゴリ別スコア**（モデル選定判断に直結）
6. **「候補プールのrecallと最終kのrecallの差」を主題化した研究が見つからなかった**
7. **「文脈が短いと過剰に棄却する」現象をプロンプトのみで解決した研究が見つからなかった**
8. **2025末〜2026年の適応バジェット系プレプリント群は自己参照的クラスタに見える（推測）**
9. **WebSearchが使えず、企業技術ブログの実務知見をカバーできていない**
10. **日本語での文脈バジェット研究は実質存在しない**
