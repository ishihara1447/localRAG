# 非中国系LLM「抽出精度」調査（2026-07-15）

## 目的・前提

現行 `gemma4:12b`（Google, Apache-2.0, Ollama公式, 実行時VRAM約7.6-8GB）は、防衛白書546ページの実運用30問評価で **21/30（70%）・ハルシネーションゼロ**。残る失敗8件中6件は「検索は成功している（正解チャンクがtop8にある）のに、LLMが数値・日付を混同する／別チャンクを採用する／『記載なし』と誤って拒否する」という**抽出段階の失敗**（`RAG_HAKUSHO_EVAL_RESULT_2026-07-14.md`, `HYBRID_SEARCH_LINUX_VERIFY_RESULT_2026-07-15.md`）。ハイブリッド検索(BM25)導入後も同じ6件は変わらず残った＝検索改善では解決しない、LLM自体の「文脈から正確な事実を選び取る力」の課題。

制約: 中国系不可、VRAM 16GB（RTX 5070 Ti）、**Ollama公式ライブラリ配布のみ**（コミュニティGGUFはテンプレート破損の実害あり）、商用再配布可能なライセンス。

## 重要な限界（先に明記）

公開ベンチマークで測られている「ハルシネーション率」は主に**要約タスクでの捏造率**（Vectara Hallucination Leaderboard/FaithJudge）であり、本プロジェクトの実際の失敗モード──**「候補が数個ある似た数値・日付から正しい1つを選び取る」「定義文を読み違えずに答える」**──を直接測るベンチマークは見つからなかった。RULER/needle-in-haystackは「情報がどこにあるかを見つける」検索寄りのタスクで、これも今回の失敗（検索は成功済み）とは性質が異なる。したがって、**以下の比較はあくまで代理指標であり、最終判断には現行の防衛白書30問ハーネスでの実測A/Bテストが必須**。

## 候補モデル一覧

### 1. Microsoft Phi-4 14B

| 項目 | 内容 |
|---|---|
| 概要 | Microsoft製14B密モデル。合成データ＋厳選公開データで学習、SFT+DPOで指示追従を強化。 |
| ライセンス | **MIT**（最もクリーン、商用・改変・再配布に制約なし） |
| VRAM目安 | Ollama公式 `phi4:14b` 既定量子化で **9.1GB**（gemma4:12bの7.6GB比 +1.5GB程度、16GBに十分収まる） |
| コンテキスト長 | **16K**（gemma4:12bの256Kに比べ大幅に狭い。topN=8程度のRAGなら実用上は足りる可能性が高いが余裕は小さい） |
| 抽出精度の根拠 | **Vectara Hallucination Leaderboard（2026-05-11時点）で hallucination率 3.7%・factual consistency 96.3%、全モデル中Rank #4**。同リーダーボードで確認した非中国系モデルの中では最良値（gemma4:12b単体の値はリーダーボード未掲載）。出典: [vectara/hallucination-leaderboard](https://github.com/vectara/hallucination-leaderboard) |
| 日本語 | **弱点あり**。Phi-4は設計上「英語中心」で、公式ドキュメントも「英語以外の言語は性能低下がある」と明記。日本語はCommonCrawl/Wikipediaの多言語データに含まれるが主眼ではない。防衛白書のような日本語密文書での抽出精度は未検証で、Vectaraの3.7%が日本語でも維持される保証はない。 |
| Ollama公式 | ✓ `ollama.com/library/phi4`（14B/mini/reasoning系列あり） |
| 総合評価 | **測定済み忠実性（faithfulness）は候補中最良、ライセンスも最クリーン**。ただし日本語性能の実測データが無く、本プロジェクトの用途（日本語RAG）でこの強みが再現するかは不明。**実測検証が必須の最有力候補**。 |

### 2. IBM Granite 4.1 8B

| 項目 | 内容 |
|---|---|
| 概要 | IBM製、密（dense）decoder-only、2026-04-28リリース。RAG・ツール利用・構造化出力を明確に意識した設計。 |
| ライセンス | **Apache 2.0** |
| VRAM目安 | Ollama公式既定量子化で **5.3GB**（NF4 4bit量子化の実測では4.6GBという報告もあり、gemma4:12bより大幅に軽量。16GBに大きな余裕）。 |
| コンテキスト長 | 128K（トレーニング手法により512Kまで拡張可能とされる） |
| 抽出精度の根拠 | **Granite 4.0 H-Small（32B/9B active、8Bより大きい別モデル）はVectaraで hallucination率5.2%・Rank #13**。ただし対象候補の **Granite 4.1 8B（dense）自体のVectara/FaithJudge数値は見つからず**。関連情報として、IBMはMTRAG（マルチターンRAGベンチマーク）で「Granite 4.0はRAG設計を強みとする」と主張するが、Llama/Mistral等との頭合わせ数値は非公開（レビュー記事も「IBMの比較表はGranite同士の比較のみで、他社モデルとの直接比較表が無い」と指摘）。また SimpleQA（パラメトリック記憶からの事実回答）は8Bで**4.82%と非常に低い**＝「モデル自体は知識を持たず、検索結果への依存を前提に設計されている」ことを示唆（RAGでは適切な特性だが、裏を返せば実測前は未知数）。 | 
| 日本語 | 学習対象12言語に日本語を含む。コミュニティ実測（Qiita記事、2026-05）では「Granite 4.1 8B（NF4量子化）は要約・QA・議事録作成で十分実用的」と報告されるが、**定量スコア（精度%・ハルシネーション率）は開示なし**、定性評価に留まる。 |
| Ollama公式 | ✓ `ollama.com/library/granite4.1`（3B/8B/30B） |
| 総合評価 | **ライセンス最良（Apache2.0）＋VRAM最軽量＋RAG設計思想が用途と合致**という点で紙上のスペックは魅力的だが、抽出精度の実測エビデンスが薄い（8B単体のハルシネーション/忠実性データなし）。**実測検証必須の第2候補**。VRAM余裕が大きい分、将来的にtopNを増やす・より大きい30Bへの切替余地がある点も利点。 |

### 3. Mistral Small 3.2 24B

| 項目 | 内容 |
|---|---|
| 概要 | Mistral AI製24B密モデル。3.2は指示追従・関数呼び出し・繰り返し生成の改善版。 |
| ライセンス | **Apache 2.0** |
| VRAM目安 | Ollama公式既定量子化で **15GB**。**16GB VRAMカードでは非常にタイトで、KVキャッシュ・OS/他プロセスのオーバーヘッドを考えると実運用上のヘッドルームがほぼ無い**。gemma4:12bが8GB運用で `OLLAMA_NUM_PARALLEL` 設定ミスによりCPU転落した実績があり、15GB案は同種のリスクがより高い。 |
| コンテキスト長 | 128K |
| 抽出精度の根拠 | 直接のMistral Small 3.2データは見つからず。旧版 **Mistral Small(2501)がVectaraで hallucination率5.1%・factual consistency 94.9%**（gemma3-12bの4.4%より劣る）。GPQA等の総合ベンチでは強いが、忠実性(faithfulness)特化の指標では現時点でgemma系・Phi-4に劣る値。 |
| 日本語 | 数十言語対応と謳うが、コミュニティ実測（note記事）では「総合性能はGemma3 12BやQwen3 14B(Q4_K_M)と同程度」という報告に留まり、日本語での明確な優位性は確認できず。 |
| Ollama公式 | ✓ `ollama.com/library/mistral-small3.2` |
| 総合評価 | ライセンスは良好だが、**VRAM圧迫リスクが高く、忠実性の実測値も現行gemma4:12b想定より弱め**。優先度は低い。 |

### 4. NVIDIA Nemotron-3-Nano系

| 項目 | 内容 |
|---|---|
| 概要 | NVIDIA製。Mamba-2+MoEハイブリッド構成。 |
| ライセンス | NVIDIA Open Model License（商用利用・再配布可、ガードレール改変を除き制約は緩い） |
| VRAM目安 | Ollama公式タグは **4B（2.8GB、弱い）** と **30B-A3B（Q4_K_Mでも24GB、16GB超過）** の二極化。**16GBに収まる「ちょうど良いサイズ」の量子化が存在しない**。 |
| 抽出精度の根拠 | Vectaraで **Nemotron-3-Nano-30B-A3B: hallucination率9.6%**。gemma3-12b(4.4%)・phi4(3.7%)より明確に劣る。 |
| 日本語 | 30B-A3Bは日本語含む多言語対応と表記。ただし前回調査で有望視した日本語特化版 `Nemotron-Nano-9B-v2-Japanese` は**引き続きOllama公式ライブラリに存在せず**（コミュニティ配布のみ）。 |
| Ollama公式 | ✓（4B/30Bのみ、日本語特化版は非公式） |
| 総合評価 | **除外**。忠実性データも他候補に劣り、16GBに収まる版が弱小4Bしか無い。日本語特化版は依然Ollama非公式のため鉄則違反。 |

### 5. Cohere Command-R7B / Command-A / Command R+

| 項目 | 内容 |
|---|---|
| ライセンス | **Command-R7B: CC-BY-NC-4.0（非商用限定）**。Command-A/Command-R+も同種のCohere独自ライセンス＋C4AI Acceptable Use Policyで、**商用利用には別途Cohereとの商用ライセンス契約が必要**。 |
| 抽出精度の根拠 | Command-R-Plus: hallucination率6.9%、Command-A: 9.3%（Vectara）。gemma系より劣る。 |
| 総合評価 | **ライセンスの時点で即除外**。士業向け顧客への有償配布という製品要件（商用再配布可否）を満たさない。2026年に新設された「Command A+」はApache 2.0との情報もあるが218B級MoEで16GB VRAMには到底収まらず対象外。 |

### 6. Meta Llama系（Llama 4 Scout / Llama 3.3等）

| 項目 | 内容 |
|---|---|
| ライセンス | Meta独自コミュニティライセンス（700M MAU未満は商用可だが、Apache/MITほどクリーンではなく「Built with Llama」表記義務等の付帯条件あり） |
| VRAM目安 | Llama 4 Scout（109B、MoE）はQ4でも**約20GB以上**必要、Llama 3.3 70Bも大幅に16GB超過。**16GBに収まる新世代Llamaの現実的な選択肢が無い**（Llama 3.1 8B等の旧世代小型モデルはあるが、忠実性・日本語ともに他候補を上回る根拠が無く、世代的に見劣りする）。 |
| 総合評価 | **除外**（VRAM超過、ライセンスもApache/MITより制約あり、小型版は魅力に乏しい）。 |

## Vectara Hallucination Leaderboard 抜粋（2026-05-11時点、要約タスクでの契約整合性＝忠実性の代理指標）

| モデル | Hallucination率 | Factual Consistency | Rank |
|---|---:|---:|---:|
| Phi-4 | 3.7% | 96.3% | #4 |
| Llama-3.3-70B-Instruct-Turbo | 4.1% | 95.9% | #5 |
| Gemma-3-12B-it | 4.4% | 95.6% | #7 |
| Gemma-4-26B-A4B-it（MoE, 16GB超） | 5.2% | 94.8% | #14 |
| Granite-4.0-H-Small（32B/9B active, 16GB超） | 5.2% | 94.8% | #13 |
| Mistral Small(2501) | 5.1% | 94.9% | #12 |
| Gemma-3-4B-it | 6.4% | 93.6% | #28 |
| Command-R-Plus | 6.9% | 93.1% | #29 |
| Gemma-4-31B（16GB超） | 7.4% | 92.6% | - |
| Command-A | 9.3% | 90.7% | - |
| Nemotron-3-Nano-30B-A3B（16GB超） | 9.6% | 90.4% | - |
| Granite-3.3-8B-Instruct | 10.6% | 89.4% | - |

**注**: gemma4:12b（現行モデル、dense 12B）およびGranite 4.1 8Bの単体数値はこのリーダーボードに掲載が無い。一般論として「Gemma4系はGemma3系よりコンテキストへの忠実性が概ね半減する」という記事はあるが、gemma4:12b単体の直接測定ではなく推測の域を出ない。

出典:
- [vectara/hallucination-leaderboard (GitHub)](https://github.com/vectara/hallucination-leaderboard)
- [Benchmarking LLM Faithfulness in RAG with Evolving Leaderboards (arXiv 2505.04847)](https://arxiv.org/abs/2505.04847)

## 結論: 乗り換える価値がありそうな候補 上位

### 1位: Microsoft Phi-4 14B ── 条件付きで検証する価値あり

測定済み忠実性（Vectara Rank #4, 3.7%）が候補中最良、ライセンスもMITで最もクリーン、VRAMも9.1GBと余裕をもって16GBに収まる。**唯一かつ最大の懸念は日本語性能が未知数**（設計上英語中心と明記されている）。防衛白書30問ハーネスで実測し、日本語での忠実性がgemma4:12bの21/30を上回るか検証すべき。コンテキストが16Kと狭い点もtopN=8運用では致命的ではないが留意。

### 2位: IBM Granite 4.1 8B ── ライセンス・VRAM・設計思想は最良、実測データが薄いのでA/B必須

Apache 2.0・VRAM 5.3GB（gemma4:12bの約2/3）・RAG特化設計・日本語対応と、紙面上の適合度は高い。ただし忠実性の直接的なベンチマーク数値（Vectara/FaithJudge）が8B単体で存在せず、コミュニティの日本語実測も定性評価どまり。**「良さそう」の域を出ないため、Phi-4と同様に実測A/Bテストが前提**。VRAM余裕が大きい分、失敗時のダウンサイドリスクは小さい（システム全体の安定性への影響が少ない）。

### 3位（参考、優先度低）: Mistral Small 3.2 24B

Apache 2.0で忠実性も及第点级ではあるが、旧版Mistral Small(2501)の忠実性データ(5.1%)はgemma3-12b(4.4%)にすら劣り、**VRAM 15GB/16GBというヘッドルームの薄さが運用リスクとして重い**。積極的に乗り換える理由に乏しい。

### 総括: gemma4:12bを今すぐ置き換える「決定的な」根拠は無い

現時点の公開ベンチマークだけでは、**gemma4:12bが劣っていると断言できるデータは無い**（gemma4:12b単体のVectara測定値が存在しないため）。一方で、防衛白書30問評価で実際に観測されている「数値・日付の取り違え」「定義文の読み違え」という失敗モードを直接測るベンチマークは市場に存在せず、**理論値だけで移行を決めるのは危険**。

現実的な次アクション:
1. **Phi-4 14B** と **Granite 4.1 8B** の2つを、既存の防衛白書30問ハーネス（`scratchpad/hakusho_eval30.py`）で実測A/Bテストする（各モデルのプロンプト調整も必要になる可能性あり、gemma4:12bのときも過剰拒否/捏造対策のプロンプト調整で24→25/30に改善した前例がある）。
2. Phi-4は日本語弱点のリスクを許容してでも「忠実性最強」を試す価値がある一方、Granite 4.1 8Bは「VRAM超軽量＋RAG設計」というダウンサイドの小さい賭け。両方試して、gemma4:12bの21/30（防衛白書baseline）・25/30（士業規程10本baseline）を上回るか確認するのが最も費用対効果が高い。
3. どちらも明確に上回らない場合は、**gemma4:12bを現状維持**し、残る改善余地（コンテキスト順序制御・回答後検証など、`RAG_HAKUSHO_EVAL_RESULT_2026-07-14.md`記載の未実施施策）に投資する方が合理的。

## 出典一覧

- [Ollama library: phi4](https://ollama.com/library/phi4)
- [Ollama library: granite4.1](https://ollama.com/library/granite4.1)
- [Ollama library: mistral-small3.2](https://ollama.com/library/mistral-small3.2)
- [Ollama library: nemotron-3-nano](https://ollama.com/library/nemotron-3-nano)
- [Ollama library: command-r7b](https://ollama.com/library/command-r7b)
- [Ollama library: gemma4](https://ollama.com/library/gemma4)
- [Ollama library: llama4:scout](https://ollama.com/library/llama4:scout)
- [vectara/hallucination-leaderboard (GitHub)](https://github.com/vectara/hallucination-leaderboard)
- [Benchmarking LLM Faithfulness in RAG with Evolving Leaderboards (arXiv 2505.04847)](https://arxiv.org/abs/2505.04847)
- [Phi-4を MIT ライセンスで公開 (the-decoder.com)](https://the-decoder.com/microsoft-releases-full-phi-4-model-with-weights-under-mit-license/)
- [Phi-4技術レポート (arXiv 2412.08905)](https://arxiv.org/pdf/2412.08905)
- [IBM Granite 4.0 announcement](https://www.ibm.com/new/announcements/ibm-granite-4-0-hyper-efficient-high-performance-hybrid-models)
- [Granite 4.1 日本語性能を検証 (Qiita)](https://qiita.com/thayate/items/24eca0a003cb8999a33f)
- [IBM Granite 4.1 Review — ChatForest](https://chatforest.com/reviews/ibm-granite-4-1-dense-enterprise-llm-family-review/)
- [Granite 4.1 vs Gemma 4 comparison (aimadetools.com)](https://www.aimadetools.com/blog/granite-4-1-vs-gemma-4/)
- [ibm-granite/granite-4.0-h-small (Hugging Face)](https://huggingface.co/ibm-granite/granite-4.0-h-small)
- [Mistral Small 3.2 (2506) model card](https://docs.mistral.ai/models/model-cards/mistral-small-3-2-25-06)
- [Command R7B license discussion (Hugging Face)](https://huggingface.co/CohereLabs/c4ai-command-r7b-12-2024)
- [NVIDIA Nemotron Open Model License](https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-nemotron-open-model-license/)
- [Llama 4 Scout specs/VRAM (apxml.com)](https://apxml.com/models/llama-4-scout)
- 既存プロジェクト調査: `docs/MODEL_SELECTION_NON_CHINESE_2026-07-14.md`
