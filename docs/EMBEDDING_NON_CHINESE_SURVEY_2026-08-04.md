# 埋め込みモデルの非中国系化 — 調査結果と、着手前に必要な前提工事（2026-08-04）

## 1. 結論

**「Ollama 公式配布 ＋ 日本語で `bge-m3` と同等以上（公開データで断定可）＋ 商用可」を
すべて満たす候補は、現時点で存在しない。**

そして着手前に**製品コードの欠落を1つ埋める必要がある**（§3）。これを埋めずに評価すると、
どの候補も本来の性能が出ず、誤った結論に至る。

**したがって本件は着手を見送り、リランカーの差し替え（`docs/RERANKER_SWAP_2026-08-04.md`）を
先に完成させた。** 本文書は次に着手する際の出発点である。

## 2. 候補の状況

現行は `bge-m3`（BAAI＝北京智源人工智能研究院＝中国系、MIT、1024次元、VRAM 実測 0.58GB）。

| 候補 | 日本語性能 | Ollama公式 | ライセンス | 出自 | 判定 |
|---|---|---|---|---|---|
| `embeddinggemma:300m` | **評価が割れている**（JMTEB 58.10 / 検索 72.3、NanoBEIR-ja 0.5869） | ✅ | **Gemma Terms**（Apache-2.0 でない） | Google（米） | 第一候補。ただし要実測 |
| `cl-nagoya/ruri-v3-310m` | JMTEB 77.24。**ほぼ確実に現行超え** | ❌（コミュニティ GGUF は patched llama.cpp 必須） | Apache-2.0 | 名古屋大 ← SB Intuitions。**採用済みリランカーと同系譜** | 第二候補。ONNX 同梱なら可能性あり |
| `snowflake-arctic-embed2` | NanoBEIR-ja 0.5739 | ✅ | Apache-2.0 | Snowflake（米）**だがベースが `BAAI/bge-m3-retromae`** | ❌ 出自が要件に反する |
| `multilingual-e5-large` | JQaRA 0.554（現行 0.539 とほぼ同じ） | ❌ | MIT | **著者が MSR Asia（北京）** | ❌ リランカーで mMiniLMv2 を同理由で却下した基準に反する |
| `sarashina-embedding-v2-1b` | JMTEB 76.38 | ❌ | **非商用** | SB Intuitions（日） | ❌ |
| `granite-embedding` / `nomic-embed-text-v2-moe` | **日本語の公開データなし** | ✅ | Apache-2.0 | IBM / Nomic（米） | ダークホース。実測する価値はある |
| `qwen3-embedding` | — | ✅ | Apache-2.0 | Alibaba（中国） | ❌ |

**Ollama 公式の埋め込みは全12種あるが、日本語で現行を超える公開実測があるのは
`embeddinggemma` だけで、しかもその測定が割れている。**

## 3. 🔴 着手前に必要な前提工事: Ollama embedder の prefix 対応

**実測で確認した欠落**:

| ファイル | `embeddingPrefix` / `queryPrefix` の実装 |
|---|---|
| `server/utils/EmbeddingEngines/ollama/index.js` | **0 箇所（未実装）** |
| `server/utils/EmbeddingEngines/native/index.js` | 7 箇所（実装済み） |

一方、配線側は既に prefix を渡す準備ができている:

```
server/utils/vectorDbProviders/lance/index.js:663
        chunkPrefix: EmbedderEngine?.embeddingPrefix,
```

### なぜこれが致命的か

**候補のほぼ全部が prefix を前提に学習されている。**

| モデル | 必要な prefix |
|---|---|
| ruri 系 | `検索クエリ: ` / `検索文書: ` |
| embeddinggemma | `task: search result \| query: ` / `title: none \| text: ` |
| multilingual-e5 / GLuCoSE | `query: ` / `passage: ` |

**prefix 無しで評価すれば、どの候補も本来の性能を出さない。**
現行 `bge-m3` は prefix 不要なので、この欠落が今まで表面化していなかった。

### 過去の判断への影響

`mxbai-embed-large` を「日本語の言い換え検索で正解文書を top8 にも入れられない」として
2026-07-11 に撤回したが、**あの評価も prefix 無しで行われた可能性がある**。
再評価する価値があるかもしれない（未検証）。

### 必要な作業

`native/index.js` を手本に、`ollama/index.js` へ getter 2つと `embedTextInput` の
上書きを足す。**約15〜20行**。

## 4. 移行コストの実測値

### 開発機での再 embed → 障害にならない

防衛白書 544ページ = 1,756チャンク。実測は次のとおり（`docs/TTFT_BREAKDOWN_2026-08-04.md`）:

- collector パース: 23.5秒
- `bge-m3` での embed: **3分30秒**

パース結果は再利用できるので、モデル差し替え時の再 embed は**3分半のオーダー**。
評価を回すコストは問題にならない。

ただし ONNX/CPU 経路（native embedder）を採る場合、1,756チャンクを CPU で embed する
時間は**未知**。

### 顧客側 → ここが本当のコスト

- LanceDB の既存ベクトルは**全無効**。顧客は文書を再アップロードする必要がある
- **Linux 版 v1.1.1 が 2026-07-31 に公開済み**。既に導入があるなら移行手順書が必須
- 次元が 1024 → 768 に変わると LanceDB のスキーマも変わる。**テーブルの自動再作成が効くかは未確認**

### 実効コンテキスト長は 8,192 ではなく 500（重要）

`EMBEDDING_MODEL_MAX_CHUNK_LENGTH=500` が `runtime/docker-compose.yml:165` と
`linux-native/package/config/server.env.template:51` に設定されている。

つまり **`bge-m3` の 8,192 ctx は使っていない**。したがって ctx 2048 の
`embeddinggemma` でも十分であり、ctx 512 系も**おそらく足りる**（日本語500文字＋prefix が
512 トークンに収まるかは要実測）。

## 5. 推奨する段階戦略（次に着手する際）

**Step 0**: Ollama embedder に prefix 対応を入れる（約20行）。**これが最優先。**

**Step 1**: `embeddinggemma:300m` を防衛白書30問で実測。特に **(e) 言い換え 5問**を見る。
Ollama 公式配布という鉄則を満たす唯一の非中国系候補である。
ただしライセンスが Gemma Terms なので、`LICENSES/` と NOTICE に加えて
**顧客契約への条項組み込みが必要**になる点に注意。

**Step 2**: 不可なら `cl-nagoya/ruri-v3-310m` を ONNX で native embedder 経由で同梱。
リランカーと同じ方式で、**同じ ModernBERT-Ja 系・同じトークナイザ**なので
`config.json` の書き換え手法がそのまま効く可能性が高い。
ただし `ALLOWED_EMBEDDING_ENGINES` に `native` を戻す必要があり、CPU 実行になる。

**Step 3**: 両方だめなら現行維持。**「リランカーは達成、埋め込みは技術的制約により未達」と
明示的に記録する**のが誠実である。埋め込みは検索の土台であり、mxbai の前例どおり
劣化すれば製品全体が壊れる。

## 6. リスク

**最大のリスクは「ベンチマークの数値が言い換え耐性を保証しないこと」。**

JMTEB・JQaRA・NanoBEIR-ja はいずれも言い換え検索を直接測る指標ではない。
`mxbai` の失敗は、多言語対応を謳うモデルが自社30問で初めて露呈したものだった。
同じ構図は再現しうる。

**候補が JMTEB でどれだけ高くても、白書30問の (e) 言い換え 5問が落ちたら採用しない**、
という判断基準を先に決めておくべきである。

なお **`llm-jp` 型の全滅事故（コミュニティ GGUF のテンプレート破損で 30問中0問）は
埋め込みには構造的に起こらない**（埋め込みにチャットテンプレートは無い）。
埋め込みで起きるのは「静かな精度劣化」であり、評価で必ず検出できる。
この違いは重要で、「コミュニティ配布は一律禁止」を埋め込みにそのまま適用すると、
非中国系の選択肢をほぼ全部捨てることになる。

## 7. 実測が必要な項目

1. **防衛白書30問、特に (e) 言い換え 5問**（現行 27/30・言い換え 5/5 が基準）
2. 166問セット（30問では n が小さすぎる）
3. **prefix 有無の A/B**（実装後。mxbai の判断の再検証にもなる）
4. 日本語500文字＋prefix が候補の ctx に収まるか
5. VRAM 実測（8GB 環境で `gemma4:12b` と同居する。**余裕が無い**）
6. 再 embed 時間（Ollama/GPU と ONNX/CPU の両方）
7. 次元変更（1024→768）で LanceDB テーブルが自動再作成されるか
8. 同梱 Ollama v0.31.2 で `embeddinggemma` が動くか（要件 0.11.10 以上なので満たすはずだが未検証）
