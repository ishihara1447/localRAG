# Codex 作業依頼（第2ラウンド）: 管理者権限での実機インストール検証

作成日: 2026-07-10（Claude Code）
前回結果: `docs/WINDOWS_NATIVE_BUILD_VERIFY_RESULT_2026-07-09.md`（Part A成功・Part B権限不足で中断）
診断: `docs/WINDOWS_NATIVE_EXPAND_ARCHIVE_HANG_DIAGNOSIS_2026-07-10.md`（ハング原因の切り分け完了）

## 前回からの変化（先に読むこと）

1. **Expand-Archiveハングは診断済み・成果物の欠陥ではない**。zipもinstall.ps1も正常（全ハッシュ一致を確認済み）。原因は展開セッションが書いたファイル実体に残った開発機ローカルのフィルタドライバ状態。**今回から展開は`tar.exe -xf`を正式手順とする**（`Expand-Archive`は使用禁止）。
2. **Ollama「0.23.0」問題は誤解と解明**。`ollama --version`の1行目は接続先サーバー（=ポート11434のWSL Docker側）のバージョン。同梱exeは`Warning: client version is 0.31.2`のとおり**正しくv0.31.2**。再ダウンロード不要。
3. `export-windows.ps1`のversions.lock生成をclient行優先に修正済み（zipの再生成は不要。既存zipはそのまま使ってよい）。

## 今回の作業: Part B検証（管理者権限）

**ビルド済みzip（`C:\LocalRAG\dist\LocalRAG-win64-v1.0.0.zip`）をそのまま使う。再ビルド不要。**

### B2-0. 管理者権限の確保（前回のブロッカー）

```powershell
# 現在のセッションが管理者か確認
([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
```

- `True`ならそのまま進む。
- `False`の場合: `Start-Process powershell -Verb RunAs` で昇格ウィンドウを開いて作業する。
- **Codexセッションの制約で昇格が不可能な場合は、無理をせず**、以下をそのまま実行できる形で報告書に貼ってユーザーに実行を依頼し、実行後のコンソール出力を受け取って検証を続行すること（インストール本体だけ人間、確認コマンドはCodexでも可）。

### B2-1. クリーン化と展開

```powershell
# 前回の残骸削除（ハング状態のファイルが削除に失敗する場合があるが、失敗しても続行してよい。結果だけ記録）
Remove-Item -Recurse -Force C:\Temp\localrag-install -ErrorAction Continue
Remove-Item -Recurse -Force C:\LocalRAGProd -ErrorAction Continue

# 新しいディレクトリにtar.exeで展開（Expand-Archiveは使わない）
mkdir C:\Temp\localrag-verify
cd C:\Temp\localrag-verify
tar.exe -xf C:\LocalRAG\dist\LocalRAG-win64-v1.0.0.zip
# 目安: 数分（6GB）。進捗表示は出ないが待つこと
```

### B2-2. インストール実行

**ポートは`-ServerPort 3005`を指定する**。理由: 3001は`wslrelay.exe`が使用中で、解放には`wsl --shutdown`が必要だが、**それはWSL上で動いているClaude Codeセッションを強制終了させてしまう**ため今回は避ける。`-ServerPort`パラメータの検証を兼ねる。

```powershell
cd C:\Temp\localrag-verify\LocalRAG-win64-v1.0.0
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -InstallRoot C:\LocalRAGProd -ServerPort 3005
```

チェックサム検証（10万ファイル）に時間がかかる。**目安20〜40分、ハングと誤認しないこと**（[checksum]の後に沈黙が続くのは正常）。急ぐ場合でも`-SkipChecksum`は使わず、実測時間を報告に記録する（顧客の体感時間として重要なデータ）。

**確認ポイント（報告に含める）**:
- preflight全項目の出力（そのまま貼る）
- `Get-Service LocalRAG-*` → 3本ともRunning
- ブラウザ（またはcurl）で `http://localhost:3005` が開く
- `C:\ProgramData\LocalRAG\logs\` に3サービスのログが生成されている

### B2-3. GPU動作の確認（今回の重要ポイント）

**未検証の核心**: Windowsサービス（Session 0・LocalSystem）として起動したOllamaがGPU（CUDA）を使えるか。前回PoCはユーザーセッションでの手動起動だったため、ここが今回初の検証になる。

```powershell
# 専用Ollamaサービス(11435)にモデルロード状況を確認（E2E実行後に見るのが確実）
curl.exe -s http://127.0.0.1:11435/api/ps
# → "100% GPU" 相当の表示があるか。CPU動作になっていたら、その事実と応答速度を記録
```

**もしCPU動作だった場合**: 即失敗ではない（E2Eは通る可能性が高い）が、応答速度を記録し報告すること。サービスのGPUアクセス制約が原因なら、Claude Code側でサービス実行アカウントの変更等を検討する。

### B2-4. RAG E2E（11項目、まずPS5.1で）

```powershell
# APIキー: ブラウザ http://localhost:3005 → Settings → API Keys で発行
cd C:\LocalRAGProd
$env:LOCALRAG_API_KEY = "<発行したキー>"
$env:LOCALRAG_BASE_URL = "http://localhost:3005"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\rag-e2e-test.ps1
```

- 合格ライン: 11/11 PASS。
- **まず`powershell.exe`（5.1）で実行**（UTF-8 BOM対応の実地検証）。文字化けやparser errorが出たらpwshで再実行し、両方の結果を記録。
- 既知の仕様: テスト用ワークスペース`localrag-smoketest`が削除保護により残る（正常。UIから手動削除可）。
- 1問あたりの応答時間の体感も記録（Docker版6.4秒/6stepとの比較材料）。

### B2-5. 運用スクリプト検証

```powershell
cd C:\LocalRAGProd
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\backup.ps1
# → C:\ProgramData\LocalRAG\backups\ にzip生成、サービスがRunningに自動復帰すること
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\stop.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\start.ps1
curl.exe -s http://localhost:3005/api/ping   # {"online":true}
```

### B2-6. 再起動耐性（可能なら）

Windowsを再起動できる状況なら、再起動後にサービス3本が自動起動（Automatic）で復帰し、`/api/ping`が通ることを確認。再起動できない場合はスキップしてよい（その旨記録）。

### B2-7. アンインストール（データ温存確認）

```powershell
cd C:\LocalRAGProd
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

- `Get-Service LocalRAG-*` が空・`C:\LocalRAGProd`がほぼ空（uninstall.ps1自身は残る仕様）
- データが `C:\ProgramData\LocalRAG\uninstalled-<日時>\storage` に温存されている
- `C:\ProgramData\LocalRAG\models` が残っている

### B2-8. 後片付け

- `C:\Temp\localrag-verify` と `C:\ProgramData\LocalRAG` を削除（zipは残す）
- 前回の `C:\Temp\localrag-install` が削除できていなければその旨記録（Claude側で対処を検討）

## 予想される障害と対策（事前に読んでおくこと）

| # | 起こりうる障害 | 対策 |
|---|---|---|
| 1 | 管理者昇格ができない | B2-0の代替手順（ユーザー実行依頼ブロックを報告書に用意）へ切り替え。**セッション終了せず確認系コマンドだけでも進める** |
| 2 | install.ps1のchecksum検証が数十分沈黙 | 正常。CPU使用率が動いていれば待つ。1時間超えたら中断して経過を記録 |
| 3 | サービス起動失敗（LocalRAG-Server が起動しない等） | `C:\ProgramData\LocalRAG\logs\LocalRAG-*.err.log`と`.out.log`を確認し、そのまま報告に貼る。**推測で直そうとせずログ収集を優先** |
| 4 | Ollamaサービスがモデルを見つけられない | `C:\ProgramData\LocalRAG\models\manifests`と`blobs`の存在を確認。`OLLAMA_MODELS`はサービスXMLで指定済みのため、パス実体だけ確認して報告 |
| 5 | GPUがCPU fallbackになる（Session 0制約） | 失敗ではない。`/api/ps`出力・応答速度を記録して報告（Claude側で対策検討） |
| 6 | E2EがPS5.1でparser error | pwshで再実行して結果を取得しつつ、5.1のエラー全文を報告（BOM対応の再修正はClaude側で行う） |
| 7 | prisma migrateがネットワークアクセスを試みて遅延 | 今回はオンライン環境なので致命的ではないが、目立つ遅延があれば記録（次回オフライン検証で`CHECKPOINT_DISABLE=1`を入れる判断材料になる） |
| 8 | ポート3005も使用中 | preflightがowner processを表示して中止する（それ自体が正しい動作）。別の空きポート（3006等）で再実行 |

## 報告テンプレート（docs/WINDOWS_NATIVE_VERIFY_ROUND2_RESULT_2026-07-10.md）

```markdown
# Windows Native 検証（第2ラウンド）結果
作成日: / 担当: Codex

- B2-0 管理者権限: 昇格方法 / 代替手順の要否
- B2-1 クリーン化・tar展開: OK/NG（所要時間、旧ディレクトリ削除の成否）
- B2-2 install.ps1: preflight出力貼付 / checksum所要時間 / サービス状態 / UI: OK/NG
- B2-3 GPU: /api/ps の出力（GPU or CPU）、応答速度の体感
- B2-4 E2E: PS5.1での結果11項目（NGならpwshの結果も）、応答時間の体感
- B2-5 backup/stop/start: OK/NG
- B2-6 再起動耐性: 実施有無と結果
- B2-7 uninstall: OK/NG（データ温存パス確認）
- B2-8 後片付け: 完了状況
- 発生した障害と対処（上記対策表のどれに該当したか）:
- Claude Codeへの修正依頼・気づき:
```
