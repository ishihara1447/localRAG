# 日本語RAG精度改善 調査レポート（2026-07-10）

対象システム: AnythingLLM (fork可) + Ollama + LanceDB、完全オフライン配布、
Embedding = mxbai-embed-large、LLM = llm-jp-4-8b-thinking Q4_K_M（GPU 16GB / ctx 8192）、
文書 = 就業規則・経費規程・契約書等の日本語法務系文書。

調査日: 2026-07-10（Web調査。情報の鮮度は各所に日付を明記）

---

## 0. エグゼクティブサマリー

1. **最大のボトルネックは現行embedding（mxbai-embed-large）**。同モデルは英語特化で、
   多言語・言語横断タスクでは「ほぼゼロに近いスコア」と報告されており、max 512トークンで
   長い条文も切り捨てられる。日本語特化モデル（ruri-v3系）とはJMTEB Retrievalで
   実質10ポイント以上の差がつくと推定される。**embedding入替が費用対効果で最優先**。
2. **リランカー導入の効果は実測値が最も明確**（JQaRA nDCG@10でembedding単体比 +13〜24pt）。
   日本語リランカーはMIT/Apache-2.0でONNX提供があり、CPUでも実用速度。パッケージ増は
   100〜600MB程度で済む。
3. **条文単位チャンキング＋見出しメタデータ**はモデル追加ゼロ（パッケージ増なし）で、
   「近接する類似数値の混同」という本システム固有の課題に最も直接効く。
   ハイブリッド検索（LanceDBのngram FTS）は条番号・金額など字句一致の取りこぼし対策として
   有効だが、単体の精度向上幅は+1〜2%と限定的。クエリ変換（HyDE等）は8B thinkingモデルの
   レイテンシ負担に対して効果が不確実で、優先度は最下位。

---

## 1. 日本語embeddingモデルの現在の実力比較

### 1.1 現行モデル（mxbai-embed-large）の問題点

- MTEB（英語）ではRetrieval 54.39と良好だが、**英語特化モデルであり、多言語・言語横断
  タスクではnomic-embed-textと並んで「ほぼゼロ」と評価**されている（2026年3月の10モデル
  実測ベンチマーク）。
- **入力512トークンで切り捨て**。日本語の条文（1条で数百字〜千字超）では後半が消える。
- 本来必要なクエリ用プロンプト（"Represent this sentence for searching relevant passages:"）
  を付けない運用だと本来の性能も出ない。

→ 日本語法務文書の検索基盤としては不適合。**入替そのものが最大の改善**。

### 1.2 主要候補の比較表（JMTEBスコアは各モデルカード/公式ブログ記載値）

JMTEB = 日本語テキスト埋め込みベンチマーク（SB Intuitions）。リーダーボードは現在
MTEB Leaderboard（General Purpose → Japanese）に移管されている。

| モデル | JMTEB Avg / Retrieval | パラメータ | max seq | ライセンス | Ollama/GGUF | 備考 |
|---|---|---|---|---|---|---|
| **ruri-v3-310m** (cl-nagoya) | **77.24 / 81.89** | 315M | 8192 | **Apache-2.0** | △ GGUFあり(Q8_0 337MB)だが**要パッチ版llama.cpp**（後述） | 日本語SOTA級。プレフィックス「検索クエリ: 」「検索文書: 」必須 |
| ruri-v3-130m | 76.55 / 81.9前後 | 132M | 8192 | Apache-2.0 | △ 同上 | 310mとRetrievalほぼ同等でより軽量 |
| **PLaMo-Embedding-1B** (PFN) | 76.10 / **79.94** | 1B | 訓練1024（config上4096） | **Apache-2.0** | ✕ transformers前提（独自arch、GGUF実績なし） | 2025-04時点で検索タスク首位級 |
| sarashina-embedding-v1/v2-1b (SB Intuitions) | 75.50〜 / 77.61〜（v2は2025-07-28時点で28データセット平均首位） | 1.2B | 8192 | **非商用ライセンス（商用は要契約）** | ✕ | **商用配布不可のため本件では除外** |
| ruri-large-v2 (v2系, BERT) | 74.55 / 76.34 | 337M | 512 | Apache-2.0 | **○ 標準Ollamaで動作**（BERT arch。kun432氏のOllamaモデル or 自前GGUF変換） | v3より劣るが「今すぐOllamaで動く」現実解 |
| multilingual-e5-large | 71.65 / 70.98 | 560M | 512 | MIT | ○（コミュニティGGUF/Ollamaモデルあり） | プレフィックス query:/passage: 必須 |
| Qwen3-Embedding-0.6B/4B/8B | 0.6BのJMTEB Retrieval 72.81（secon.dev実測 2025-06） | 0.6B〜8B | 32K | Apache-2.0 | **○ Ollama公式ライブラリ**（639MB〜4.7GB） | 多言語首位級だが日本語Retrievalはruri-v3に大差で劣る（同実測で「日本語は振るわない」と結論） |
| bge-m3 (dense) | JMTEB公式表に非掲載。JQaRA nDCG@10 0.539（mE5-large 0.554と同等圏） | 567M | 8192 | MIT | **○ Ollama公式ライブラリ**（1.2GB、5.1M pulls） | dense+sparse+multi-vectorの3方式対応（Ollama経由はdenseのみ） |

**読み方のポイント**
- 日本語Retrievalの序列（2025〜2026年の複数実測で一貫）:
  **ruri-v3 ≫ PLaMo-1B > sarashina > ruri-v2 > OpenAI 3-large(74.48) > bge-m3 ≒ mE5-large ≫ 英語特化(mxbai等)**。
- 2026-02公開の独立ベンチマーク（2000問、4言語）でも、ローカル勢ではruri-v3-310mが
  bge-m3を上回り、日本語特化でありながら英語・韓国語でもbge-m3と同等以上だった
  （「日本語特化だから多言語に弱い」は当てはまらない）。

### 1.3 Ollamaで動かす際の重要な注意（2026-07時点）

- **ruri-v3はModernBERTアーキテクチャ**。llama.cpp本体へのModernBERTサポートは
  2025-12にマージされたが、当初はGranite英語モデル向けで機能が不完全、かつ
  **Ollama側のvendor更新は速度問題で一度revertされた**経緯がある。
  現時点で「標準Ollamaにpullして終わり」とはならず、以下のいずれかが必要:
  1. **パッチ版/最新llama.cppのllama-serverを同梱**し、AnythingLLMの
     Generic OpenAI互換embedding provider経由で接続（GGUF Q8_0で337MB増、Q4_K_M版もあり）
  2. ONNX/transformers系ランタイムをforkに組み込む（変更大、非推奨）
  3. Ollamaの対応状況を継続ウォッチし、対応後に差し替え
- **今すぐ標準Ollamaで動く現実解**は bge-m3（公式）/ Qwen3-Embedding（公式）/
  ruri-large-v2（BERT系GGUF）。精度序列は ruri-large-v2 > bge-m3 ≒ mE5-large。
- **プレフィックス付与のfork改修が必須**: ruri系（検索クエリ:/検索文書:）、e5系
  （query:/passage:）は非対称プレフィックス前提。AnythingLLMのembedderプロバイダ層で
  「クエリ時とインデックス時に別プレフィックスを付ける」小改修（数十行規模）が要る。
  これを怠るとモデルカード記載の性能は出ない。

---

## 2. リランカー（cross-encoder）の導入効果

### 2.1 効果の実測値

JQaRA（日本語RAG向け検索評価、nDCG@10）での公表値:

| 段 | モデル | nDCG@10 |
|---|---|---|
| embedding単体 | ruri-large | 0.6287 |
| embedding単体 | multilingual-e5-large | 0.554 |
| embedding単体 | bge-m3 (dense) | 0.539 |
| 字句検索 | BM25 | 0.458 |
| リランカー | **ruri-v3-reranker-310m** | **0.8688** |
| リランカー | japanese-reranker-base-v2 | 0.7845 |
| リランカー | japanese-reranker-small-v2 | 0.7633 |
| リランカー | japanese-reranker-xsmall-v2 | 0.7403 |
| リランカー | bge-reranker-v2-m3 | 0.673 |
| リランカー | japanese-reranker-tiny-v2 | 0.6455 |

→ **最良embedding単体(0.63)に対し、リランカー導入で+11〜24pt**。本調査で確認した
全手法の中で最も向上幅の実証が明確。ELYZAの実験（2026-03-03公開）でも
cross-encoder最高はruri-v3-reranker-310mのnDCG@10 0.869で、GPT-4.1等のLLMリランクと拮抗。

**注意**: JQaRAはクイズ由来のデータセットで、日本語リランカー群はこの形式を学習済みのため
スコアが出やすい（bge-reranker-v2-m3が不利になる）傾向が指摘されている。規程・契約書
ドメインでの絶対値はこの通りにはならないが、「リランカー>embedding単体」の序列と
2桁ポイント級の改善傾向は複数データセット（JaCWIR MAP@10、MIRACL、JSQuAD）で一貫。

### 2.2 モデル選択肢（ライセンス・実行方式・速度）

| モデル | ベース | サイズ | ライセンス | 実行方式 | 速度目安 |
|---|---|---|---|---|---|
| **ruri-v3-reranker-310m** (cl-nagoya) | ModernBERT | 315M | **Apache-2.0** | transformers / ONNX変換可 | GPUで高速（flash-attn2対応）。精度最優先ならこれ |
| **japanese-reranker-base-v2** (hotchpotch) | ModernBERT | 111M | **MIT** | transformers / **ONNX提供あり** | RTX5090で15万ペア32.5s（≒0.2ms/ペア → top50再ランクで约10ms） |
| japanese-reranker-xsmall-v2 | ModernBERT 10層 | ~40M | MIT | ONNX提供あり | CPUで15万ペア2300s（≒15ms/ペア → **top50をCPUで約0.8s**） |
| japanese-reranker-tiny-v2 | ModernBERT 3層 | ~10M | MIT | ONNX提供あり | CPUで15万ペア702s（≒4.7ms/ペア → top50で約0.25s。Raspberry Piでも動く想定と作者言及） |
| bge-reranker-v2-m3 (BAAI) | XLM-R | 568M | MIT | transformers / GGUF・ONNXあり | 精度で日本語特化勢に劣後（JQaRA 0.673）ため本件では選ぶ理由が薄い |

**本システムへの適用メモ**
- GPU 16GBはLLM(8B Q4)で相当占有されるため、**リランカーはONNX+CPU実行が安全**。
  xsmall-v2ならCPUでもtop50再ランク≒1秒以下、パッケージ増は数十〜150MB程度。
- 精度を取るならruri-v3-reranker-310m（Apache-2.0）をGPU or ONNXで。VRAM余裕と相談。
- AnythingLLM本体のreranker機構の有無は別エージェント調査に委ねるが、実装形態としては
  「ベクトル検索でtop30〜50取得 → cross-encoderで再スコア → top5をLLMへ」が定石。
  レイテンシ増はCPU実行でも1秒前後であり、thinking系LLMの生成時間に比べ小さい。

---

## 3. ハイブリッド検索（BM25/字句 + ベクトル）

### 3.1 効果の定説（2025〜2026）

- 2026-02の日本語含む2000問ベンチマークでは、dense単体に対しハイブリッド（bge-m3 sparse併用）は
  **P@1で+1〜2%、P@10で+1.5%程度**。P@3ではdense単体が上回る場面もあり、
  「**リランキング前の候補取得（recall確保）に向く**」というのが結論。
- 一方で「ハイブリッドで必ず性能が上がるわけではない」ことも日本語QAデータセットの実測で
  報告されており、全文検索器（トークナイズ品質）の性能に強く依存する。
- ただし本件の文書特性（**条番号・金額・日数など、embeddingが潰しがちな字句情報が
  クエリに含まれる**）では、字句一致の取りこぼし救済としてベンチマーク数値以上の
  体感効果が期待できる。BM25単体でもJQaRA 0.458と、駄目なembedding（OpenAI 3-small
  0.388）より強い。定石は「hybrid で候補50件 → cross-encoder再ランク」。

### 3.2 LanceDBの対応状況（2026-07時点）

- LanceDBはネイティブFTS（BM25, tantivyベース）と `query_type="hybrid"` を公式サポート。
- **日本語トークナイズは2系統**:
  1. `base_tokenizer="lindera/ipadic"`（形態素解析）— ただし**辞書モデルを
     LANCE_LANGUAGE_MODEL_HOME 配下に別途配置（要ビルド）**が必要で、オフライン配布では
     辞書同梱の手間とサイズが増える
  2. **`base_tokenizer="ngram"`（ngram_min_length=2 等）— 辞書不要で日本語bi-gramが
     成立**。「東京」「設計」等の複合語を言語非依存で拾える。インデックスは大きくなり
     精度（適合率）は形態素解析に劣るが、導入が圧倒的に軽い。Node.js SDKでも
     `ngramMinLength` 指定での実装例が公開されている（2026年のローカルRAG実装記事）
- AnythingLLMはLanceDBをNode SDK経由で使うため、**ngram FTSインデックス＋hybrid検索は
  fork内の小改修で実現可能な範囲**（FTSインデックス作成＋クエリ側をhybridに変更＋
  RRF等での統合）。lindera利用はWindows配布での辞書ビルド・配置が重く、第一段階では
  ngram推奨。
- なお中国語FTS等でのCJK対応議論は継続中（ICU/UAX#29トークナイザの提案 Issue #6661 等）。
  将来的にはICUトークナイザが本命になる可能性があり、ウォッチ対象。

---

## 4. 日本語法務文書のチャンキング戦略

### 4.1 定説（2025〜2026の国内実践記事・Azureガイダンスの集約）

- ベースライン: **512トークン + オーバーラップ10〜25%**（Azure AI Search系ガイダンス）。
  日本語文字数に直すと概ね**400〜800字/チャンク**（トークナイザ依存のためトークン基準推奨）。
- ただし規程・契約書のような**構造化文書では固定長より「構造認識分割」が明確に優位**という
  のが国内実践記事の一致した結論。契約書レビュー用途では「条文単位の分割が有効」
  「見出し（Header）メタデータ付きでトピック単位にまとまる」と整理されている。

### 4.2 本システムへの具体的推奨

1. **条単位分割を第一原則にする**: 「第◯条」「第◯章」「附則」等の正規表現で分割。
   1チャンク=1条。長い条（>800字目安）は項・号単位に落とす。条界で切る限り
   オーバーラップは原則不要（固定長分割にフォールバックする箇所のみ10〜20%）。
2. **各チャンク先頭に階層パスを埋め込む**: 例「就業規則 > 第4章 賃金 > 第31条（時間外手当）」。
   これにより (a) embeddingに文脈が乗る、(b) **近接する類似数値（「30日」「14日」等）が
   どの条の数値かをLLMが区別できる**、(c) 回答時の出典明示が可能になる。
   形態素解析で名詞キーワードを抽出しメタデータ付与する手法はハイブリッド検索とも相乗する。
3. **small-to-big（親子チャンク）**: 検索は条単位の小チャンクで行い、LLMには章単位や
   前後条を含む親コンテキストを渡す。ctx 8192の制約下ではtop5×条単位が現実的。
4. AnythingLLM側はデフォルトが汎用の再帰分割（文字数ベース）のため、**規程系文書向けの
   条文スプリッタをdocument processor層に追加するfork改修**が必要。モデル追加ゼロで
   パッケージサイズ増なし。改修はスプリッタ追加に閉じるためupstream追従への影響も小さい。

---

## 5. クエリ変換（HyDE / マルチクエリ / クエリ拡張）

- HyDE（LLMで仮回答を生成してそれで検索）は国内でも検証記事が多いが、**効果はコーパスと
  クエリ性質に強く依存し、「必ず効く」という定説はない**。概念整理記事（2026-05）でも
  「評価セットで定量比較してから採用すべき」という位置づけ。
- ローカル8B級でもクエリ変換自体は品質的に可能（7B以下でも実用範囲が広がっていると
  国内記事で言及）だが、本システム固有の問題として:
  - **llm-jp-4-8b-thinkingはthinkingトークンを吐くため、検索前に1回LLM往復を挟むと
    体感レイテンシが大きく悪化**する（生成が支配的な現構成でさらに数秒〜数十秒増）
  - マルチクエリはN回検索+統合でさらに増
- **推奨**: 優先度最下位。導入するなら「同義語辞書ベースの軽量クエリ拡張」（労基法用語⇔
  社内用語、例: 有休⇔年次有給休暇）をLLM無しで行う方が、法務ドメインでは費用対効果が高い。
  HyDE/multi-queryは評価基盤（§6）を作った後にA/Bで判断。

---

## 6. 日本語RAG評価（データセットと実務評価セット設計）

### 6.1 公開データセット

| データセット | 内容 | 指標 | 用途 |
|---|---|---|---|
| **JQaRA** (hotchpotch) | 質問+候補100件（Wikipedia由来、クイズ形式） | nDCG@10 | 検索・リランカーの相対比較 |
| **JaCWIR** (hotchpotch) | カジュアルWeb文書のタイトル/概要 | MAP@10 | Wikipedia以外での頑健性確認 |
| JMTEB Retrieval（JAQKET, Mr.TyDi-ja, NLP Journal等） | 埋め込み総合 | nDCG@10等 | embeddingモデル選定 |
| MIRACL-ja / JSQuAD | 多言語IR / 読解QA | nDCG / EM | 補助 |

注意: いずれもWikipedia・Web由来で**規程・契約書ドメインは含まれない**。モデル間の
相対比較には使えるが、絶対精度は自社評価セットで測る必要がある。

### 6.2 実務評価セットの設計知見

- **LLMによるQA自動生成が実務の主流**。NTTデータの手法（NLP2025）は、文書からQAペアを
  生成→「質問者観点の妥当性」「QAペアの正当性」の2段品質チェックで高品質化する構成。
- Ragasのテストセット自動生成は**日本語ではデフォルト設定で動作しない問題**が報告されて
  おり、プロンプトの日本語化が必要（朝日新聞メディア研究開発センターの検証）。
- 本件推奨: **50〜100問の固定評価セット**を最初に作る。構成は
  (a) 条文特定型（「経費精算の提出期限は？」→ 該当条を当てられるか: Recall@5/nDCG@10）、
  (b) 数値混同誘発型（近接する類似数値を持つ条のペアを狙い撃ち）、
  (c) 複数条合成型、(d) 該当なし型（拒否できるか）。
  検索指標（Recall@k）と回答正誤を分離して測ることで、改善がretrieval起因か
  generation起因かを切り分ける。全施策のA/B判断はこのセットで行う。

---

## 7. 適用優先順位の提案（費用対効果順）

| 優先 | 施策 | 期待効果（根拠） | 実装工数 | パッケージ増 | レイテンシ増 | ライセンス |
|---|---|---|---|---|---|---|
| **P0** | 自社評価セット構築（50問） | 全施策の判断基盤（効果測定不能状態の解消） | 1〜2日（LLM生成+人手レビュー） | 0 | 0 | — |
| **P1** | **embedding入替**: mxbai → 短期は bge-m3（Ollama公式）or ruri-large-v2、本命は **ruri-v3-130m/310m**（パッチ版llama-server同梱 + Generic OpenAI provider接続）＋クエリ/文書プレフィックス付与のfork小改修 | 序列で2段階以上の改善見込み（JMTEB Ret: mxbai=日本語実質圏外 → bge-m3/mE5≒71 → ruri-v3≒82）。JQaRAでもruri系はbge-m3比+9pt | 短期案0.5日／本命案2〜4日（llama-server同梱・起動管理含む） | ruri-v3: +0.3〜0.7GB／bge-m3: +1.2GB | ほぼ0（軽量モデル） | Apache-2.0 / MIT |
| **P2** | **条文単位チャンキング＋見出しパス付与＋small-to-big** | 構造化文書では固定長より優位が国内実践の一致結論。近接数値混同への最直接対策。要再インデックスのみ | 2〜4日（スプリッタ+メタデータ+プロンプト整形） | **0** | 0 | — |
| **P3** | **リランカー導入**（xsmall-v2 ONNX/CPU、精度重視ならruri-v3-reranker-310m） | **JQaRA nDCG@10で+11〜24pt**（embedding単体比）。全手法中、実証された向上幅が最大 | AnythingLLM側機構次第（別調査）。モデル組込自体は1〜2日 | +0.05〜0.6GB | CPUでtop50≒0.3〜1秒 | MIT / Apache-2.0 |
| **P4** | **ハイブリッド検索**（LanceDB ngram FTS + RRF統合） | 単体では+1〜2%（P@1）だが、条番号・金額等の字句一致救済とリランク前recall確保に有効。P3とセットで真価 | 2〜3日（fork内: FTSインデックス+hybridクエリ+RRF） | 0（ngramなら辞書不要。インデックス増のみ） | 数十ms | LanceDB: Apache-2.0 |
| **P5** | クエリ変換（HyDE/multi-query） | 効果不確実（定説なし、コーパス依存）。thinking 8Bでは検索前LLM往復のレイテンシが重い | 1〜2日 | 0 | **+数秒〜数十秒** | — |

**推奨ロードマップ**: P0→P1(短期案で即効)→P2 をまず実施し評価セットで効果確認 →
P3（リランカー、別エージェントのAnythingLLM機構調査と合流）→ P4 → P1本命案
（ruri-v3化、Ollama/llama.cppのModernBERT対応成熟を見て判断）→ P5は保留。

**リスク・留意点**
- ruri-v3のOllama標準対応は2026-07時点で未成熟（llama.cpp本体マージ済みだがOllama側revert
  歴あり）。パッチ版llama-server同梱はWindows配布物のビルド・保守コストが乗る。
  短期はbge-m3/ruri-large-v2で確実に底上げし、ruri-v3は対応成熟後に差し替えが低リスク。
- embedding入替は**全文書の再インデックスが必要**（顧客環境での移行手順を配布物に含める）。
- JQaRA等の数値はWikipedia/クイズドメインでの値。規程類での絶対値は必ず自社評価セット
  （P0）で確認する。sarashina系は非商用ライセンスのため候補から除外済み。

---

## 8. 参照URL一覧

### embeddingモデル（一次情報）
- ruri-v3-310m モデルカード（JMTEB表・ライセンス・プレフィックス仕様）: https://huggingface.co/cl-nagoya/ruri-v3-310m
- ruri-large-v2 モデルカード（BERT系・JMTEB表）: https://huggingface.co/cl-nagoya/ruri-large-v2
- Ruri論文（NLP2025）: https://www.anlp.jp/proceedings/annual_meeting/2025/pdf_dir/Q4-3.pdf
- PLaMo-Embedding-1B 開発ブログ（PFN, JMTEB表・Apache-2.0明記）: https://tech.preferred.jp/ja/blog/plamo-embedding-1b/
- sarashina-embedding-v2-1b（非商用ライセンス）: https://huggingface.co/sbintuitions/sarashina-embedding-v2-1b/blob/main/README_JA.md
- JMTEB（リーダーボードはMTEB Leaderboardへ移管）: https://github.com/sbintuitions/JMTEB / https://huggingface.co/spaces/mteb/leaderboard
- Qwen3-EmbeddingのJMTEB実測（secon.dev, 2025-06-11）: https://secon.dev/entry/2025/06/11/100000-qwen3-embedding-jmteb/
- Ollama公式 bge-m3: https://ollama.com/library/bge-m3
- Ollama公式 qwen3-embedding: https://ollama.com/library/qwen3-embedding
- ruri-v3-310m GGUF（要パッチ版llama.cpp）: https://huggingface.co/Targoyle/ruri-v3-310m-GGUF / https://huggingface.co/Targoyle/ruri-v3-310m-GGUF-Q4_K_M-imatrix
- llama.cpp ModernBERT対応（Issue #11282、2025-12マージ・制限あり）: https://github.com/ggml-org/llama.cpp/issues/11282
- Ollamaで動くruri（v1/v2系, kun432）: https://ollama.com/kun432/cl-nagoya-ruri-large
- mxbai-embed-large（Ollama公式・512tok制限）: https://ollama.com/library/mxbai-embed-large
- 10モデル実測ベンチ（2026-03, mxbaiの多言語弱点）: https://zc277584121.github.io/rag/2026/03/20/embedding-models-benchmark-2026.html
- 日本語RAG 6構成2000問ベンチ（2026-02-12, ruri-v3 vs bge-m3・ハイブリッド効果）: https://zenn.dev/fp16/articles/aa48dcae23974e

### リランカー（一次情報）
- JQaRA（スコア表: embedding/BM25/リランカー比較）: https://github.com/hotchpotch/JQaRA
- japanese-reranker v2 公開記事（secon.dev, 2025-05-08, スコア・速度表・ONNX言及）: https://secon.dev/entry/2025/05/08/100000-japanese-reranker-v2/
- japanese-reranker-base-v2（MIT）: https://huggingface.co/hotchpotch/japanese-reranker-base-v2
- japanese-reranker-xsmall-v2 / tiny-v2: https://huggingface.co/hotchpotch/japanese-reranker-xsmall-v2 / https://huggingface.co/hotchpotch/japanese-reranker-tiny-v2
- ELYZAリランカー比較実験（2026-03-03）: https://zenn.dev/elyza/articles/2642fd1b964fd2
- JaCWIR: https://github.com/hotchpotch/JaCWIR

### ハイブリッド検索・LanceDB
- LanceDB FTS公式ドキュメント（lindera/ipadic・ngramトークナイザ）: https://docs.lancedb.com/search/full-text-search
- Node SDKでのngram日本語FTS実装例（2026）: https://www.norsica.jp/blog/local-rag-agentic-coding
- ICU/UAX#29トークナイザ提案（lance Issue #6661）: https://github.com/lance-format/lance/issues/6661
- 「ハイブリッドで必ず上がるわけではない」実測（Ahogrammer）: https://hironsan.hatenablog.com/entry/improving-performance-of-hybrid-search
- BM25×ベクトル×RRF実装ガイド（2026年版）: https://renue.co.jp/posts/hybrid-search-bm25-vector-rrf-rag-guide-2026

### チャンキング
- チャンキング戦略6選（2026-02-09, 512tok+10-25%オーバーラップ基準）: https://blog.usize-tech.com/rag-guide-1-chunking-strategy/
- Azure RAGチャンキングフェーズ: https://learn.microsoft.com/ja-jp/azure/architecture/ai-ml/guide/rag/rag-chunking-phase
- 日本語RAG・形態素解析/セマンティックチャンキング実装戦略: https://media.tcdigital.jp/ai-knowledge-flow/articles/japanese-rag-semantic-chunking/
- 契約書=条文単位分割の推奨・階層/メタデータ設計: https://arpable.com/artificial-intelligence/rag-chunking-optimization/ / https://de-stk.ae/archives/506

### クエリ変換・評価
- AutoHyDE/クエリ拡張/分解の概念比較（Nulab, 2026-05-14）: https://nulab.com/ja/blog/nulab/rag-query-techniques-autohyde-comparison/
- HyDE検証（Ahogrammer）: https://hironsan.hatenablog.com/entry/information-retrieval-with-hyde
- RAG評価用QAデータセット自動生成（NTTデータ, NLP2025）: https://www.anlp.jp/proceedings/annual_meeting/2025/pdf_dir/A3-3.pdf
- Ragas日本語QA生成の問題と回避（朝日新聞M研）: https://note.com/asahi_ictrad/n/nd849f8bf34fb
- JMTEB構築記事（SB Intuitions, 2024-05）: https://www.sbintuitions.co.jp/blog/entry/2024/05/16/130848

---
*本レポートはWeb公開情報に基づく。ベンチマーク数値は各出典の測定条件下の値であり、規程・契約書ドメインでの絶対値を保証しない。git commitは行っていない。*
