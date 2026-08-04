# OTE-RAG TTFT（最初の文字が出るまでの時間）内訳の実測 — 2026-08-04

対象: 導入先要件「**1問あたり TTFT 8秒以内**」に対する現行構成の実力と、その内訳。

> 🔴 **本文書の結論は、同日のリランカー差し替えによって現行構成には当てはまらない。**
> 本測定は 2026-08-04 の**差し替え前**の構成（`onnx-community/bge-reranker-v2-m3-ONNX`）で行った。
> 差し替え後は、下記でボトルネックと特定した⑤が**中央値 約4,400ms → 約500ms** になっている
> （`out/reranker-ab-2026-08-04/AGGREGATE.txt`）。したがって §1 の「p90 11.56秒で要件未達」も、
> §5 の打ち手とその優先順位も、**そのままでは現行構成の評価として読んではならない**。
> なお §5 の打ち手表には「リランカー自体を小さいモデルに替える」が載っておらず、
> 実際に採用したのはこの表のどれでもない。
> **差し替え後の TTFT は、同一の24問で測り直していない**（未実施の残作業）。
> 生データと測定スクリプトは `out/ttft-2026-08-04/` にある。

---

## 1. 結論

- **TTFT の中央値は 6.99 秒、p90 は 11.56 秒、最大 14.26 秒**（現行既定 topN=8・文抽出クッションON、n=24、防衛白書544ページ）。
- **8秒要件は「中央値では満たすが p90 では満たさない」。24問中 14問（58%）しか 8秒以内に入らない。**
- **ボトルネックは⑤の文抽出クッション（bge-reranker-v2-m3 を CPU で実行）で、TTFT 中央値の 60.1%（4,202ms）を占める。** ①〜④＋⑥（埋め込み・ベクトル検索・BM25・RRF・プロンプト構築）は合計でも約 180ms（2.5%）にすぎない。
- **⑦（LLM 側）は中央値 2,251ms（32.2%）で、Ollama 実測の prompt eval は 966ms。小さい LLM に替えても縮むのは高々 1〜2 秒で、単独では要件に届かない。**
- 実測した緩和策: **topN=8→4 で TTFT 中央値 2.86秒・p90 3.47秒（24/24 が 8秒以内）**、**クッション OFF なら中央値 1.68秒・p90 1.82秒（24/24）**。ただし両方とも回答品質への影響は本測定では評価していない。

---

## 2. 測定方法

### 2-1. 経路

**製品の実経路（ストリーミング chat API）**を使った。評価スクリプト（`scripts/*-eval.py`）の
非ストリーミング `/chat` 経路ではない。

```
POST /api/v1/workspace/ttft-hakusho/stream-chat
  { "message": <質問>, "mode": "query", "sessionId": <設問ごとに一意> }
  → SSE を読み、最初の非空 textResponse が届いた時刻を TTFT とする
```

`sessionId` は設問ごとに一意にした（`docs/EVAL_HARNESS_FIXES_2026-07-26.md` の指摘どおり、
省略すると全問が既定セッションに積み上がり履歴が交絡するため）。

### 2-2. 段の切り分け方

**コンテナログのタイムスタンプでは段を切り分けられなかった。** 既存ログは
`sentence-cushion chunks 8 -> 5, sentences kept 23/44` のような
「その段が走ったこと」しか示さず、開始時刻を持たないためである。

そこで**稼働コンテナ内の製品コードに計測ログだけを差し込んだ**。挙動は変えていない
（`Date.now()` の取得と `console.log` の追加のみ。分岐・引数・戻り値は不変）。
差し込み先と対応する段:

| 段 | 差し込み先（コンテナ内パス） | 取得したキー |
|---|---|---|
| ① 埋め込み | `server/utils/vectorDbProviders/lance/index.js` `performSimilaritySearch` | `s1_embed_ms` |
| ② ベクトル検索 | 同 `hybridSimilarityResponse` | `s2_dense_ms` |
| ③ BM25 | 同上 | `s3_bm25_ms` |
| ④ RRF融合 | 同上 | `s4_rrf_ms` |
| ⑤ クッション | 同 `applySentenceCushion` 呼び出し | `s5_cushion_ms` |
| ⑥ プロンプト構築 | `server/utils/chats/apiChatHandler.js` `streamChat`（`chatPrompt`＋`compressMessages`） | `s6_prompt_build_ms` |
| ⑦ LLM | `server/utils/AiProviders/ollama/index.js` `handleStream` 最初の content チャンク | `s7_llm_to_first_token_ms` |
| ⑦内訳 | 同 `chunk.done` | `o_prompt_eval_ms` / `o_prompt_eval_count` / `o_load_ms` / `o_eval_ms` |

`global.__TTFT` に段ごとの所要を積み、最初のトークン到達時に `[TTFT_FIRST] {json}`、
完了時に `[TTFT_DONE] {json}` を1行 JSON で出力させた。`OLLAMA_NUM_PARALLEL=1` かつ
測定は直列実行なので、グローバル1本で混線しない。

**クライアント側 TTFT とサーバ内計測 TTFT の差は全問で 10ms 未満**だったので、
HTTP/SSE のオーバーヘッドは無視できる。以降 TTFT はクライアント実測値を使う。

### 2-3. 設問

`fixtures/complex/hakusho-complex-qa.json`（166問）から**等間隔に24問**を決定的に抽出
（`cases[0::6][:24]`＝Q01, Q07, Q13, Q021 … Q141）。カテゴリ C1〜C6 を横断する。
各条件で**測定前にウォームアップ1問**を捨てている（gemma4:12b の初回ロードは実測 49.5 秒かかり、
これを含めると計測がロード時間に支配されるため）。

### 2-4. 条件

| 条件 | topN | クッション | n |
|---|---:|---|---:|
| **A（製品既定）** | 8 | ON | 24 |
| B | 4 | ON | 24 |
| C | 8 | **OFF** | 24 |

共通: `chatMode=query` / `openAiTemp=0` / `similarityThreshold=0.25` / `vectorSearchMode=default` /
`LANCE_HYBRID_SEARCH=true` / `QUERY_REFORMULATION=true` / `OLLAMA_DISABLE_THINKING=true`。
条件 C のみ `LANCE_SENTENCE_CUSHION=false` を compose override で与えた（リポジトリの
`runtime/docker-compose.yml` は変更していない）。

### 2-5. 測定環境

- ホスト: WSL2 Ubuntu / Intel Core Ultra 7 265KF（20コア）/ RAM 31GB / **RTX 5070 Ti 16GB**（driver 591.86）
- コンテナ: `localrag-anythingllm:1.0.7`（image作成 2026-07-23）＋ `ollama/ollama:latest`（v0.30.11）
- モデル: LLM `gemma4:12b` / Embedding `bge-m3:latest` / Reranker `bge-reranker-v2-m3` ONNX int8
- 文書: `R07zenpen.pdf`（令和7年版 防衛白書、66MB、544ページ）1本
- ワークスペース: `ttft-hakusho`（新規作成。ベースライン166 の `5ec7ec63-…` とは**別**）

> **⚠️ リランカーはコンテナから GPU が見えない。** `runtime/docker-compose.yml` で
> NVIDIA デバイスを予約しているのは `ollama` サービスだけで、`anythingllm` コンテナ内に
> `/dev/nvidia*` は存在しない。したがって⑤のクロスエンコーダは **CPU の onnxruntime** で走る。
> これが⑤が支配的である直接の理由である。

---

## 3. 内訳の実測値

### 3-1. 条件A（製品既定: topN=8 / クッションON）— n=24

| 段 | 中央値 | p90 | 最大 | 最小 | TTFT中央値に占める割合 |
|---|---:|---:|---:|---:|---:|
| チャット履歴読み出し | 1 ms | 2 | 2 | 0 | 0.0% |
| LanceDB 接続・存在確認 | 1 ms | 1 | 3 | 0 | 0.0% |
| **① 埋め込み（bge-m3）** | **113 ms** | 139 | 186 | 103 | 1.6% |
| **② ベクトル検索（dense）** | **8 ms** | 9 | 21 | 4 | 0.1% |
| **③ BM25（LanceDB FTS）** | **24 ms** | 52 | 81 | 14 | 0.3% |
| **④ RRF融合** | **0 ms** | 0 | 0 | 0 | 0.0% |
| **⑤ リランク（文抽出クッション）** | **4,202 ms** | **6,262** | **7,981** | 2,435 | **60.1%** |
| P1 言い換え再検索 | 0 ms | 0 | 0 | 0 | 0.0% |
| fillSourceWindow | 0 ms | 0 | 0 | 0 | 0.0% |
| **⑥ プロンプト構築** | **34 ms** | 47 | 166 | 25 | 0.5% |
| **⑦ LLM呼出→最初のトークン** | **2,251 ms** | **6,733** | **8,378** | 1,230 | **32.2%** |
| **TTFT 合計** | **6,986 ms** | **11,551** | **14,249** | 4,308 | 100% |

※ **中央値は加法的でない**。各段の中央値を足すと 6,634ms になるが、これは「TTFT 合計」の
中央値 6,986ms とは一致しない（段ごとに中央値をとる問が違うため）。割合はいずれも
実測の TTFT 合計中央値 6,986ms を分母にしている。

⑦の内側（Ollama が自己申告する値、n=24）:

| 項目 | 中央値 | p90 | 最大 |
|---|---:|---:|---:|
| `load_duration`（モデル常駐確認） | 234 ms | 294 | 329 |
| **`prompt_eval_duration`（＝⑦の prompt eval）** | **966 ms** | 1,305 | 2,321 |
| `prompt_eval_count` | 2,108 tok | 2,434 | 2,658 |
| `eval_duration`（全生成。TTFT には含まれない） | 2,676 ms | 5,480 | 8,517 |
| `eval_count` | 193 tok | 395 | 611 |

参考（TTFT ではない値）:

| 項目 | 中央値 | p90 | 最大 |
|---|---:|---:|---:|
| 総所要時間（回答が出揃うまで） | 10.60 s | 16.02 | 18.23 |
| 回答文字数 | 340 字 | 671 | 984 |
| プロンプト文字数 | 3,530 字 | 4,021 | 4,411 |
| 文脈チャンク数 | 7 | 7 | 8 |

**8秒以内に入ったのは 14/24（58%）。**

### 3-2. 条件B（topN=4 / クッションON）— n=24

| 段 | 中央値 | p90 | 最大 | 最小 |
|---|---:|---:|---:|---:|
| ① 埋め込み | 102 ms | 107 | 131 | 99 |
| ② dense | 5 ms | 11 | 27 | 3 |
| ③ BM25 | 13 ms | 20 | 25 | 10 |
| ④ RRF | 0 ms | 0 | 1 | 0 |
| **⑤ クッション** | **1,506 ms** | 2,240 | 2,456 | 695 |
| ⑥ プロンプト構築 | 24 ms | 29 | 36 | 17 |
| **⑦ LLM→最初のトークン** | **1,132 ms** | 1,273 | 1,488 | 779 |
| **TTFT 合計** | **2,857 ms** | **3,461** | **3,784** | 1,624 |

Ollama `prompt_eval_duration` 中央値 491ms / `prompt_eval_count` 1,708 tok。
プロンプト文字数 中央値 2,887字。総所要 中央値 5.62s。**8秒以内 24/24（100%）。**

### 3-3. 条件C（topN=8 / クッションOFF）— n=24

| 段 | 中央値 | p90 | 最大 | 最小 |
|---|---:|---:|---:|---:|
| ① 埋め込み | 101 ms | 107 | 118 | 97 |
| ② dense | 6 ms | 8 | 10 | 5 |
| ③ BM25 | 16 ms | 25 | 29 | 10 |
| ④ RRF | 0 ms | 1 | 1 | 0 |
| **⑤ クッション** | **0 ms**（無効） | 0 | 0 | 0 |
| ⑥ プロンプト構築 | 32 ms | 41 | 42 | 28 |
| **⑦ LLM→最初のトークン** | **1,510 ms** | 1,639 | 1,673 | 1,353 |
| **TTFT 合計** | **1,670 ms** | **1,813** | **1,857** | 1,518 |

Ollama `prompt_eval_duration` 中央値 844ms / `prompt_eval_count` **3,746 tok**（Aの1.8倍）。
プロンプト文字数 中央値 6,456字。総所要 中央値 4.72s。**8秒以内 24/24（100%）。**

### 3-4. 3条件の比較（TTFT）

| 条件 | 中央値 | p90 | 最大 | 8秒以内 |
|---|---:|---:|---:|---:|
| **A: topN=8 / クッションON（製品既定）** | **6.99 s** | **11.56 s** | 14.26 s | **14/24（58%）** |
| B: topN=4 / クッションON | 2.86 s | 3.47 s | 3.79 s | 24/24（100%） |
| C: topN=8 / クッションOFF | 1.68 s | 1.82 s | 1.87 s | 24/24（100%） |

### 3-5. 観察: クッションは⑦のばらつきも増やしている

条件C（プロンプト 3,746 tok）の⑦が中央値 1,510ms・p90 1,639ms なのに対し、
条件A（プロンプト **2,108 tok** ＝より短い）の⑦は中央値 2,251ms・**p90 6,733ms**である。
**文脈が短いほうが⑦が遅く、かつ p90 が 4 倍以上ばらつく。**

これは「文脈長が⑦を決める」という素朴な想定と逆である。観測事実として記録するが、
**機序は特定していない**。CPU を飽和させる ONNX 推論の直後に LLM リクエストを出すため
（Node のイベントループ・onnxruntime のワーカースレッド後始末・Ollama サーバとの CPU 競合）
という仮説は立つが、本測定では切り分けていない。

### 3-6. 観察: Ollama の申告値は⑦を全部は説明しない

条件Aで⑦＝2,251ms に対し Ollama の `load_duration` 234ms ＋ `prompt_eval_duration` 966ms
＝ 1,200ms しか説明されず、約 1.0 秒が未計上である（条件Cでは約 0.44 秒）。

Ollama を直接叩く切り分け（AnythingLLM を介さず `/api/chat` を呼ぶ）でも同じ差が出た。
新規プロンプト 1,865 tok で実測 wall（最初のトークンまで）1.6〜3.4秒に対し
`prompt_eval_duration` は 0.5〜0.7秒。**Ollama 0.30.11 が `prompt_eval_duration` に
含めていない内部処理が存在する**と考えられるが、**その中身は特定していない。**
なお同一プロンプトの2回目は wall 0.25 秒まで落ちる（プロンプトキャッシュ）。

---

## 4. 8秒要件に対する評価

| 指標 | 現行（条件A） | 8秒要件 | 判定 |
|---|---:|---:|---|
| TTFT 中央値 | 6.99 s | ≤ 8 s | **満たす**（余裕 1.0 s） |
| TTFT p90 | 11.56 s | ≤ 8 s | **満たさない**（超過 3.6 s） |
| TTFT 最大 | 14.26 s | ≤ 8 s | **満たさない**（超過 6.3 s） |
| 8秒以内の割合 | 58%（14/24） | — | — |

**「中央値では通るが、体感の 4 割強が要件を割る」**という状態である。
要件が「1問あたり」＝各問が守るべき上限、という読み方であれば**現行構成は要件を満たしていない**。

超過分の出所は明確で、**p90 で 8秒を 3.6秒超過しているうち、⑤クッション単独が p90 6.26秒**を
占める。**段ごとの p90 は足せない**（p90 は加法的でなく、各段の p90 が同じ問で起きるとは限らない）
ため「⑤を何秒に抑えれば 8 秒に入る」という引き算は成り立たない。言えるのは
**p90 の内訳でも⑤と⑦が支配的で、この2つを同時に見ないと要件には届かない**ということまでである。

n=24 のため p90 は上位 2〜3 問で決まっており、**p90 の点推定は粗い**。
中央値の判定（6.99秒 vs 8秒、余裕1秒）も n=24 では確定的ではない。

---

## 5. 打ち手の候補

効果はすべて **TTFT 中央値 / p90** に対する値。品質（回答正答率）への影響は本測定の範囲外。

| # | 打ち手 | TTFT への効果 | 根拠 | リスク |
|---|---|---|---|---|
| **1** | **topN 8 → 4** | 中央値 6.99→**2.86s**（−59%）／ p90 11.56→**3.47s**（−70%）／ 24/24 が8秒以内 | **実測（条件B）** | 品質影響が未解決。retrieval 側は `docs/BASELINE_166Q_2026-07-28.md` で **anchor_Coverage@4 = 0.710 vs @8 = 0.712**（All-Hit はどちらも 0.473）と**ほぼ同一**だが、generation 側は S07 の topN=8 vs 4 が δ=6.3pt・p=0.18（n=79要素）で**検出力不足のまま未決着**。166問セットなら κ=1.8 前提で 2.2pt まで検出できるので、**再測定すれば決着がつく** |
| **2** | **⑤クッションを軽量化**（全文スコアリングをやめ、上位 M チャンクのみ／文数に上限） | 上限として 中央値 6.99→**1.68s**、p90 →**1.82s**（＝クッション完全OFF、条件C）。部分適用ならこの間 | **完全OFF は実測（条件C）。部分適用は推定** | クッションは `docs/RAG_SENTENCE_CUSHION_FAIR_REEVAL_2026-07-15.md` で **hakusho 30問 18〜19 → 24〜25（+6〜7点）、c)定義カテゴリ 2/6→6/6** と記録された**製品の主要な品質資産**。単純 OFF は品質後退が大きい。M チャンク限定なら実装変更が要る（`sentenceCushion.js` は現状 topN 全チャンクの全文を `topK: sentences.length` でスコアリングしている） |
| **3** | **⑤リランカーを GPU で回す**（`anythingllm` コンテナにも NVIDIA デバイスを渡し onnxruntime の GPU EP を使う） | 推定。⑤が数百 ms 台まで落ちれば TTFT 中央値 3秒前後・p90 も 8秒内に収まる見込み | **未実測** | GPU が LLM と競合し VRAM を食う（gemma4:12b が実測 8.37GB／16GB、`OLLAMA_NUM_PARALLEL=1` はすでに VRAM 制約で決めた値）。onnxruntime-node の GPU EP 導入は image 再ビルドが必要で、`docs/HANDOFF.md` の「Dockerfile が入手できない」課題に直撃する |
| **4** | **⑤リランカーのスレッド数・バッチを調整**（CPU 20コアを使い切る） | 推定。現状 CPU 何スレッドで回っているか未確認 | **未実測** | 効果が読めない。ただし image 再ビルド不要で環境変数だけで試せる可能性があり、**検証コストが最も安い** |
| **5** | LLM をより小さいモデルに替える | 中央値で高々 **−1〜2秒**（⑦は中央値 2.25s、うち prompt eval 966ms）。p90 では⑦が 6.7秒なので効く余地は大きいが、⑦の p90 悪化は §3-5 のとおり文脈長ではなく⑤との相互作用が疑われ、**モデル変更で解消する保証がない** | ⑦の実測値からの推定 | 品質後退（gemma4:12b は空回答・捏造の実績を潰して選定された経緯がある）。**単独では要件に届かない**ため、優先度は低い |
| **6** | 文脈長の削減（⑥⑦向け） | **効果は小さい。** プロンプト 6,456字/3,746tok（条件C）でも⑦は 1,510ms、2,887字/1,708tok（条件B）で 1,132ms。**約2倍の文脈長差で⑦は 0.4秒しか違わない** | 実測（条件B/Cの比較） | — |

### 推奨する順番

1. **打ち手4（リランカーのスレッド調整）を先に試す** — image 再ビルド不要・可逆・品質不変。
2. **打ち手1（topN=4）の品質を 166問セットで再測定する** — 効果は実測済みで大きく、
   retrieval 指標は @4≈@8 なので**通る見込みがある**。generation 側の決着だけが残っている。
3. 上記で足りなければ **打ち手2（クッションの部分適用）**。品質とのトレードオフを
   実測しながら M を決める。
4. **打ち手5（LLM 差し替え）は最後**。⑦は TTFT の 32% しかなく、単独では要件に届かない。

> **「⑦（生成側）が支配的なら小さい LLM に替える」という当初の仮説は、実測により棄却される。**
> 支配的なのは⑤（検索側の CPU リランク）である。

---

## 6. 実測したこと / 推定にとどまること

### 実測した（このセッションで測った数値）

- 条件A/B/C それぞれ n=24 の TTFT と①〜⑦の段別所要（§3-1〜3-4）
- Ollama の `prompt_eval_duration` / `prompt_eval_count` / `load_duration` / `eval_duration`
- クライアント側 TTFT とサーバ内 TTFT の差が 10ms 未満であること
- `anythingllm` コンテナに `/dev/nvidia*` が存在せず、リランカーが CPU で走ること
- Ollama を直接叩いたときの「新規プロンプト vs キャッシュ済みプロンプト」の差（1.6〜3.4s vs 0.25s）
- 稼働イメージ `localrag-anythingllm:1.0.7` に **`LANCE_HYBRID_RERANK` の実装が入っていない**こと（§7）

### 推定・未確認（断定しない）

- **打ち手3（GPU リランク）・打ち手4（スレッド調整）の効果は一切測っていない。** 推定である。
- **クッションの部分適用（上位 M チャンクのみ）の効果は測っていない。** 完全OFF（条件C）が上限を与えるだけである。
- **⑦の p90 が条件Aで 6.7秒に膨らむ機序は特定していない**（§3-5）。CPU 競合の仮説は検証していない。
- **Ollama の `prompt_eval_duration` に計上されない約 0.4〜1.0 秒の中身は特定していない**（§3-6）。
- **品質（正答率）は一切測っていない。** topN=4 もクッション部分適用も、本測定は速度のみである。
- p90 は n=24 の上位2〜3問で決まるため**点推定として粗い**。条件間の大小関係（A ≫ B > C）は
  差が大きく順序は堅いが、各値の精度は主張しない。
- 総所要時間の中央値は条件Aで 10.60 秒で、**保存済みベースライン `out/baseline166/base166-gen-run1.json`
  の 14.25 秒と一致しない**。設問数（24 vs 166）・設問の内訳・ワークスペース・実行日が異なるため
  直接比較できない。**どちらが正しいかは判定していない。**

---

## 7. 環境復旧で行ったこと

### 復旧した

| 項目 | 内容 |
|---|---|
| コンテナ | `runtime/docker-compose.yml` で `rag-ollama` / `anythingllm` を起動（両方 Exited → healthy） |
| 白書 PDF | `/mnt/c/LocalRAGProd/fixtures/local/` から `fixtures/local/` へ **コピー**（`cp -n`、Windows 側は無変更）。`R07zenpen.pdf` / `prompt-tuned.txt` / `hakusho_eval_set_draft.md` の3点 |
| 取り込み | 製品経路で実施。`POST /api/v1/document/upload`（collector パース、23.5秒）→ `POST /api/v1/workspace/ttft-hakusho/update-embeddings`（bge-m3 で embed、3分30秒） |
| ワークスペース | **`ttft-hakusho` を新規作成**。`topN=8` / `chatMode=query` / `openAiTemp=0` / `similarityThreshold=0.25` |
| 埋め込みの健全性 | `GET /api/setup-complete` で **`EmbeddingEngine=ollama` / `EmbeddingModelPref=bge-m3:latest` / `EmbeddingBasePath=http://ollama:11434`** を確認。**オンボーディング画面は一度も開いていない**ので `docs/HANDOFF.md` 記載の P0（`EmbeddingEngine=native` 無条件送信）は踏んでいない |
| LanceDB | `runtime/anythingllm-storage/lancedb/` に `ttft-hakusho.lance` と `__oterag_fts__v2_ttft-hakusho.lance`（ハイブリッド検索の FTS sidecar）が生成されたことを確認 |
| 動作確認 | 復旧後に `/chat` で「統合作戦司令部が新設されたのはいつですか」→「2025年3月24日」＋出典付きで正答（sources 6件） |

### 元通りでないもの

- 🔴 **`anythingllm.db` は再作成された**（起動時にゼロから生成）。**過去のチャット履歴・
  旧ワークスペース（ベースライン166が使った `5ec7ec63-b421-42dd-8610-54984f28abc2`）・
  API キーは失われたままで、復旧していない。** 本測定は新規ワークスペース上の結果である。
- 🔴 **稼働イメージ `localrag-anythingllm:1.0.7` には `LANCE_HYBRID_RERANK` の実装が無い。**
  `runtime/docker-compose.yml` は `LANCE_HYBRID_RERANK=true` を渡しているが、
  イメージ内の `lance/index.js` に `hybridRerankEnabled` が存在せず（`fused` は `limit: topN` で
  切り捨て）、**チャンク単位のクロスエンコーダ再順位付けは走っていない**。
  fork ソース（`anything-llm/`, 2026-07-27 更新）には実装があるので、
  **image が fork より古い**（image 作成 2026-07-23）。
  これは `docs/HANDOFF.md` に記録された「image 1.0.5 に hybrid/cushion 未搭載」と同型の乖離である。
  → **本測定の⑤は「文抽出クッションのみ」であり、チャンク単位リランクを含まない。**
  `docs/HYBRID_RERANK_2026-07-27.md` の「1問あたり中央値 約7秒 → 約12秒」という記録が正しければ、
  リランク搭載イメージでは TTFT はさらに悪化する見込みだが、**本測定では確認していない。**
- 白書以外の文書（`fixtures/scale/` の規程10本など）は取り込んでいない。
- ベースライン166 の再現（166問の実行）はしていない。

### 計測用に一時的に行い、元に戻したこと

測定のため、**稼働コンテナ内の製品コードにログだけを差し込んだ**（§2-2）。
`docker cp` で差し替えたので**リポジトリの `anything-llm/` ソースは無変更**である。
測定後に `docker compose up -d --force-recreate anythingllm` でイメージから作り直し、
**3ファイルとも `__TTFT` の出現数が 0 であること**（＝原本に戻ったこと）を確認済み。
`LANCE_SENTENCE_CUSHION=true`（製品既定）に戻っていることも確認した。

### 新規に作ったファイル

リポジトリ内:

- `docs/TTFT_BREAKDOWN_2026-08-04.md`（本ファイル）
- `fixtures/local/R07zenpen.pdf` / `prompt-tuned.txt` / `hakusho_eval_set_draft.md`
  （`/mnt/c/` からのコピー。`fixtures/local/` は `.gitignore` 除外対象）

作業用（スクラッチパッド `/tmp/claude-1000/…/scratchpad/`、リポジトリ外）:

| ファイル | 用途 |
|---|---|
| `patch_ttft.py` | コンテナ内製品コードへ計測ログを差し込むパッチャ |
| `orig/*.js` | コンテナから取り出した原本3ファイル |
| `patched/*.js` | 計測ログ入り3ファイル |
| `ttft_measure.py` | stream-chat 経路の TTFT 測定クライアント |
| `analyze.py` | 段別の中央値/p90/最大の集計 |
| `probe_ollama.js` / `probe2.js` / `probe3.js` | Ollama 直叩きの切り分け（§3-6） |
| `override-nocushion.yml` | 条件C 用の compose override |
| `ttft_topn8.json` / `ttft_topn4.json` / `ttft_nocushion_topn8.json` | 生の測定ログ（設問ごとの全段の値） |

`scripts/` と `fixtures/complex/` は読み取りのみで、既存ファイルは変更していない。
`linux-native/` `windows-native/` `dist-linux/` `runtime/docker-compose.yml` も無変更。
git の commit/push/stash/checkout は行っていない。

---

## 8. 再現手順

```bash
# 1. 起動
cd runtime && docker compose up -d

# 2. 白書の取り込み（API キーは POST /api/system/generate-api-key で取得）
curl -X POST localhost:3001/api/v1/workspace/new -H "Authorization: Bearer $K" \
  -H 'Content-Type: application/json' -d '{"name":"ttft-hakusho"}'
curl -X POST localhost:3001/api/v1/document/upload -H "Authorization: Bearer $K" \
  -F "file=@fixtures/local/R07zenpen.pdf"
curl -X POST localhost:3001/api/v1/workspace/ttft-hakusho/update-embeddings \
  -H "Authorization: Bearer $K" -H 'Content-Type: application/json' \
  -d '{"adds":["custom-documents/R07zenpen.pdf-<uuid>.json"]}'

# 3. 計測ログの差し込み（コンテナ内のみ。リポジトリは無変更）
python3 <scratchpad>/patch_ttft.py
docker cp <scratchpad>/patched/lance_index.js      anythingllm:/app/server/utils/vectorDbProviders/lance/index.js
docker cp <scratchpad>/patched/apiChatHandler.js   anythingllm:/app/server/utils/chats/apiChatHandler.js
docker cp <scratchpad>/patched/ollama_index.js     anythingllm:/app/server/utils/AiProviders/ollama/index.js
docker restart anythingllm

# 4. 測定と集計
python3 <scratchpad>/ttft_measure.py ttft-hakusho out.json 24 8
python3 <scratchpad>/analyze.py out.json

# 5. 復元（必須。イメージから作り直して計測ログを消す）
cd runtime && docker compose up -d --force-recreate anythingllm
docker exec anythingllm grep -c __TTFT /app/server/utils/chats/apiChatHandler.js   # → 0
```
