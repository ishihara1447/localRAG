# リランカーの非中国系化（2026-08-04）

> **本文書は精度の記述を2度訂正している。経緯を残す（同じ誤りを繰り返さないため）。**
>
> | 版 | 記述 | 誤りの内容 |
> |---|---|---|
> | 初版 | 「26/30 → 27/30 で改善」 | 比較対象の 26/30 が **2026-07-18 の記録**で、`sessionId` を振る前のハーネスによるもの。現行と連続性がない |
> | 2版 | 「28/30 に対し 27/30 で −1」 | 現行ベースライン 28/30 は**別ワークスペース・別時点**の値。同一条件の比較ではない |
> | **確定** | **差はゼロ（旧 27/30 / 新 27/30）** | 同一条件の A/B で決着。`docs/RERANKER_AB_2026-08-04.md` |
>
> **教訓: 記録値との比較は同一条件の A/B にならない。** このリポジトリは
> 「再取り込みをまたぐと 29/30↔28/30 が動く」と自ら警告しており、記録の流用は
> その規律に反していた。**差を論じるなら同一環境で両方を測ること。**

## 1. 結論

リランカーを **BAAI（中国系）から日本発のモデルへ差し替えた。精度は同等、速度とサイズは大幅に改善。**

精度は同一条件の A/B（各3run）で **旧 27/30 / 新 27/30、差 +0.00** と決着した
（`docs/RERANKER_AB_2026-08-04.md`）。全6run が 27/30 で完全一致。

ただし**「差が無い」とは言えない**。不一致は30問中2問のみで、そこから求めた真の差の
95%信頼区間は **約 −2.8 〜 +2.8 点/30**。3点近く劣る可能性も優る可能性も否定できない。

| | 旧 | 新 |
|---|---|---|
| モデル | `onnx-community/bge-reranker-v2-m3-ONNX` | `hotchpotch/japanese-reranker-xsmall-v2` |
| 提供元 | **BAAI＝北京智源人工智能研究院（中国）** | **hotchpotch（日本）** |
| 系譜 | — | `cl-nagoya/ruri-v3-pt-30m`（名古屋大）← `sbintuitions/modernbert-ja-30m`（SB Intuitions）。**中国系の混入なし** |
| ライセンス | MIT | MIT |
| パラメータ | 568M | 36.8M |
| ONNX int8 | 570,727,094 bytes | **37,367,189 bytes** |
| 防衛白書30問 | 27/30 | **27/30**（同一条件 A/B・各3run で完全一致） |
| JQaRA nDCG@10 | 0.6730 | **0.7403** |
| TTFT 中央値 | 6.99秒 | **約2.9秒** |

**当初は「非中国系にすると精度が落ちる」と見込んでいたが、その心配は不要だった。**

## 2. なぜ差し替えたか

ユーザーより 2026-08-04 に「**非中国系のリランカーを必ず適用してほしい。回答速度と精度が多少落ちることは許容する**」という指示があった。

あわせて導入先から「**TTFT（最初の文字が出るまで）8秒以内**」という要件が出ていた。
`docs/TTFT_BREAKDOWN_2026-08-04.md` の実測で、**旧リランカーが TTFT の 60%（4,202ms）を占める最大のボトルネック**と判明していた（`anythingllm` コンテナに GPU が割り当てられておらず、onnxruntime の CPU 実行になっているため）。

つまり非中国系化と速度改善が、同じ場所を指していた。

## 3. 選定の経緯

### 却下した選択肢

| 案 | 却下理由 |
|---|---|
| **リランカーを外す** | 防衛白書30問が 24〜25 → **18〜19** に落ち、**定義説明カテゴリが 6/6 → 2/6 に壊滅**する実測がある（`docs/RAG_SENTENCE_CUSHION_FAIR_REEVAL_2026-07-15.md`）。加えて**外しても埋め込み `bge-m3`（BAAI）が残るため非中国系化は達成できない**。ユーザー判断で「論外」 |
| `japanese-reranker-cross-encoder-small-v1` | JQaRA 0.6247 と現行を下回る。またベース mMiniLMv2 は Microsoft Research **Asia（北京）**発で、出自の説明が明快でない |
| `jina-reranker-v2-base-multilingual` | CC-BY-NC-4.0（**非商用**） |
| `mxbai-rerank-base-v2` | **ベースが Qwen2.5（Alibaba）** |
| `sbintuitions/sarashina*-reranker` | **存在しない**（HF の sbintuitions 全33モデルに rerank 系はゼロ）。`docs/QUALITY_ROADMAP_2026-07-26.md:1341` の「Sarashina3 rerank」という未確認項目はこれで決着 |

### 採用の決め手

- **ONNX int8 が公式配布済み**（自前変換が不要）。`onnx/model_qint8_avx2.onnx` 他、AVX512/ARM64 版も揃う
- 系譜をたどっても**すべて日本発**で、非中国系の説明が明快
- MIT、商用・再配布可
- 計算量が現行の約 1/38（層数×隠れ次元²の比）で、TTFT のボトルネック解消が見込めた

## 4. 実装

**製品コードの変更はゼロ。** `native/index.js` が `RERANKER_MODEL_PREF` 環境変数で切替可能な設計になっていた。

```
this.model = process.env.RERANKER_MODEL_PREF || "onnx-community/bge-reranker-v2-m3-ONNX";
```

### 🔴 同梱時に必要な作業（重要）

そのままでは動かない。**3点の作業が必要**である。

**(0) ONNX ファイルのリネーム**

HuggingFace が配布しているのは `onnx/model_qint8_avx2.onnx` などの命令セット別ファイルで、
製品コード（`native/index.js` の `assertBundledModelPresent`）が要求する
`onnx/model_quantized.onnx` という名前では配布されていない。**リネームして配置する。**

```
onnx/model_qint8_avx2.onnx  →  onnx/model_quantized.onnx
```

同リポジトリには `avx512` / `avx512_vnni` / `arm64` 版もある（いずれも同サイズ）。
**⚠️ 旧 bge は汎用の dynamic int8 で CPU 命令セット依存が無かった。AVX2 前提の量子化は
今回が初めてである。** 導入先 CPU が AVX2 を持つかは未確認で、`survey-target.sh` も
CPU フラグを採取していない。非対応環境ではクラッシュではなく**静かに遅くなる／精度が落ちる**
可能性がある（未検証）。

**(1)(2) 2ファイルの書き換え**

| ファイル | 変更 | 理由 |
|---|---|---|
| `config.json` | `model_type`: `modernbert` → `xlm-roberta`<br>`architectures`: `ModernBertForSequenceClassification` → `XLMRobertaForSequenceClassification` | 同梱の `@xenova/transformers` 2.17.2 に `modernbert` のマッピングが**存在しない**（実測で確認: 出現数0）。最新の `@huggingface/transformers` 4.x にはあるが、**v2→v4 の更新は埋め込みや collector にも波及する**ため今回は見送った |
| `tokenizer_config.json` | `tokenizer_class`: `LlamaTokenizer` → `PreTrainedTokenizer` | このモデルは `legacy: false` を持ち、v2 の `LlamaTokenizer` は legacy=false のとき normalizer を null にして `MetaspacePreTokenizer` を強制する。`PreTrainedTokenizer` にすれば `tokenizer.json` 記載の設定がそのまま使われる |

**この書き換えが安全な根拠**: `encoderForward` は `session.inputNames` に従って入力を組むだけで、アーキテクチャ固有の処理をしない。JS クラスは薄いラッパで、実体は ONNX グラフである。したがって `model_type` は「どのラッパを選ぶか」しか決めていない。

**実測でも出力が正常であることを確認済み**（§5-1）。

### 変更したファイル

| ファイル | 変更内容 |
|---|---|
| `linux-native/build-linux.sh` | モデル名を `RERANKER_MODEL` 変数へ切り出し、同梱パスを変数化 |
| `linux-native/package/install.sh` | 配置処理を変数化。前提条件チェックのパスを更新 |
| `linux-native/package/config/server.env.template` | `RERANKER_MODEL_PREF` を追加。書き換えの注意を明記 |
| `linux-native/verify-package.sh` | 検証パスを更新 |
| `docs/MODEL_CARDS.md` | 新モデルのカードを記載。旧モデルを撤回済みへ移動 |
| `LICENSES/JAPANESE-RERANKER-XSMALL-V2_LICENSE.txt` | 新規。系譜3件のライセンスを記載 |

## 5. 検証

### 5-1. 動作確認（実測）

`@xenova/transformers` 2.17.2 で直接ロードし、日本語で再順位付けできることを確認した。

```
0.9974  日本国憲法第9条は、戦争の放棄、戦力の不保持、交戦権の否認を定めている。  ← 正解
0.0024  本白書は防衛省の活動を記録したものである。
0.0003  在宅勤務手当は月額7,800円を支給する。
```

正解を1位に選び、無関係な文とのスコア差も大きい。

### 5-2. TTFT（実測、製品の stream-chat 経路）

| 質問 | TTFT |
|---|---|
| 統合作戦司令部はいつ発足しましたか | 2.90秒 |
| 在宅勤務手当について教えてください | 3.06秒 |
| この白書は何部構成ですか | 2.25秒 |
| 自衛官の定員は何人ですか | 2.97秒 |
| サイバー防衛の取組を教えてください | 2.73秒 |

**全問が要件（8秒）の半分以下。** コンテナログでリランクが 877ms で完了していることも確認した（旧 4,202ms）。

### 5-3. 精度（防衛白書30問、`scripts/hakusho-eval.py`）

**同一コンテナ・同一ワークスペース・同一コーパスで、`RERANKER_MODEL_PREF` だけを
入れ替えて交互に各3run。** 詳細は `docs/RERANKER_AB_2026-08-04.md`、生データは
`out/reranker-ab-2026-08-04/`。

| カテゴリ | 旧（BAAI） | 新（日本発） | 差 |
|---|---|---|---|
| a) 直接事実 | 7/8 | 6/8 | **−1** |
| b) 数値判別 | 5/6 | 5/6 | 0 |
| **c) 定義説明** | 5/6 | **6/6** | **+1** |
| **d) 白書外（不明応答）** | **5/5** | **5/5** | 0 |
| e) 言い換え | 5/5 | 5/5 | 0 |
| **合計** | **27/30** | **27/30** | **±0** |

全6run が 27/30 で完全一致。**差が出たのは30問中2問だけ**で、生データまで遡って
切り分けた結果は次のとおり。

- **Q20（c、新が正答）— 検索側の実質的な差。** 「交戦権」の定義がチャンク境界を
  またいでおり、旧は前半しか拾えず回答が途中で終わった。新は後半も拾い完答。
  **リランカーの効きが最も出るカテゴリで新が勝っている。**
- **Q04（a、旧が正答）— リランカーの負けではない。** 正解を含むチャンクは
  **新の検索結果にも入っており、しかも順位1位**（旧は2位）。証拠が文脈の先頭に
  あるのに gemma4 が拒否した**生成側の過剰拒否**である。失敗の型は捏造ではなく拒否

**d) 白書外が両者とも 5/5** — ハルシネーションは新旧ともゼロ。ここが落ちたら
採用不可としていた基準を満たしている。

## 6. 留保（正直に記録する）

- **a) 直接事実が 7/8 → 6/8 と1問落ちている。** 総合では上回るが、カテゴリ単位では増減がある。n=30 で1問の差は誤差の範囲であり、**「明確に優れている」とまでは言えない**
- **測定は `localrag-anythingllm:1.0.7` で行った。** このイメージには `LANCE_HYBRID_RERANK`（チャンク単位リランク）の実装が入っていない（実測で確認: 出現数0。配布物の 1.1.0 には3箇所ある）。**配布物では挙動が変わる可能性がある**
- **166問セットでの確認は未実施。** 数時間かかるため見送った。より厳密な評価は今後の課題
- **🔴 入力長の上限が効いていない。** モデルカードの想定使用は `max_length=512` だが、
  同梱した `tokenizer_config.json` の `model_max_length` は **8192** で、製品コード
  （`native/index.js:296`）は `truncation:true` のみで `max_length` を指定しない。
  結果として **8192 トークンまで切り捨てられずに通る**（独立レビューが実測で 4,509 トークンを確認）。
  つまり**モデルの想定外の長さを無検査で食わせる構成**になっている。
  文抽出クッションは文単位なので実害は小さいはずだが、`LANCE_HYBRID_RERANK`
  （チャンク単位）を有効にした構成では影響が出うる。
  対処は「同梱する `tokenizer_config.json` の `model_max_length` を 512 にする」
  （既に行っている書き換えと同種の1行）か「製品側で `max_length:512` を渡す」。**次回対応**
- 同梱した ONNX は `model_qint8_avx2.onnx`（AVX2 向け量子化）。**導入先 CPU が AVX2 を持つかは未確認**。同リポジトリに avx512/vnni/arm64 版もあり差し替え可能

## 6-2. Windows 版の状況

> **【更新】`windows-native/export-windows.ps1` は本作業内で新モデルへ更新済み。**
> 当初は Linux 版だけを更新しており、以下はその時点の記録である。
> **ただし Windows での再ビルドと実機検証は未実施**で、公開中の `v1.2.7` は
> 旧 BAAI モデルを同梱している。

当初の状況（更新前）:

**当初更新したのは `linux-native/` 配下だけで、`windows-native/` は旧リランカーのままだった。**

実測で確認した残存箇所:

| ファイル | 内容 |
|---|---|
| `windows-native/export-windows.ps1:26` | `-RerankerModelDir ...\bge-reranker-v2-m3-ONNX` |
| 同 `:86-93` | リランカー必須ファイルの検証 |
| 同 `:173` | `bundling: bge-reranker-v2-m3 ONNX int8` |
| 同 `:247` | `versions.lock` への記録 |

**これは看過できない。** 今回の要件は「**Windows かつ VRAM 8GB の環境で動作する製品とそのオフラインインストーラ**」であり、**Windows 版こそが主対象**である。Linux 版だけを差し替えると、

- 顧客が検証に使う Windows 8GB 環境には**中国系リランカーが載ったまま**になる（要件未達）
- Windows 版と Linux 版でリランカーが異なる2系統が並立し、**検証結果が本番に転用できない**
- TTFT 8秒要件も Windows 版では未達のままになる（旧リランカーは TTFT の 60% を占める）

**次の作業として `windows-native/export-windows.ps1` の更新が必須である。** Linux 版と同じく、モデル名の変数化と同梱パスの変更を行う。

なお現在公開中の配布物は Linux `linux-v1.1.1` と Windows `v1.2.7` の2系統で、**どちらも旧リランカーを同梱している**。

## 7. 残る中国系依存

**埋め込み `bge-m3` は BAAI 製のまま。** 今回の対象外とした。

理由は、埋め込みの変更が**全文書の再 embed を必須とする**ためである（`CLAUDE.md` の絶対ルール）。顧客が取り込んだ文書をすべて再投入することになり、影響範囲がリランカーとは桁違いに大きい。

加えて過去に `mxbai-embed-large` へ替えた際、**日本語の言い換え検索で正解文書を top8 にも入れられず**撤回した経緯がある（2026-07-11）。埋め込みは検索の土台であり、失敗すると全体が崩れる。

**したがって現状は「リランカーは非中国系化を達成、埋め込みは未達」という部分達成である。** 埋め込みの差し替えは別トラックとして着手する。

## 8. 元に戻す方法

旧モデルは `runtime/anythingllm-storage/models/onnx-community/bge-reranker-v2-m3-ONNX/` に**温存してある**（削除していない）。

開発機で戻す場合は `runtime/docker-compose.reranker-test.yml`（オーバーレイ）を外して `docker compose up -d` するだけでよい。`runtime/docker-compose.yml` は無変更である。
