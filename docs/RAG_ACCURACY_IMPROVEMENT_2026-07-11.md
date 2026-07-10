# RAG精度検証・改善の結果報告（2026-07-11）

担当: Claude Code（調査・評価セット構築はサブエージェント委譲）
関連: `docs/RAG_ACCURACY_RESEARCH_2026-07-10.md`（手法調査）、`docs/RAG_TUNING_POINTS_FORK_2026-07-10.md`（fork棚卸し）

## 結論

**モデル構成を変更し、実運用規模評価30問で 0/30 → 26/30（87%）に改善。ハルシネーションゼロ・不明応答5/5でパイロット投入可能な水準と判断。**

| 項目 | 旧構成 | 新構成（2026-07-11確定） |
|---|---|---|
| LLM | hf.co/mmnga-o/llm-jp-4-8b-thinking-gguf:Q4_K_M | **qwen3:8b**（Ollama公式, Apache-2.0） |
| Embedding | mxbai-embed-large | **bge-m3**（Ollama公式, MIT） |
| topN既定 | 4（prisma default） | **8**（`WORKSPACE_DEFAULT_TOP_N` envで注入） |
| チャンキング | langchain既定（日本語ぶつ切り） | **日本語セパレータ**（段落→改行→。→、） |
| image | 1.0.2 | **1.0.3** |

## 評価方法

実運用を模した新評価セット（`fixtures/scale/` 紛らわしい社内規程10本 + `scripts/scale-eval.py` 30問）。
質問カテゴリ: a)単一規程内の事実10問（出典検証付き） b)紛らわしい数値の判別10問 c)規程に無い情報5問（不明応答期待） d)言い換え・同義語5問。

## 実験マトリクス

| 構成 | a | b | c | d | 合計 |
|---|---|---|---|---|---|
| 旧構成そのまま | - | - | - | - | **0/30**（本文が生成されない） |
| llm-jp修正版 + mxbai + topN4 | 9 | 6 | 0 | 1 | 16/30 |
| qwen3:8b + mxbai + topN4 | 9 | 5 | 5 | 0 | 19/30 |
| qwen3 + mxbai + topN8 + 日本語セパレータ(1.0.3) | 9 | 5 | 5 | 0 | 19/30 |
| **qwen3 + bge-m3 + topN8 + セパレータ(1.0.3)** | **10** | **8** | **5** | **3** | **26/30** |

回帰確認: 新構成で `rag-e2e-test.sh` **11/11 PASS**、`precision-eval.py` 18/19（1件は非決定的な単発、手動再現では正答・正出典を確認）。

## 発見した重大問題（精度以前の実運用ブロッカー）

### 1. 旧LLM（コミュニティGGUF）のチャットテンプレート破損 — 本文が生成されない

- GGUFに焼き込まれた自動生成Modelfileに (a) `tart|>user` という破損文字列、(b) harmony形式のチャンネル遷移トークン（`<|channel|>`等）がstopパラメータに登録、という2つの欠陥。
- 結果、思考の後に本文を書こうとした瞬間に生成が停止し、**ユーザーに見える回答が空になる**。
- **過去のe2e/精度テストのPASSは、期待値が思考テキスト内に偶然含まれたことによる見かけのPASSを含んでいた**（今回、判定前に`<think>`を除去する評価に是正して発覚）。
- stopを修正した`llm-jp-4-8b-thinking-fixed`も試したが、途切れ・タグ混入が残存し、**存在しないファイル名を出典として捏造する**ケースを確認したため不採用。
- 教訓: **LLMはOllama公式配布のモデルのみ使用する**（コミュニティ変換GGUFはテンプレート品質が保証されない）。評価は必ず「顧客に見える本文」に対して行う。

### 2. embedding（mxbai）が日本語の言い換えを検索できない

- 「配偶者に先立たれた→死亡弔慰金」「自分のデータを見せて→開示請求」等の言い換え質問で、**正しい規程がtop8にも入らない**（d: 0/5）。topN増・チャンキング改善では解消せず、bge-m3への入替のみが効いた（d: 3/5、b: 5→8、a: 9→10）。
- 手法調査レポートの予測（mxbaiは英語特化・embedding入替が最優先）と一致。

### 3. その他の修正

- 既定システムプロンプトに「内部CONTEXT番号を回答に含めない・出典は文書名で示す」を追加（qwen3が「[CONTEXT 0]の第1条…」と露出していた）。
- 新規ワークスペースの検索既定値をenv注入化（`WORKSPACE_DEFAULT_TOP_N`等）— 顧客がWSを作るたびにtopN=4に戻る問題の恒久対応。

## インストール方式への影響（セットで実施済み）

**インストール手順自体は不変**（tar展開→install.ps1の流れ・スクリプトに変更なし）。変わるのは同梱物と設定値のみ:

| 変更 | Docker配布 | Windows native配布 |
|---|---|---|
| モデル | `runtime/ollama-models`に取得済み（export.shはディレクトリごと同梱） | `export-windows.ps1`のBundleModelsをqwen3:8b+bge-m3に更新済み |
| 設定 | `runtime/docker-compose.yml`更新済み | `windows-native/config/server.env.template`更新済み |
| image | 1.0.3（日本語セパレータ+env注入+プロンプト改善） | ソースは同一forkからビルドされるため次回ビルドで自動反映 |
| ライセンス | LICENSES/NOTICE/THIRD_PARTY更新済み（Qwen3=Apache-2.0, bge-m3=MIT。llama3.1/llm-jp/mxbaiは非同梱化） | 同左 |

**注意（Round2検証との関係）**: ビルド済みの`LocalRAG-win64-v1.0.0.zip`は旧モデル構成のまま。Round2実機検証はインストーラ機構（サービス化・GPU・uninstall）の検証として引き続き有効だが、**合格後にv1.1.0として新モデル構成で再ビルドが必要**。Windows側`%USERPROFILE%\.ollama\models`にはqwen3:8bは既存、bge-m3の追加コピーが必要（WSL側`runtime/ollama-models`から）。

## 残課題（P2バックログ、費用対効果順）

1. 言い換え検索の残り（d: 3/5）: 日本語リランカー導入（fork内に機構あり・ONNXモデル差替の改修が必要）または ruri-v3系embedding（Ollama対応の成熟待ち）
2. b)残り2問: 附則・施行日などチャンク粒度問題 → 条文単位チャンキング（fork中規模改修）
3. APIレスポンスの`<think>`露出（UI表示は対応済み。API連携時の見た目の問題のみ）
4. `EMBEDDING_MODEL_MAX_CHUNK_LENGTH`の文字/トークン単位混在（fork棚卸しレポート参照）
