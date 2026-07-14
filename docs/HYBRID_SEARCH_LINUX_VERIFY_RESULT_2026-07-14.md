# ハイブリッド検索 Linux実機評価 結果（2026-07-14〜15）

> **【訂正 2026-07-15】本レポートの「retrieval 1/2」「既定OFFを推奨」は誤りでした。**
> 非核三原則の定義チャンクは実際には hybrid検索で rank 1 に入っており、retrievalは**2/2 PASS**でした
> （私の採点用正規表現が原文の空白「持ち込ま せず」を通せず誤ってNG判定していたのが原因）。
> 士業でのスコア差（15 vs 10）も単発計測でノイズの範囲内でした。Codexが同日に独立検証した
> `docs/HYBRID_SEARCH_LINUX_VERIFY_RESULT_2026-07-15.md` が正しい結論です。
> **ユーザー判断によりハイブリッドは既定ON（`LANCE_HYBRID_SEARCH=true`）に確定**。以下は経緯として残す。

担当: Claude Code / 依頼: Codex（`docs/CLAUDE_CODE_REQUEST_HYBRID_SEARCH_LINUX_VERIFY_2026-07-14.md`）
対象実装: Codexの日本語ハイブリッド検索（dense + LanceDB bi-gram BM25 + RRF）

## 結論（先に）

- **実装は正しく安全**: 第三者コードレビューPASS、既存経路の非破壊を実機確認、RAG E2E **11/11 PASS**、文書外質問のハルシネーションゼロ維持。
- **ただし精度は退行するため、既定OFFにした**（`LANCE_HYBRID_SEARCH=false`）。実装は温存し opt-in とする。
  - 防衛白書30問: dense **21/30** → hybrid **19/30**
  - 士業規程（実ターゲット, 同一コンテナA/B）: 検索で採点される (a)+(b) が dense **15** → hybrid **10**
- 原因: 日本語bi-gram BM25はノイズが多く、RRF融合でdenseが正確に取れていたチャンクを押し出す。特に「似た短い固有語が複数文書に散在する」規程で顕著。
- **本質的なボトルネックは検索でなくLLM(gemma4:12b)の抽出精度**（正解がtop8にあるのに読み違え・数値取り違え・拒否のブレ）。検索方式では解けない。

## 検証中に発見・修正したバグ（Codex実装への追加修正）

| # | 種別 | 内容 | 修正 |
|---|---|---|---|
| 1 | 機能(重大) | sidecar構築が `query()` 既定 limit=10 で**10行だけ**になり、毎クエリ再構築＋FTSほぼ空振り | `buildOrOpenFtsTable` で `.limit(primaryCount)`。ログ `rows:10→1748` |
| 2 | 機能 | FTSヒットID→本体行の `where("id IN ...")` も既定limit=10で切り捨て | `.limit(ids.length)` 追加 |
| 3 | 機能 | 長音符「ー」(U+30FC, Script=Common)がカタカナrunから漏れ「レーダー→レ/ダ」と分断 | `CJK_RUN_PATTERN` に `ー々〆ヶゝゞヽヾ` を追加。**併せてトークナイザ変更に伴い sidecar物理表名をバージョニング**（`__oterag_fts__v2_<ns>`、旧表は前方一致で掃除対象）→ 静かな空振りを防止 |
| 4 | 性能 | 文書追加ごとに `createIndex(replace)` でコーパス全再インデックス（O(全行)×N） | `add` 後は `optimize()` で増分マージ（LanceDBは未インデックス行もflat searchで対象） |

第三者レビュー（実SDK live検証込み）でのその他の指摘（軽微）: 初回クエリの同期ビルド遅延、FTS→本体取得で不要なvector列も読む、等。いずれもブロッカーでない。

## 反映方法（依頼手順9の記録）

- dev image再ビルドはWSL2のDNSで失敗するため、対象ファイル（`lance/index.js`, `lance/hybridSearch.js`, `PDFLoader/index.js`, `systemSettings.js`）を稼働中 `anythingllm` コンテナへ `docker cp`＋`restart` で反映。`LANCE_HYBRID_SEARCH` はcompose再作成で切替。
- 評価namespaceは空白正規化後の防衛白書（`hakusho-eval-57319043`, 1748チャンク）。同一namespaceで dense/hybrid をA/B。
- 士業は `scripts/scale-eval.py`（fixtures/scale 10規程・30問）。

## retrieval診断（hybrid, 修正版, top8に正解チャンクが入るか）

| 質問 | dense | hybrid |
|---|:--:|:--:|
| 非核三原則（取りこぼし1） | ❌ | ❌（RRFでtop8に押し上がらず） |
| 交戦権（取りこぼし2） | ❌ | ✅ |
| 統合作戦司令部/防衛関係費/中国4.4倍（回帰） | ✅ | ✅ |

取りこぼし2件の回復は **1/2**（合格条件2/2に未達）。sidecar構築 約19〜46秒（1748行, 初回のみ）、以降のhybrid検索は約5〜11秒（gemma4生成込み）。

## 30問スコア

**防衛白書（同一namespace, topN=8）**

| 版 | a | b | c(不明) | d | e | 合計 |
|---|:--:|:--:|:--:|:--:|:--:|:--:|
| dense | 6/8 | 4/6 | 5/5 | 5/5 | 3/5 | **21/30** |
| hybrid | 6/8 | 4/6 | 2/6※ | 5/5 | 2/5 | **19/30** |

**士業（同一コンテナA/B, topN=8, gemma4）**

| 版 | a(事実) | b(数値) | c(不明) | d(言換) | 合計 |
|---|:--:|:--:|:--:|:--:|:--:|
| dense | 8/10 | 7/10 | 1/5 | 3/5 | 19/30 |
| hybrid | 6/10 | 4/10 | 5/5 | 4/5 | 19/30 |

- 士業の合計は同点だが、**(c)不明応答が 1⇔5 と乱高下**しており、これは gemma4 の確率的な拒否挙動のブレ（±4点）で検索方式と無関係。**検索で採点される (a)+(b) は dense 15 > hybrid 10** で、ハイブリッドは検索精度を落としている。
- ハルシネーション（文書外を捏造）は両版とも発生ゼロ（拒否のブレは「捏造」ではなく「答えられるのに不明と言う」側）。

## E2E回帰

`scripts/rag-e2e-test.sh`: **PASS=11 FAIL=0**（hybrid有効状態）。sidecar表は通常API（tables/totalVectors）から不可視、workspace削除で `__oterag_fts__*` も消える（実装どおり）。

## 判断と推奨

1. **`LANCE_HYBRID_SEARCH` は既定OFF**（compose・server.env.template 反映済み）。実装・テストは温存し、特定文書型で有効性が確認できれば opt-in で有効化する。
2. さらなる精度向上は検索でなく **LLM抽出** が主戦場。候補: (a)コンテキスト並べ替え(Lost in the Middle)、(b)より強い抽出をさせる段階プロンプト（ただし過去v2は不明応答を壊したので慎重に）、(c)より高性能な非中国系LLM。
3. hybridを活かすなら RRF の重み（dense優先）や BM25候補の「denseが漏らした分だけ追加」方式への作り替えが要る（現状の対称RRFは対短文・多類似文書で不利）。

## 未コミット

依頼方針に従い、コミット・pushはユーザーの明示指示があるまで保留（本レポート・バグ修正・既定OFF化はいずれも作業ツリーに未コミット）。
