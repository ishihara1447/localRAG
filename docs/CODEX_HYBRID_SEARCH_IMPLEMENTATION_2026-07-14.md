# Codex実装記録: 日本語ハイブリッド検索（dense + BM25）

作成日: 2026-07-14  
状態: 実装・単体プローブ完了 / Linux稼働環境での防衛白書E2E評価待ち

## 背景と目的

防衛白書30問評価では、失敗8件のうち6件は正解チャンクがdense top8に存在し、残る2件（非核三原則・交戦権）だけがtop30にも入らない検索取りこぼしだった。

日本語PDFの字間空白正規化は先に根本対応済みであり、本実装はそれを置き換えない。dense検索が得意な言い換えと、BM25が得意な固有語・条文・数値の厳密一致をRRF（Reciprocal Rank Fusion）で融合し、2件の取りこぼしを補完する。

## 実装方針

- 既存のLanceDBベクトル表とEmbedding形式は変更しない。
- LanceDB 0.15のFTS tokenizerは日本語N-gramを直接指定できないため、日本語をUnicodeコードポイント単位のbi-gramへ前処理し、`whitespace` tokenizerの検索専用sidecar表へ格納する。
- sidecar名は `__oterag_fts__<workspace slug>`。通常のnamespace一覧・ベクトル件数には含めない。
- 初回検索時に既存namespaceから自動構築する。文書追加・文書削除・namespace削除にも追随する。
- dense候補とBM25候補をRRF（k=60）で融合し、ワークスペースのtopN件を返す。
- BM25だけで取得した出典には、意味類似度と誤認させるscoreを付けない。
- `LANCE_HYBRID_SEARCH=true` のときだけ有効。FTS構築・検索に失敗した場合は既存dense検索へ自動フォールバックする。
- 既存の `vectorSearchMode=rerank` は変更しない。通常の既定検索モードにhybridを適用する。

## 変更ファイル

AnythingLLM fork:

- `server/utils/vectorDbProviders/lance/index.js`
- `server/utils/vectorDbProviders/lance/hybridSearch.js`
- `server/__tests__/utils/vectorDbProviders/lance/hybridSearch.test.js`
- `server/__tests__/utils/vectorDbProviders/lance/index.test.js`

製品設定:

- `runtime/docker-compose.yml`
- `windows-native/config/server.env.template`

## 実施済み検証

- LanceDB 0.15 Linux native: 「非核三原則」「交戦権」を日本語bi-gram BM25で取得: PASS
- 公開検索入口 `performSimilaritySearch`: flag OFFでdense順位、ONでBM25融合順位: PASS
- hybrid処理の意図的エラー時にdenseへフォールバック: PASS
- 既存namespaceからのsidecar自動構築、件数集計からの除外、namespace削除連動: PASS
- 文書追加後のsidecar同期、文書削除後の主表・sidecar同期: PASS
- Windows配布用 `@lancedb/lancedb` 0.15 nativeで日本語BM25: PASS
- `node --check`、変更実装のESLint/Prettier、`git diff --check`: PASS

Jestテストは追加済み。ただしWSLのroot `node_modules` にJestがなく、Yarnキャッシュにも存在しなかったため、このセッションではJest runner自体を実行していない。ネットワークからの追加取得は行わず、同じケースをNode assertの一時DBプローブで実行した。

## 残作業

Linux稼働環境で、防衛白書を対象に以下を確認する。

1. 非核三原則・交戦権の正解チャンクがhybrid top8へ入ること。
2. 30問評価が現行21/30を下回らず、文書外質問5/5を維持すること。
3. 既存RAG E2E 11/11を維持すること。
4. 初回sidecar構築時間、通常検索の追加レイテンシを記録すること。

詳細依頼: `docs/CLAUDE_CODE_REQUEST_HYBRID_SEARCH_LINUX_VERIFY_2026-07-14.md`

## Git上の注意

本作業以外に、親リポジトリにはClaude Code由来の `.gitignore` 変更と改行コード差分、forkには既存2ファイルのmode差分が残っている。これらは変更・復元していない。コミット・pushも実施していない。
