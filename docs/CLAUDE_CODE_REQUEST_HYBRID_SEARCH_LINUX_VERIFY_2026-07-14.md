# Claude Code作業依頼: ハイブリッド検索のLinux実機評価

作成: Codex / 宛先: Claude Code（Linux・dev稼働環境担当）  
作成日: 2026-07-14

## 目的

Codexが実装したLanceDB日本語ハイブリッド検索（dense + BM25 + RRF）をLinuxの実稼働コンテナへ反映し、防衛白書で検索取りこぼしだった2件を救えるか確認する。

実装内容と単体検証: `docs/CODEX_HYBRID_SEARCH_IMPLEMENTATION_2026-07-14.md`

## 前提

- fork最新基準は `5649a7ec`（日本語PDF字間空白正規化）。その上の未コミット差分としてCodexのBM25実装がある。
- 親リポジトリの `runtime/docker-compose.yml` に `LANCE_HYBRID_SEARCH=true` を追加済み。
- Embedding=`bge-m3`、LLM=`gemma4:12b`、topN=8、既定プロンプトは変更しない。
- BM25の効果を切り分けるため、モデル・プロンプト・チャンクサイズ・topN・リランカーを同時変更しない。
- `fixtures/local/` の防衛白書と評価データは機微・大容量データとしてGitへ追加しない。
- Codex/ユーザーの未コミット変更を復元・上書きしない。コミット・pushはユーザーの明示指示があるまで行わない。

## 反映対象

fork:

- `server/utils/vectorDbProviders/lance/index.js`
- `server/utils/vectorDbProviders/lance/hybridSearch.js`

設定:

- `runtime/docker-compose.yml` の `LANCE_HYBRID_SEARCH=true`

collectorの日本語PDF空白正規化も反映された状態で評価すること。古い抽出結果を使う場合は、防衛白書を再取り込みする。

## 作業手順

1. 上記差分をレビューし、既存dense検索・rerank経路・namespace削除を壊していないことを確認する。
2. dev AnythingLLM/serverへ差分を反映する。通常イメージ再ビルドがDNS等で困難な場合は、従来どおり対象ファイルだけをコンテナへ反映してよい。ただし実施方法を結果へ記録する。
3. `LANCE_HYBRID_SEARCH=false` で現行baselineを確認する。
4. `LANCE_HYBRID_SEARCH=true` でserverを再起動する。
5. 空白正規化後の防衛白書namespaceを使用する。未反映なら再取り込みする。
6. retrieval診断で次の正解チャンクがtop8へ入るか確認する。
   - 非核三原則: 「持たず、作らず、持ち込ませず」
   - 交戦権: 「国の交戦権は、これを認めない」
7. `scratchpad/hakusho_eval30.py` で30問評価を再実行する。
8. `scripts/rag-e2e-test.sh` を実行し、既存11項目を回帰確認する。
9. sidecar表の初回構築時間、2回目以降の検索時間、物理表名、通常APIのベクトル件数が増えて見えないことを確認する。

## 合格条件

- 取りこぼし2件の正解チャンクがhybrid top8へ入る: **2/2**
- 防衛白書30問: **21/30以上**。期待値は検索漏れ2件回復による23/30だが、LLM抽出失敗ならretrieval結果と回答結果を分けて記録する
- 文書外質問: **5/5、不明応答維持、ハルシネーションゼロ**
- RAG E2E: **11/11 PASS**
- FTS障害時にdense検索が継続する
- workspace削除後に `__oterag_fts__<slug>` が残らない

## 結果記録

`docs/HYBRID_SEARCH_LINUX_VERIFY_RESULT_2026-07-14.md` を作成し、以下を記録する。

- 反映方法と使用コミット/差分
- baselineとhybridのretrieval top8比較
- 30問カテゴリ別スコアとハルシネーション件数
- E2E結果
- 初回構築・通常検索レイテンシ
- 発見した不具合、追加修正、残課題

完了後に `docs/HANDOFF.md` 冒頭へ結果とWindows v1.2.0再ビルドへの反映要否を追記する。
