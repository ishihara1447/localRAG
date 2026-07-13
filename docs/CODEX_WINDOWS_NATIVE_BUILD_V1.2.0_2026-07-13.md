# Codex 作業依頼: v1.2.0ビルド + サービス制御UI/デスクトップランチャーの実機検証

作成日: 2026-07-13（Claude Code） / **改訂: 2026-07-13（1回目のズレを受けて再依頼）**
背景: `docs/HANDOFF.md` の「2026-07-13 サービス制御UI+デスクトップランチャー実装完了」を参照。
fork `57b5d115`（サービス制御API/UI）・localRAG本体（デスクトップランチャー・ショートカット・サービス制御env）が対象。

> ## ⚠️ 最重要（前回のズレ、必ず先に読む）
> 2026-07-13の1回目実行（`docs/WINDOWS_NATIVE_VERIFY_ROUND2_RESULT_2026-07-13.md`）では、
> **Part A/B（ビルド）を実行しないまま検証ランナーだけを回したため、v1.2.0ではなく既存のv1.1.0.zipを検証してしまった**
> （ランナーのデフォルトZipPathが当時v1.1.0だったため）。v1.1.0の回帰はPASSしたが、今回の本題である
> v1.2.0の新機能（デスクトップショートカット・ランチャー・サービス制御UI）は一切検証できていない。
>
> **今回の必須事項**:
> 1. **必ずPart A（yarn install/build）→ Part B（export-windows.ps1 -Version 1.2.0）を先に完了させ、`C:\LocalRAG\dist\LocalRAG-win64-v1.2.0.zip`を実在させてから**Part Cへ進むこと。
> 2. ランナーのデフォルトZipPathは**v1.2.0に更新済み**（未ビルドのまま実行すると「zip not found」で止まる＝旧版の誤検証を防止）。それでも念のためPart Cでは`-ZipPath`を明示指定すること。
> 3. Part Cが「zip not found」で止まった場合は、Part A/Bが未完了ということ。検証ではなくビルドに戻る。

## 前提（Claude側で完了済み・確認不要）

- `C:\LocalRAG\src`（frontend/server）は fork `57b5d115` まで同期済み（diffなし確認済み）。
- `C:\LocalRAG\windows-native` はリポジトリと完全一致に同期済み（`launcher/`・`deploy/`・`verify/` 含む）。
  旧版（Jul 10時点）には `launcher/` フォルダ自体が存在せず、`install.ps1`/`export-windows.ps1`/`uninstall.ps1`/`config/server.env.template` も未反映だったため、今回同期した。
- localRAGリポジトリのコミット5件（サービス制御UI実装4件＋Round2レポート記録1件）はorigin/mainにpush済み。

## 今回の作業: v1.2.0ビルド → 実機検証

### Part A. ビルド（Windows、管理者権限不要）

```powershell
cd C:\LocalRAG\src\server
yarn install
node node_modules\prisma\build\index.js generate --schema=.\prisma\schema.prisma
cd C:\LocalRAG\src\collector
yarn install

cd C:\LocalRAG\src\frontend
yarn install
yarn build
# ビルド成果物を server\public にコピー（既存の export-windows.ps1 チェック対象）
Copy-Item -Recurse -Force .\dist\* ..\server\public\
```

- `server\node_modules\.prisma\client` に `query_engine-windows*` が生成されていることを確認（export-windows.ps1が事前チェックする）。
- `server\public\index.html` または `_index.html` が存在することを確認。

> **⚠️ 事前必須: OTE-RAGリブランドをC:\LocalRAG\srcへ再同期してからビルドすること（2026-07-13追加）**
> WSL側forkに製品名リブランド（「LocalRAG for ℳシステム」→「OTE-RAG（おてらぐ）」）とアイコンの日の丸化を実施済み。
> **これはyarnビルド前のソース再同期が必須**（フロント広範囲＝`frontend/src`の40ファイル・`frontend/index.html`・
> `server/utils/boot/MetaGenerator.js`・`server/utils/localServices/index.js`・ロゴSVG3点が変更されている）。
> 前回のデザイン刷新と同様、差分コピーでなく**ソースツリー再コピー推奨**（node_modules/.git除く）。
> - 温存すべき技術識別子は変更していない: サービス名`LocalRAG-Ollama/Collector/Server`、パス`C:\LocalRAG*`、
>   import識別子`LocalRAGIcon`、アセットファイル名`localrag-*.svg`はそのまま（表示テキストのみOTE-RAG化）。
>
> **favicon（日の丸アイコン）の再生成**: WSL側ではsharpのネイティブバイナリがlinux非対応で生成できなかったため未実施。
> ビルドマシン（Windows、sharp動作）で新アイコンSVGから`frontend/public/favicon.png`を再生成すること:
> ```powershell
> cd C:\LocalRAG\src\server
> @"
> const sharp=require('sharp'),fs=require('fs');
> const svg=fs.readFileSync('..\\frontend\\src\\media\\logo\\localrag-icon.svg');
> sharp(svg,{density:384}).resize(256,256,{fit:'contain',background:{r:0,g:0,b:0,alpha:0}}).png()
>   .toFile('..\\frontend\\public\\favicon.png').then(()=>console.log('favicon.png OK'));
> "@ | Out-File -Encoding utf8 _gen-favicon.js
> node _gen-favicon.js; Remove-Item _gen-favicon.js
> ```
> `favicon.ico`も更新したい場合は48pxで別途生成（任意。多くのブラウザはpngのicon linkで足りる）。
> 再生成した`favicon.png`が`yarn build`のコピー対象に含まれるよう、**faviconを作ってから`yarn build`→server\public コピー**の順で実行する。

### Part B. パッケージ生成

```powershell
cd C:\LocalRAG\windows-native
powershell -NoProfile -ExecutionPolicy Bypass -File .\export-windows.ps1 `
  -Version 1.2.0 `
  -SourceDir C:\LocalRAG\src `
  -NodeDir C:\LocalRAG\build-deps\node-v22.20.0-win-x64 `
  -OllamaDir C:\LocalRAG\build-deps\ollama `
  -WinSWExe C:\LocalRAG\build-deps\WinSW-x64.exe `
  -ModelsDir $env:USERPROFILE\.ollama\models `
  -OutputDir C:\LocalRAG\dist
```

- モデルは`qwen3:8b`+`bge-m3`（v1.1.0と同じ、変更なし）。
- 生成物: `C:\LocalRAG\dist\LocalRAG-win64-v1.2.0.zip`。旧版（v1.1.0）は残したままでよい。

### Part C. 実機検証（Round2ランナーを流用、-ZipPathでv1.2.0を指定）

```powershell
cd C:\Temp\localrag-round2
powershell -NoProfile -ExecutionPolicy Bypass -File .\round2-admin-verify.ps1 -ZipPath C:\LocalRAG\dist\LocalRAG-win64-v1.2.0.zip
```

管理者昇格が必要な場合は前回同様 `Run-Round2-Verify.cmd`（UAC自己昇格）を使うか、ユーザーに管理者実行を依頼する（過去のRound2と同じ運用）。

**今回追加で確認すべき新規項目（Round2にはなかった）**:

1. **デスクトップショートカット**: install.ps1実行後、全ユーザーデスクトップに`LocalRAG.lnk`が作成されているか。
2. **疎通確認ランチャー**: ショートカットをダブルクリックし、`LocalRAG.html`がサーバー正常時にアプリへ自動遷移するか。サービス停止中は日本語案内+再接続ボタンが出るか（`stop.ps1`実行後に手動確認）。
3. **サービス制御UI**: Web UI右上の状態ピル→3サービスパネルから、Ollama/Collectorを実際に**起動・停止**できるか（`sc.exe`経由のWinSW制御。devでは検証不可、今回が実機での初検証）。
   - 停止後、入力欄上に警告バナーが出るか。
   - 停止中にVRAMが解放されるか（`nvidia-smi`または`/api/ps`で確認）。
   - 再度起動ボタンでサービスが復帰し、RAGが使えるようになるか。
4. **サービスセルフ制御不可の確認**: server自身は制御対象外（UI提供中のため）であることの仕様通りの挙動（Serverのstart/stopボタンが出ない、または操作できないこと）。
5. 既存のE2E11項目・backup/stop/start・uninstallはRound2と同様PASSすること（回帰確認）。

## 報告テンプレート

`docs/WINDOWS_NATIVE_BUILD_V1.2.0_RESULT_2026-07-13.md` として、Round2のテンプレート（`docs/CODEX_WINDOWS_NATIVE_VERIFY_ROUND2_2026-07-10.md`末尾）に上記1〜4の新規項目を追加した形式で報告してください。
