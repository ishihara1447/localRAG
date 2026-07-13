# MODEL CARDS — 同梱モデル一覧

最終更新: 2026-07-14（LLMを非中国系 gemma4:12b に切替。根拠: `docs/MODEL_SELECTION_NON_CHINESE_2026-07-14.md` / 旧構成: `docs/RAG_ACCURACY_IMPROVEMENT_2026-07-11.md`）

本製品（Local RAG）に同梱・使用するAIモデルの正式な記録。配布パッケージのモデル差し替え時は本ファイルを必ず更新すること。**すべてのモデルは完全ローカルで動作し、顧客文書・質問内容を外部に送信しない。**

---

## 1. LLM: Gemma 4 12B（`gemma4:12b`）

| 項目 | 内容 |
|---|---|
| 用途 | RAG回答生成（日本語）。出典必須・文書外は「不明」応答を既定システムプロンプトで強制 |
| 提供元 | Google DeepMind、Ollama公式レジストリ配布（`registry.ollama.ai/library/gemma4:12b`） |
| ライセンス | **Apache-2.0**（全文: `LICENSES/Apache-2.0_LICENSE.txt`。ollama公式配布の同梱ライセンスblobでも確認済み） |
| パラメータ数 | 11.9B（dense） |
| 量子化 | Q4_K_M（約7.38GB。マルチモーダルprojector 175MB込みで約7.56GB） |
| コンテキスト長 | 262,144トークン（256K） |
| 必要Ollama | 0.30.5以上（同梱の配布用Ollama v0.31.2で動作。dev v0.30.11でも確認） |
| 特記 | thinking（推論過程生成）対応。vision/audio/tools対応の基盤だが、本製品ではテキストRAGのみ使用。`trust_remote_code`不要（Ollama公式配布のみ使用する方針に適合） |
| manifest config digest | `sha256:c805f5b265d8e695c44f4065dfc368206cd8026447604925fef8db57ee32ee23` |
| model blob digest | `sha256:1278394b693672ac2799eadc9a83fd98259a6a88a40acfb1dcaa6c6fc895a606`（7,381,382,048 bytes） |
| projector blob digest | `sha256:675ad6e68101ca9413ec806855c452362f0213f2dfc5800996b086fdb8119842`（175,115,584 bytes、vision用） |
| 既定パラメータ | temperature 1 / top_k 64 / top_p 0.95 |
| 採用根拠 | 中国系以外・RAG適性・日本語・商用可・16GB VRAMの要件をすべて満たす（`docs/MODEL_SELECTION_NON_CHINESE_2026-07-14.md`）。gemma4向け調整プロンプト＋topN=8の30問評価で**25/30・ハルシネーションゼロ（不明応答5/5）**。同条件でqwen3:8bは22/30・捏造4件であり、精度・安全性の両面で上回る |
| 旧構成からの変更理由 | 旧LLM `qwen3:8b`（Alibaba＝中国系）から、非中国系・Apache-2.0のGoogle Gemma 4に切替。gemma4は「過剰拒否」と「出典捏造」が出やすかったため、既定システムプロンプトを言い換え許容・捏造禁止方向に調整（`server/models/systemSettings.js` saneDefaultSystemPrompt、2026-07-14） |

## 2. Embedding: BGE-M3（`bge-m3:latest`）

| 項目 | 内容 |
|---|---|
| 用途 | 文書チャンク・質問文のベクトル化（LanceDBに格納、類似検索topN=8） |
| 提供元 | BAAI（Beijing Academy of Artificial Intelligence）、Ollama公式レジストリ配布（`registry.ollama.ai/library/bge-m3:latest`） |
| ライセンス | MIT（全文: `LICENSES/BGE-M3_LICENSE.txt`） |
| パラメータ数 | 566.7M（BERT系アーキテクチャ） |
| 精度/形式 | F16（GGUF、約1.16GB） |
| コンテキスト長 | 8,192トークン |
| 埋め込み次元 | 1,024 |
| 特記 | 多言語対応（日本語含む100+言語）。dense/sparse/multi-vector検索対応モデルだが、本製品ではdense embeddingのみ使用 |
| manifest config digest | `sha256:0c4c9c2a325fb1cdafec606e6809cb745f1cb26a6d919994400d27372303e276` |
| model blob digest | `sha256:daec91ffb5dd0c27411bd71f29932917c49cf529a641d0168496c3a501e3062c`（1,157,671,200 bytes） |
| 採用根拠 | 日本語の言い換え質問（同義語・語彙回避）で正解文書をtop8に安定して入れられる唯一の検証済みOllama公式embedding（2026-07-11評価） |
| 旧構成からの変更理由 | mxbai-embed-largeは日本語言い換え検索で正解文書をtop8にも入れられず撤回 |
| **重要な制約** | **embedding モデルを変更した場合は全文書の再embedが必須**（既存ベクトルとの互換性なし） |

---

## 撤回済みモデル（参考・再採用禁止）

| モデル | 撤回日 | 理由 |
|---|---|---|
| `qwen3:8b` | 2026-07-14 | 中国系（Alibaba）のため非中国系方針で置換。現行30問評価でも22/30・捏造4件でgemma4:12b（25/30・捏造0）に劣る |
| `hf.co/mmnga-o/llm-jp-4-8b-thinking-gguf:Q4_K_M` | 2026-07-11 | コミュニティGGUFのテンプレート破損で本文が空になる（30問評価0/30）。過去のe2e PASSは思考テキストへの偶然マッチ |
| `mxbai-embed-large:latest` | 2026-07-11 | 日本語言い換え検索で正解文書をtop8に入れられない |
| `llama3.1:8b` | 2026-07-04 | 日本語品質でllm-jp系に切替（その後llm-jp系も撤回）。Llama 3.1 Community License（Apache-2.0でない）点も配布上不利 |

## 配布パッケージとの対応

- Docker/WSL2版: `runtime/ollama-models/` をディレクトリごと同梱（`scripts/export.sh`）
- Windows native版: `windows-native/export-windows.ps1` の `$BundleModels`（manifest解析で必要blobのみ同梱）
- 両配布とも上記2モデル（gemma4:12b + bge-m3:latest）のみを同梱する。撤回済みモデルは同梱しない
- **ビルドマシン準備**: 再ビルド前に `ollama pull gemma4:12b` でモデルをModelsDirに取得しておくこと（同梱blob解析の対象）
