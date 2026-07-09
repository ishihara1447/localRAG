# Windows Native ビルド・検証結果
作成日: 2026-07-10 / 担当: Codex

## Part A: ビルド
- A-0 ソース再取得・COLLECTOR_HOTDIR_PATH確認: OK
  - `C:\LocalRAG\src` を削除後、WSL側 `anything-llm` から再取得。
  - `server\utils\files\index.js` の `COLLECTOR_HOTDIR_PATH` 検出結果: `True`。
- A-1 yarn install / frontend build / prisma generate: OK
  - `server` / `collector` / `frontend` の `yarn install`: OK（合計 約43秒）。
  - `collector` の optional dependency `canvas` は Node 24 ABI 向けprebuiltなしで失敗ログあり。ただし yarn install は成功扱い。
  - frontend build: OK（約21秒）。postbuildにより `server\public\_index.html` が生成される。
  - prisma generate: OK。`query_engine-windows.dll.node` 生成確認済み。
- A-2 依存DL（node/ollama/winswの正確なバージョン）:
  - Node.js portable: `v22.20.0` (`node-v22.20.0-win-x64.zip`)
  - Ollama standalone: GitHub release `v0.31.2` の `ollama-windows-amd64.zip` から取得。ただし同梱 `ollama.exe --version` の表示は `ollama version is 0.23.0`。
  - WinSW: `v2.12.0` の `WinSW-x64.exe`。
  - 取得時、Windows curl が `CRYPT_E_NO_REVOCATION_CHECK` で失敗したため、公式URLに対して `curl.exe --ssl-no-revoke` で再取得。
- A-3 export-windows.ps1: OK
  - 所要時間: `00:07:05.9135547`
  - package folder: `C:\LocalRAG\dist\LocalRAG-win64-v1.0.0`
  - zip: `C:\LocalRAG\dist\LocalRAG-win64-v1.0.0.zip`
  - package files: `100513`
  - package size: `7.38 GiB`
  - zip size: `6.04 GiB` (`6482414647` bytes)
  - `versions.lock`:

```text
package_version=1.0.0
build_date=2026-07-10T00:08:22+09:00
node=v22.20.0
ollama=ollama version is 0.23.0
models=mxbai-embed-large:latest, hf.co/mmnga-o/llm-jp-4-8b-thinking-gguf:Q4_K_M
source_dir=C:\LocalRAG\src
```

- 発生したエラーと暫定対処:
  - 初回exportは `server\public\index.html` が無いことで失敗。AnythingLLM frontend postbuild は `_index.html` にリネームするため、`export-windows.ps1` のチェックを `index.html` または `_index.html` 許容に修正。
  - モデルblobに5GB超の単一ファイルがあるため、`Compress-Archive` ではなく、大容量ファイル検出時に `tar.exe -a -cf` でzip作成するよう `export-windows.ps1` を修正。

## Part B: 検証
- B-0 クリーン化で停止したもの:
  - PoC手動プロセス `3002` / `8888` / `11435`: なし。
  - LocalRAGサービス: なし。
  - 現在 `3001` は `wslrelay.exe` が使用中。管理者インストール検証前に `wsl --shutdown` 等で解放が必要。
- B-1 install.ps1:
  - `Expand-Archive C:\LocalRAG\dist\LocalRAG-win64-v1.0.0.zip -DestinationPath C:\Temp\localrag-install`: OK（PS5.1、約21分45秒）。5GB超blobの展開も確認。
  - ただし、`Expand-Archive` 展開後の root `install.ps1` は Windows PowerShell 5.1 の parser がハングする。
  - 同じzipを `tar.exe -xf` で展開した場合、PS5.1 / pwsh とも `install.ps1 -SkipChecksum` はpreflightまで進み、現セッションでは以下で正常に停止:

```text
=== LocalRAG Windows native installer ===
[preflight] Checking environment...
ERROR: run this script from an elevated (Administrator) PowerShell.
```

  - 現Codexセッションは非管理者 (`admin=False`) のため、サービス登録・起動までは未実施。
  - サービス状態: LocalRAGサービスなし。
  - UI表示: 未実施（管理者権限が必要）。
- B-2 E2E: 未実施
  - 理由: `install.ps1` が管理者権限必須のため、サービス起動まで進められない。
- B-3 backup/stop/start: 未実施
  - 理由: サービス未インストール。
- B-4 uninstall: 未実施
  - 理由: サービス未インストール。
  - `C:\LocalRAGProd` と `C:\ProgramData\LocalRAG` は作成されていないことを確認済み。
- B-5 オフライン検証（任意）: 未実施

## Claude Codeへの修正依頼・気づき
- 顧客手順の展開コマンドは現状 `Expand-Archive` だが、今回生成zipでは root `install.ps1` がPS5.1 parserでハングする。`tar.exe -xf` 展開では正常なため、以下のどちらかを検討してほしい。
  - 顧客手順を `tar.exe -xf LocalRAG-win64-v1.0.0.zip` に変更する。
  - zip生成方式またはパッケージ構成を変更し、`Expand-Archive` 展開後も root `install.ps1` がPS5.1で動くようにする。
- `export-windows.ps1` は今回2点だけ修正済み。
  - frontend成果物チェックを `_index.html` 対応。
  - 2GB超ファイルがある場合に `tar.exe` でzip作成。
- 管理者権限での再検証時は、先に `wsl --shutdown` などで `3001` の `wslrelay.exe` を止める必要がある。
- Ollamaは公式GitHub release `v0.31.2` assetを取得したが、`ollama.exe --version` は `0.23.0` と表示された。配布前にOllama側のversion表示仕様または取得assetの妥当性を再確認したい。
