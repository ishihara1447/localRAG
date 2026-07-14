# Codex作業メモ — OTE-RAG v1.2.0 Windowsビルド追記

作成日: 2026-07-14  /  宛先: Claude Code

## 今回確認したこと

- WSL側のfork `anything-llm` は `8907620d`（OTE-RAGリブランド、日の丸SVG）まで更新済み。
- Windows側 `C:\LocalRAG\src` に `frontend`（`node_modules`除外）と指定されたserver 3ファイルを同期した。
- `frontend\index.html` のタイトルは `OTE-RAG` になった。
- Windows側のsharpで `frontend\public\favicon.png` を日の丸SVGから生成した（256x256、10,295 bytes）。
- server／collector／frontendの依存関係確認、Prisma Windowsエンジン生成、frontend buildは完了した。
  - collectorではPuppeteerのChrome自動取得とcanvasの任意バイナリ取得が証明書検証で失敗したため、`PUPPETEER_SKIP_DOWNLOAD=true` で再実行した。
  - frontend buildは仕様どおり `server\public\_index.html` を生成した。

## 顧客資料が最初のビルドに入らなかった件

最初の `export-windows.ps1 -Version 1.2.0` は成功したが、次の警告が出た。

```text
WARN: docs\customer-windows not found; package will ship without customer docs.
```

原因は、Windowsビルドツリーの `C:\LocalRAG\windows-native` が同期済みでも、exportスクリプトが参照する `C:\LocalRAG\docs\customer-windows` が存在しなかったため。WSLの正本に資料が存在していても、自動でUNC側から取得する処理はなかった。

対応として、WSLの正本
`\\wsl.localhost\Ubuntu-22.04\home\ishihara1447\projects\fukugyo\repos\localRAG\docs\customer-windows`
を `C:\LocalRAG\docs\customer-windows` に同期し、最初にCodexが作成した `C:\LocalRAG\dist\LocalRAG-win64-v1.2.0` と同名zipだけを削除して再生成している。旧v1.0.0／v1.1.0の成果物、`build-deps`、`src`、その他のフォルダは削除していない。

再生成中の展開物では、以下を確認済み。

- `docs\INSTALL_GUIDE.md` が存在
- 顧客docsを含むファイル数は100,601
- 展開物サイズは約9.53GB

## 再発防止の改善候補

`windows-native/export-windows.ps1` は現在、スクリプトの親ディレクトリにある `docs\customer-windows` だけを見ている。Windowsビルドを `C:\LocalRAG` のステージングツリーで行う場合、docs同期漏れを防ぐため、次のいずれかを検討する。

1. `-CustomerDocsDir`（または`-RepoRoot`）を引数化し、ビルド手順でWSL正本または同期済みdocsを明示する。
2. docsが無い場合は警告で継続せず、配布必須ファイルの欠落としてエラー終了する。
3. build手順にdocs同期と、生成パッケージ内の `docs\INSTALL_GUIDE.md` 存在確認を必須チェックとして追加する。

## 未完了の作業

- docs込みv1.2.0 zipの圧縮完了とサイズ・`versions.lock`・checksum確認。
- 管理者権限でv1.2.0 Round2検証。
- ショートカット、ランチャー、Web UIのOllama／Collector制御、停止時のVRAM解放、OTE-RAG表示の実機確認。
- 検証結果を `docs/WINDOWS_NATIVE_VERIFY_V1.2.0_RESULT_2026-07-14.md` に記録。
## v1.2.0追加不具合と修正

自動Round2ではE2E 11/11、GPU、backup、stop/start、uninstallがPASSしたが、手動UI確認用のサービス制御APIで次が判明した。

- /api/system/local-services の表示ラベルは OTE-RAG になっていた。
- Collector/Ollama の controllable は false で、Web UIからの停止・起動が無効だった。
- 原因は、WinSW Serverが NODE_ENV=production で起動し、Node側が .env.production を読むのに、installerが .env だけを生成していたこと。
- windows-native/install.ps1 を修正し、server用に .env.production も生成するようにした。
- ショートカット説明に残った LocalRAG for M System を OTE-RAG に修正した。
- windows-native/export-windows.ps1 の顧客docs欠落処理を警告継続からエラー終了へ変更した。

修正版はWSLリポジトリと C:\LocalRAG\windows-native へ同期済み。v1.2.0再ビルド後にサービス制御APIを再確認する。

ブラウザ操作はサンドボックス初期化エラーで未実施。ローカルAPI、ランチャーHTML、ショートカットのTarget/Icon、サービス状態は確認済み。
