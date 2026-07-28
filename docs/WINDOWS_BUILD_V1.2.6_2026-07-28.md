# Windows 配布物 v1.2.6 ビルド報告

作成日: 2026-07-28
実施: Claude Code（WSL2 から `powershell.exe` 経由で Windows 側を操作）
手順の出典: `docs/AUTONOMOUS_PLAN_2026-07-27.md` §7-b（B-1〜B-8）
参照: `docs/CODEX_REQUEST_WINDOWS_BUILD_SETTINGS_MENU_2026-07-27.md`

> **並行実行への配慮**: WSL側 Docker（`anythingllm` / `rag-ollama`）で166問ベースライン測定が実行中だったため、
> `docker` 系コマンドは一切実行せず、dev環境（localhost:3001）にも接続していない。
> WSL側リポジトリは**読み取りのみ**、書き込みは Windows 側（`C:\LocalRAG\`）と本ドキュメントに限定した。

---

## 0. 結論

**B-1〜B-8 すべて完了。失敗した工程はない。** `C:\LocalRAG\dist\` に v1.2.6 の3点を配置済み。

```
C:\LocalRAG\dist\OTE-RAG-Setup.exe                 26,624 bytes
C:\LocalRAG\dist\OTE-RAG-win64-v1.2.6.zip  11,018,859,839 bytes
C:\LocalRAG\dist\OTE-RAG-win64-v1.2.6.zip.sha256       92 bytes
```

**次の操作（ユーザー）**: `C:\LocalRAG\dist\OTE-RAG-Setup.exe` を**管理者として実行**する。
Setup.exe は**未署名**のため SmartScreen が出る → 「詳細情報」→「実行」。
旧版（v1.2.5）がインストール済みなら、Setup.exe が自動でアンインストールを提案する（v1.2.4以降の機能）。

**途中で発見し対処した重大な問題が1件ある**（§2 の `VITE_API_BASE`）。計画書には無かった落とし穴で、
気づかなければ API ベースURLが `http://localhost:3001/api` に固定された配布物ができていた。

### 並行実行中の測定への影響

`docker` コマンドは一度も実行していない。dev環境（localhost:3001）にも接続していない。
ビルドは全て Windows 側（`C:\LocalRAG\`）で行い、WSL 側リポジトリは**読み取りのみ**。
書き込んだのは本ドキュメント1ファイルのみ。`git commit` / `push` はしていない。

---

## 1. B-1: ソース同期（WSL fork → `C:\LocalRAG\src`）

### 同期したコミット

同期元: `/home/ishihara1447/projects/fukugyo/repos/localRAG/anything-llm`
ブランチ: `product/customer-rag-base` / 作業ツリーはクリーン（未コミット変更なし）

| コミット | 日付 | 内容 |
|---|---|---|
| `2e61181d5c7c1920a0b2f5e13a1d0411a914e537` | 2026-07-28 | 設定画面を顧客向けに絞り、迂回経路を塞ぐ |
| `45056d856eb7c783bba1f0fcf0286a0f7720b041` | 2026-07-28 | PDF抽出のU+FFFDをU+2026へ置換する実装を追加する（既定OFF・不採用） |
| `f53d6101d77eb7f41f833138fe709c0c9c557d98` | 2026-07-28 | ハイブリッド検索にチャンク単位のリランクを追加する |
| `2d6db21981bdf236a0f7067aa1dc0b31f675c38e` | 2026-07-27 | OTE-RAGのアイコンを文書検索AIとして再設計（Codex作業） |

`2e61181d` が同期後の HEAD。

### 同期方法

`rsync -rltc --delete`（**チェックサム比較**）で、以下を除外して同期した。

```
/.git/  node_modules/  /server/storage/  /server/public/  /frontend/dist/
/collector/hotdir/  /collector/storage/  .env  .env.*  *Zone.Identifier*
/docs/（fork内の空ディレクトリ）  /frontend/bundleinspector.html（gitignore対象のビルド生成物）
__tests__/**/models/（gitignore対象のテストキャッシュ）
```

`server/public` と `frontend/dist` を除外したのは、**B-2 で作り直す**ため。

### 事前確認: `node_modules` の再インストールは不要

パッケージマニフェストが WSL 側と Windows 側で完全一致していたため、
Windows 側の既存 `node_modules`（および prisma windows エンジン）をそのまま使用した。

| ファイル | 結果 |
|---|---|
| `package.json` / `yarn.lock`（ルート） | 一致 |
| `server/package.json` / `server/yarn.lock` | 一致 |
| `collector/package.json` / `collector/yarn.lock` | 一致 |
| `frontend/package.json` / `frontend/yarn.lock` | 一致 |
| `server/prisma/schema.prisma` | 一致 |

`server/node_modules/.prisma/client/query_engine-windows.dll.node` の存在も確認済み。

### 🔴 実測: 主要ファイルの SHA-256 一致確認

同期後、WSL 側と `C:\LocalRAG\src` 側で **12ファイル全て一致**（MISMATCH 0件）。

| SHA-256 | ファイル |
|---|---|
| `37a2b00e798e87beac782d93803cc35426b54f8b883b1fb651a5cd767cb82e18` | `server/utils/vectorDbProviders/lance/index.js` |
| `36d467f1d80c3478…` | `server/utils/vectorDbProviders/lance/sentenceCushion.js` |
| `993bcbb0e43eb3d5690d8b10e9268af0c0bd2a1666d40752f423f91b24b8c891` | `server/utils/helpers/productProfile.js` |
| `0389c99341e2b22f…` | `server/utils/helpers/updateENV.js` |
| `6a4966f1c02eab98…` | `server/utils/helpers/index.js` |
| `b2563dd82a78a40629d77c2fd5f98659da666a0a89db23b9ce0605655d89e4c1` | `collector/processSingleFile/convert/asPDF/PDFLoader/index.js` |
| `b8ad9d852b846dae2103ec421bbe07d0c58a5974a4ba5d08f532480ad58c1015` | `frontend/src/utils/productProfile.js` |
| `ec6230921ebc575895c1cd55e2ac77d64b0904a878c78f4ea98b2442f02ffac6` | `frontend/src/components/SettingsSidebar/index.jsx` |
| `33f97a276600d02958bd21c0de2d693aca98acf9586effef1ed9f71027263745` | `frontend/src/components/PrivateRoute/index.jsx` |
| `4cfc76f95f97bdfa…` | `frontend/src/pages/GeneralSettings/LLMPreference/index.jsx` |
| `8fd4317fde199202…` | `frontend/src/pages/GeneralSettings/EmbeddingPreference/index.jsx` |
| `46de5e2ed6ff0003…` | `frontend/src/pages/GeneralSettings/VectorDatabase/index.jsx` |

さらに**ツリー全体**についても、同期後に `rsync --checksum --dry-run` を再実行して
**差分ゼロ**（転送対象0件）であることを確認した。個別ファイルだけでなく全体で一致している。

### 併せて同期したもの（`export-windows.ps1` が `C:\LocalRAG` 直下から取り込む資材）

| 対象 | 結果 |
|---|---|
| `windows-native/` 全体 | 同期。`config/server.env.template`・`config/collector.env.template` の2ファイルが古かった。`dist-split/` 3ファイルが新規追加 |
| `docs/customer-windows/` | 同期。ガイド5本＋onepager SVG 6本が古かった（アンインストール手順の追記など） |
| `docs/MODEL_CARDS.md` / `LICENSES/` / `NOTICE` | 既に一致（変更なし） |
| `fixtures/` | **意図的に同期しない**。WSL側にのみ存在する `fixtures/calibration` / `fixtures/complex` は評価専用であり、配布物に不要のため（v1.2.5 と同じ構成を維持） |

### 補足: 事前情報との差異

計画書は「Windows側 `src` は 2026-06-29 のまま」としていたが、**実測では
`54727020`（文抽出クッション）・`d6e7174d`（productProfile 導入）・`2d6db219`（アイコン）までは
既に反映済み**だった。実際に不足していたのは上記3コミット（`f53d6101` / `45056d85` / `2e61181d`）分の
差分のみで、内容としては計画書の想定と一致している。

---

## 2. B-2: frontend ビルドと `server/public` の作り直し

### 🔴 発見と対処: `VITE_API_BASE` が dev 値のままだった

`C:\LocalRAG\src\frontend\.env` は `VITE_API_BASE='http://localhost:3001/api'`（`.env.example` と同一の dev 値）
だった。一方、v1.2.5 の同梱バンドルには `localhost:3001` が**一切含まれず** `"/api"` が入っていた。
`docs/CODEX_WINDOWS_NATIVE_BUILD_AND_VERIFY_2026-07-09.md` L59 にも
`Set-Content -Path .env -Value "VITE_API_BASE='/api'"` と明記されている。

**このまま build していれば、API ベースが絶対URLに固定された配布物ができていた。**
ビルド直前に `.env` を `VITE_API_BASE='/api'` に差し替え、ビルド後に元へ戻した。
生成物を実測確認した結果は以下のとおり。

```
contains localhost:3001 : False
contains "/api"         : True
```

### 手順（実行内容）

1. `frontend\dist` を**削除**
2. `node node_modules\vite\bin\vite.js build`（= `yarn build` の前半。Windows に yarn が無いため vite を直接実行）
3. `node scripts\postbuild.js`（`index.html` → `_index.html` リネーム）
4. `server\public` を **`Remove-Item -Recurse -Force` で削除**してから `dist` をコピー（上書きコピーは不使用）

### ビルド結果

```
vite v4.5.3 building for production...
✓ 6134 modules transformed.
✓ built in 35.12s
```

### 🔴 実測: `server\public` のタイムスタンプ

| ファイル | サイズ (bytes) | LastWriteTime |
|---|---|---|
| `C:\LocalRAG\src\server\public\_index.html` | 913 | **2026/07/28 9:32:45** |
| `C:\LocalRAG\src\server\public\index.js` | 2,789,108 | **2026/07/28 9:32:45** |
| `C:\LocalRAG\src\server\public\index.css` | 303,909 | **2026/07/28 9:32:45** |

差し替え前（v1.2.5 のバンドル）は `2026/07/23 13:00` / `index.js` 2,790,105 bytes だった。
**今回のビルド時刻に更新されていることを実測確認済み。**

### 内容確認（設定メニュー変更がバンドルに入っているか）

`server\public\index.js` に `この配布版では利用できません`（`productProfile` の URL guard 文言）が
**含まれている**ことを実測確認した。2026-07-14 の「ソースにはあるのに配布物に入っていない」事故の再発なし。

---

## 3. B-3: env テンプレートの確認

`C:\LocalRAG\windows-native\config\server.env.template`（WSL側と SHA-256 一致: `8210ce23fd4ed1cc…`）

| gate | 値 | 備考 |
|---|---|---|
| `LANCE_HYBRID_SEARCH` | `true` | 既存 |
| **`LANCE_HYBRID_RERANK`** | **`true`** | **2026-07-27 追加。今回の配布物で初めて有効化される** |
| `LANCE_HYBRID_CANDIDATE_LIMIT` | コメントアウト（未設定＝既定 topN×4 = 32） | K=50 は退行するため意図的に未設定 |
| `LANCE_SENTENCE_CUSHION` | `true` | 既存 |
| `RERANKER_QUANTIZED` | `true` | 同梱は int8 のみ |

`C:\LocalRAG\windows-native\config\collector.env.template`（SHA-256 一致: `115fc15263d54e9d…`）

| gate | 値 |
|---|---|
| `PDF_MOJIBAKE_TO_ELLIPSIS` | **コメントアウト（＝OFF）**。2026-07-27 の実測で退行したため不採用 |

確定値どおりであることを確認した。

---

## 4. B-4 / B-5: export と Setup.exe

### 実行コマンド

```powershell
C:\LocalRAG\windows-native\export-windows.ps1 `
  -Version 1.2.6 `
  -SourceDir C:\LocalRAG\src `
  -NodeDir C:\LocalRAG\build-deps\node-v22.20.0-win-x64 `
  -OllamaDir C:\LocalRAG\build-deps\ollama `
  -WinSWExe C:\LocalRAG\build-deps\WinSW-x64.exe `
  -ModelsDir C:\Users\ms_is\.ollama\models `
  -RerankerModelDir C:\LocalRAG\build-deps\reranker\bge-reranker-v2-m3-ONNX `
  -OutputDir C:\LocalRAG\dist
```

**終了コード 0**。所要時間 09:33:38 → 09:46:07（約12分30秒）。

### 経過

| 工程 | 結果 |
|---|---|
| [1/7] app（server/collector + node_modules） | OK |
| [2/7] runtime（node v22.20.0 / ollama 0.31.2） | OK |
| [3/7] WinSW + service XML | OK |
| [4/7] models | `gemma4:12b`（5 blobs）/ `bge-m3:latest`（3 blobs）/ reranker ONNX int8 | 
| [5/7] scripts / config / fixtures / docs / licenses | OK |
| [6/7] versions.lock | OK |
| [7/7] checksums | **100,624ファイル**をハッシュ |
| zip | 2GB超ファイルがあるため `tar.exe` を使用（設計どおり） |
| Setup.exe | `build-setup.ps1` が export から自動起動。**26,624 bytes** |

`versions.lock`（生成物の実測）

```
package_version=1.2.6
build_date=2026-07-28T09:36:18+09:00
node=v22.20.0
ollama=0.31.2
models=gemma4:12b, bge-m3:latest
reranker=onnx-community/bge-reranker-v2-m3-ONNX (int8)
source_dir=C:\LocalRAG\src
```

B-5 は export-windows.ps1 の末尾から自動的に呼ばれるため、`build-setup.ps1` の単独再実行は不要だった。

---

## 5. B-6 / B-7: 配置と SHA-256 検証

### 旧版の退避（削除ではなく移動）

Setup.exe は隣接する `OTE-RAG-win64-v*.zip` を**1個だけ** glob 要求する
（`OTE-RAG-Setup.cs` L37-46。複数あるとエラー）ため、export 実行前に v1.2.5 の3点を
**`C:\LocalRAG\dist-archive\v1.2.5\` へ移動**した（削除していない）。

```
C:\LocalRAG\dist-archive\v1.2.5\OTE-RAG-Setup.exe
C:\LocalRAG\dist-archive\v1.2.5\OTE-RAG-win64-v1.2.5.zip
C:\LocalRAG\dist-archive\v1.2.5\OTE-RAG-win64-v1.2.5.zip.sha256
```

`C:\LocalRAG\dist\` の `OTE-RAG-win64-v*.zip` は**1個**であることを実測確認済み。

### 生成物（サイズと SHA-256）

| ファイル | サイズ (bytes) | SHA-256 |
|---|---|---|
| `OTE-RAG-win64-v1.2.6.zip` | **11,018,859,839** | `19efde29ae6516dcd3639b78325843f1580661bc7146b210755fa5855f94127a` |
| `OTE-RAG-Setup.exe` | **26,624** | `9b8b620f3a600cc3e953a0741b940627a40d84dc61e75c50a6925883d04f5729` |
| `OTE-RAG-win64-v1.2.6.zip.sha256` | 92 | （上記zipハッシュを記載） |

（参考）v1.2.5: zip `b2b1dc702a67cadf0711bbcdecf53a8ba73fe2355a05bc96c31b760d3f651930` / 11,018,845,698 bytes、
Setup.exe `b310e85c82a222ed1f4f309dc5a265ae459ee02e0d685225ab3195b5365e5a2e`。
Setup.exe はソース（`OTE-RAG-Setup.cs`）が無変更でもハッシュが変わるが、これは
C# コンパイラが MVID とビルドタイムスタンプを埋め込むためで、正常。

### 🔴 B-7: SHA-256 整合の実測

```
declared (.sha256): 19efde29ae6516dcd3639b78325843f1580661bc7146b210755fa5855f94127a
actual   (sha256sum): 19efde29ae6516dcd3639b78325843f1580661bc7146b210755fa5855f94127a
→ 一致
```

### 追加検証: zip の中身（セントラルディレクトリ実読）

11GB の zip を展開せずに中身を実読して確認した。

| 確認項目 | 結果 |
|---|---|
| zip 内エントリ数 | 110,826 |
| `app/server/public/index.js` | 存在。**サイズ 2,789,108 bytes / 日時 2026-07-28 09:32:44**（＝今回のビルド） |
| `app/server/public/_index.html` | 存在 |
| `config/server.env.template` | 存在（`LANCE_HYBRID_RERANK=true` を含むことを展開前の同一ファイルで確認済み） |
| `app/server/utils/helpers/productProfile.js` | 存在 |
| `app/server/utils/vectorDbProviders/lance/index.js` | 存在 |
| `versions.lock` / `checksums/package.sha256` | 存在 |

さらに、zip 化前のパッケージディレクトリ内のファイルについて WSL fork との SHA-256 一致を実測した。

| ファイル（パッケージ内 `app/` 配下） | 結果 |
|---|---|
| `server/utils/vectorDbProviders/lance/index.js` | 一致 |
| `server/utils/helpers/productProfile.js` | 一致 |
| `server/utils/helpers/updateENV.js` | 一致 |
| `collector/processSingleFile/convert/asPDF/PDFLoader/index.js` | 一致 |

`app/collector/hotdir` は `__HOTDIR__.md` のみ、`app/server/storage` はリランカーモデル（`models/`）のみで、
顧客環境用にクリーンな状態であることも確認した。

### 後片付け

- zip 化元のステージングディレクトリ `C:\LocalRAG\dist\OTE-RAG-win64-v1.2.6\`（約13GB）を削除
- 作業用に置いた一時 PowerShell スクリプト2本を削除
- `C:\LocalRAGProd` には**一切触れていない**

---

## 6. やらなかったこと（指示どおり）

| 項目 | 状態 |
|---|---|
| クリーンインストールの実機検証 | **未実施**（ユーザーが管理者実行する運用のため） |
| `docs/CODEX_REQUEST_..._2026-07-27.md` §3 の受け入れ条件8項目 | **未検証**。インストール後にしか確認できないため |
| `C:\LocalRAGProd` の削除 | **していない** |
| `git commit` / `push` | **していない**（fork・親リポジトリとも） |
| WSL側 Docker の操作 | **していない** |

したがって、**「設定メニューが顧客向け allowlist どおりに出るか」「非対応URLが拒否されるか」
「RAG が回帰していないか」は未確認のまま**である。インストール後にユーザーまたは Codex が
上記依頼書 §3・§4 の項目を確認する必要がある。

なお、バンドルへの取り込み自体（2026-07-14 の事故の再発有無）は §2 のとおり実測で確認済みで、
これは「ソースにあるのに配布物に入っていない」型の事故が起きていないことを意味する。

---

## 7. 申し送り

### 7.1 🔴 `frontend/.env` が dev 値のまま放置されている（再発する）

`C:\LocalRAG\src\frontend\.env` は今回もビルド後に dev 値へ戻してある。
つまり**次回ビルドでも同じ罠を踏む**。恒久対策の候補:

- (a) `export-windows.ps1` に「`server\public\index.js` に `localhost:3001` が含まれていたら中断」チェックを追加
- (b) frontend ビルド用の `.env.production`（`VITE_API_BASE='/api'`）を fork にコミットする
- (c) ビルド手順を1本のスクリプトにまとめ、`.env` の差し替えを内包させる

**(a) が最も費用対効果が高い**（既存の「ビルドの古さを検出しない」問題への対策と同じ場所に置ける）。

### 7.2 `export-windows.ps1` は依然としてビルドの古さを検出しない

今回は手順で担保したが、スクリプト側の恒久対策は入れていない
（依頼書 §2「将来の恒久対策」は未実施）。7.1 の (a) と併せて対応するのが自然。

### 7.3 🔴 ビルド中に別エージェントが fork を編集した — その変更は v1.2.6 に**入っていない**

ビルド開始時（09:27頃）の fork 作業ツリーは**クリーン**で、HEAD は `2e61181d` だった。
ソース同期はその状態を **09:29:50** に `C:\LocalRAG\src` へ写し取っている。

ところが、ビルド実行中の **09:37:54〜09:46:20** に、別エージェント（Codex と思われる）が
「オフラインインストール堅牢化」と見られる変更を fork に加えていた。

| ファイル | fork 側の更新時刻 |
|---|---|
| `server/utils/helpers/transformersOffline.js`（新規） | 09:37:54 |
| `server/utils/EmbeddingRerankers/native/index.js` | 09:38:38 |
| `server/utils/EmbeddingEngines/native/index.js` | 09:39:14 |
| `collector/utils/transformersOffline.js`（新規） | 09:42:53 |
| `collector/utils/WhisperProviders/localWhisper.js` | 09:42:58 |
| `server/utils/boot/verifyBundledAssets.js`（新規） | 09:45:25 |
| `server/utils/boot/index.js` | 09:45:38 |
| `collector/utils/OCRLoader/index.js` | 09:46:20 |

関連ドキュメントとして `docs/OFFLINE_INSTALL_HARDENING_2026-07-28.md`（09:50:22 作成）も追加されている。

**これらは v1.2.6 に含まれない。** 根拠:

1. すべての更新時刻が、ソース同期（09:29:50）と export の app コピー工程（09:33:38〜）より**後**である
2. `C:\LocalRAG\src` は WSL 側 fork とは独立した Windows 上のコピーであり、
   同期は 09:29:50 の rsync 1回のみ。以降 fork 側の編集は伝播しない
3. ビルド完了後に `rsync --checksum --dry-run` を再実行したところ、
   **上記8ファイルちょうどが差分として検出された**（同期直後は差分ゼロだった）

したがって **v1.2.6 は commit `2e61181d` 時点のスナップショットとして正しく閉じている**が、
オフラインインストール堅牢化の作業は**次のビルド（v1.2.7 相当）に持ち越し**となる。
その作業が配布に必要なら、**完了後に再ビルドが必要**。

### 7.4 未解決のギャップは v1.2.6 でも残っている

`docs/CODEX_REQUEST_WINDOWS_BUILD_SETTINGS_MENU_2026-07-27.md` §6 に記載のとおり、
以下は**この配布物でも塞がっていない**。

- TTS / STT プロバイダーがサーバー側で allowlist 化されていない（API/env 直接編集で外部送信設定が保存できる）
- フロントの URL guard は API 直叩きを塞がない
- ワークスペース単位の Agent Configuration タブは残置

---

## 6. 意思決定ログ

| 日付 | 内容 | 担当 |
|---|---|---|
| 2026-07-28 | v1.2.6 の Windows 配布物をビルド。WSL側 Docker（166問測定）には一切触れず、Windows 側で完結させた | Claude |
