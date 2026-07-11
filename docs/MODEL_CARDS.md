# MODEL CARDS — 同梱モデル一覧

最終更新: 2026-07-11（モデル構成確定に伴い作成。構成の根拠: `docs/RAG_ACCURACY_IMPROVEMENT_2026-07-11.md`）

本製品（Local RAG）に同梱・使用するAIモデルの正式な記録。配布パッケージのモデル差し替え時は本ファイルを必ず更新すること。**すべてのモデルは完全ローカルで動作し、顧客文書・質問内容を外部に送信しない。**

---

## 1. LLM: Qwen3 8B（`qwen3:8b`）

| 項目 | 内容 |
|---|---|
| 用途 | RAG回答生成（日本語）。出典必須・文書外は「不明」応答を既定システムプロンプトで強制 |
| 提供元 | Alibaba Cloud（Qwen Team）、Ollama公式レジストリ配布（`registry.ollama.ai/library/qwen3:8b`） |
| ライセンス | Apache-2.0（全文: `LICENSES/Apache-2.0_LICENSE.txt`、NOTICE参照） |
| パラメータ数 | 8.2B |
| 量子化 | Q4_K_M（GGUF、約5.2GB） |
| コンテキスト長 | 40,960トークン |
| 特記 | thinking（推論過程生成）を正式サポート。`trust_remote_code`不要（Ollama公式配布のみ使用する方針に適合） |
| manifest config digest | `sha256:05a61d37b08453e59290add468e3bb2f688e23a01e967fecb0e2fa41218cea76` |
| model blob digest | `sha256:a3de86cd1c132c822487ededd47a324c50491393e6565cd14bafa40d0b8e686f`（5,225,374,496 bytes） |
| 既定パラメータ | temperature 0.6 / top_k 20 / top_p 0.95 / repeat_penalty 1 / stop `<|im_start|>` `<|im_end|>` |
| 採用根拠 | 実運用規模30問評価で26/30（87%）・ハルシネーションゼロ・文書外質問の不明応答5/5（2026-07-11） |
| 旧構成からの変更理由 | 旧LLM（llm-jpコミュニティGGUF `hf.co/mmnga-o/llm-jp-4-8b-thinking-gguf:Q4_K_M`）はチャットテンプレート破損＋有害stopトークンにより回答本文が空になる致命的問題（30問評価0/30）。コミュニティGGUFは品質保証がなく、以後Ollama公式配布モデルのみ採用する |

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
| `hf.co/mmnga-o/llm-jp-4-8b-thinking-gguf:Q4_K_M` | 2026-07-11 | コミュニティGGUFのテンプレート破損で本文が空になる（30問評価0/30）。過去のe2e PASSは思考テキストへの偶然マッチ |
| `mxbai-embed-large:latest` | 2026-07-11 | 日本語言い換え検索で正解文書をtop8に入れられない |
| `llama3.1:8b` | 2026-07-04 | 日本語品質でllm-jp系に切替（その後llm-jp系も撤回）。Llama 3.1 Community License（Apache-2.0でない）点も配布上不利 |

## 配布パッケージとの対応

- Docker/WSL2版: `runtime/ollama-models/` をディレクトリごと同梱（`scripts/export.sh`）
- Windows native版: `windows-native/export-windows.ps1` の `$BundleModels`（manifest解析で必要blobのみ同梱）
- 両配布とも上記2モデル（qwen3:8b + bge-m3:latest）のみを同梱する。撤回済みモデルは同梱しない
