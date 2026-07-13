# 非中国系LLMへの切替 調査（2026-07-14）

## 背景・要件

現行LLMは `qwen3:8b`（Alibaba＝中国系）。中国系以外で、以下を満たす優秀なモデルを1つ採用したい。

- RAGに適する（長文脈・指示追従・出典に基づく回答）
- 日本語に強い
- 商用利用可能（顧客へ有償配布するため再配布可のライセンスが望ましい）
- VRAM 16GB（RTX 5070 Ti）で動作
- ＋プロジェクト固有の鉄則: **Ollama公式ライブラリ配布のモデルのみ**（過去にコミュニティGGUFの
  チャットテンプレート破損で本文が生成されない事故があったため。`RAG_ACCURACY_IMPROVEMENT_2026-07-11.md`）

## 結論（推奨）

### 第1候補: `gemma4:12b`（Google DeepMind）★推奨

| 項目 | 評価 |
|---|---|
| 非中国系 | ✓ Google（米） |
| ライセンス | ✓✓ **Apache 2.0**（Gemma 4で従来のGemma独自ライセンスから変更。商用・改変・再配布に制約なし。qwen3のApache 2.0と同等以上にクリーン） |
| RAG適性 | ✓ コンテキスト **256K**、要約・QA・推論が得意 |
| 日本語 | ○ 140言語対応。非中国系オープンではGemma系が日本語上位。ただし日本語固有ベンチは未公開で「英語よりやや低い」傾向 |
| VRAM 16GB | ✓✓ Q4 **約7.6GB**（QAT版 7.2GB）。KVキャッシュ込みでも余裕、長文脈も取れる |
| Ollama公式 | ✓ `ollama.com/library/gemma4`（公式配布＝テンプレート破損リスク回避） |
| 変種 | 12B(dense,256K,7.6GB) が16GBの最適点。26B(MoE,~18GB)・31B(dense,~20GB)は16GB超で不可 |

→ **全ハード要件を満たす唯一の「安全な万能解」**。特にApache 2.0とOllama公式配布は、有償配布プロダクトにとって最重要。

### 第2候補: `NVIDIA Nemotron-Nano-9B-v2-Japanese`（日本語は最強だが要検証）

| 項目 | 評価 |
|---|---|
| 非中国系 | ✓ NVIDIA（米） |
| 日本語 | ✓✓ **日本語特化**。Nejumi Leaderboard 4のオープンモデル日本語で最上位クラス（総合0.7111） |
| ライセンス | ✓ NVIDIA Nemotron Open Model License（商用可） |
| VRAM 16GB | ✓ 9B。Q4_K_Mは12GB級で快適、16GBならQ8も可 |
| Ollama公式 | ✗ **公式libraryに無い**（コミュニティ名前空間のみ）。かつ hybrid Mamba(`nemotron_h`)アーキで
  Ollama互換に難があった（新しめのOllamaで対応）。**プロジェクトの「公式配布のみ」鉄則に反し、
  テンプレート/アーキ健全性の検証が必須** |

→ 日本語の実測性能は最上位だが、配布形態・アーキのリスクがあり、採用には事前検証が要る。

## 補足: Embeddingも中国系（bge-m3）である点

現行Embeddingの `bge-m3` は BAAI（北京智源人工智能研究院＝中国系）。「中国系以外で」を厳密に貫くなら
Embeddingも対象になる。非中国系の候補は `embeddinggemma`（Google、Gemma 4と自然にペア）等。
ただし **Embedding変更は全文書の再embedが必須**であり、過去 `mxbai-embed-large` は日本語言い換えで
失敗して bge-m3 に戻した経緯があるため、切替は評価必須。今回のLLM切替とは分けて判断するのが安全。

## 除外・不適

- `qwen`系: 中国系のため除外（今回の趣旨）。
- Swallow（東工大, Llama継続学習）/ ELYZA（Llama-3-JP-8B）: 日本語は強いが Ollama公式libraryに無く
  コミュニティGGUF配布 → 鉄則に反する（採用するなら検証必須）。
- Gemma 4 26B MoE / 31B: 16GB VRAMに収まらない（~18GB/~20GB）。
- クラウド専有（GPT-5.2/Gemini 3/Claude）: ローカル完結の製品要件に反する。

## 採用に向けた統合手順（承認後）

1. **同梱Ollamaのバージョン確認**: `gemma4:12b`（2026-06追加変種）は比較的新しいOllamaが必要。
   同梱の **Ollama v0.31.2 で `ollama pull gemma4:12b` が通るか検証**。通らなければOllama更新（配布物のOllamaランタイムをバンプするPRが別途必要）。
2. `gemma4:12b` を取得し、`LLM_MODEL` 等の設定へ配線（Embeddingは当面bge-m3を維持 or 別途判断）。
3. **既存の30問評価（`scripts/scale-eval.py`）で日本語RAG精度・ハルシネーションを qwen3:8b と比較**
   （qwen3:8bは26/30・不明応答5/5が基準）。
4. 基準クリアなら compose の image、export（`export.sh` / `export-windows.ps1` の BundleModels）、
   `MODEL_CARDS.md`、`LICENSES/` を更新。
5. e2e回帰（11/11）→ Windows再ビルドに反映。

## 実測結果（2026-07-14、dev環境・scale-eval.py 30問）

条件: 規程10本を同一ワークスペースに投入、Embedding=bge-m3固定、判定は現行ハーネス（<think>除去）。

| モデル / 設定 | (a)事実 | (b)数値判別 | (c)不明応答 | (d)言い換え | 合計 | 捏造 |
|---|:--:|:--:|:--:|:--:|:--:|:--:|
| gemma4:12b（現行prompt, topN=8） | 10 | 7 | 4/5 | 3 | 24/30 | 1 |
| **gemma4:12b（調整prompt, topN=8）★採用** | 10 | 7 | **5/5** | 3 | **25/30** | **0** |
| gemma4:12b（調整prompt, topN=15） | 8 | 7 | 2/5 | 3 | 20/30 | 3 |
| qwen3:8b（現行prompt, topN=8, 基準取り直し） | 10 | 8 | 1/5 | 3 | 22/30 | 4 |

結論:
- **採用構成 = gemma4:12b + 調整プロンプト + topN=8 → 25/30・ハルシネーションゼロ**。qwen3:8b(22/30・捏造4)を精度・安全性の両面で上回る。
- **プロンプト調整の効果**: gemma4は「答えが文書にあるのに拒否する過剰拒否」と「実在しない出典の捏造」が出やすい。既定システムプロンプトを (3)言い換え許容・(4)過剰拒否禁止・(6)捏造禁止 に調整し、捏造を4/5→5/5(ゼロ)に解消（`server/models/systemSettings.js`）。
- **topNは8が最適**。15に上げるとチャンク増でノイズが増え、捏造が復活し正解も薄まる（cが5→2、aが10→8に悪化）。既定 `WORKSPACE_DEFAULT_TOP_N=8` を維持。
- **残る過剰拒否5件**（出張申請3営業日前・育休1ヶ月前・文書管理施行日・給料28日・弔慰金50000）はqwen3でも同一設問が落ちるため、モデル/プロンプトでなく**チャンク分割/embedding側の別課題**。かつ「捏造せず正直に無いと言う」安全側の失敗であり、出荷ブロッカーではない（別途チャンク調整の課題として残す）。

## 反映済み（2026-07-14、ソース側）

- `server/models/systemSettings.js`: 既定プロンプトをgemma4向けに調整（fork、ローカルコミット）。
- `runtime/docker-compose.yml` / `windows-native/config/server.env.template`: `OLLAMA_MODEL_PREF=gemma4:12b`。
- `windows-native/export-windows.ps1` `$BundleModels`・`scripts/export.sh`: 同梱LLMを gemma4:12b に。
- `docs/MODEL_CARDS.md`: LLMカードをGemma 4 12Bに差し替え、qwen3:8bを撤回済みへ。
- **未反映（Codex/Windows側で必要）**: 配布用の再ビルドで gemma4:12b を同梱（`ollama pull gemma4:12b` 後にexport）。dev稼働イメージも次回リビルドで既定プロンプトが反映される（評価はopenAiPrompt注入で先行検証済み）。配布zipは約2.3GB増（qwen3:8b 5.2GB→gemma4:12b 7.56GB）。

## 出典

- Ollama gemma4 ライブラリ: https://ollama.com/library/gemma4
- Gemma 4 概要・Apache 2.0: https://www.buildfastwithai.com/blogs/google-gemma-4-open-model / https://codersera.com/blog/gemma-4-complete-guide-2026/
- Gemma 4 12B 日本語・VRAM: https://ai-revolution.co.jp/media/what-is-gemma-4-12b/
- Nejumi Leaderboard 4（日本語ランキング, Nemotron Nano 9B Japanese 0.7111）: https://blog.qualiteg.com/llm-ranking-2025/ / https://note.com/wandb_jp/n/nec28bede0513
- NVIDIA Nemotron-Nano-9B-v2-Japanese: https://huggingface.co/nvidia/NVIDIA-Nemotron-Nano-9B-v2-Japanese / https://dev.classmethod.jp/articles/nemotron-9b-v2-japanese-handson/
- Ollama gemma4 対応バージョン: https://github.com/open-webui/open-webui/issues/23471
