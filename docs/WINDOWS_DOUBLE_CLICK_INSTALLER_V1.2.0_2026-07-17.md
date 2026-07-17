# OTE-RAG ダブルクリックインストーラー実装・検証結果

- 実施日: 2026-07-17
- 対象: Windows native v1.2.0
- 状態: 修正版GUIによる管理者実インストールと基本動作確認まで合格。

## 結論

顧客側では、次の3ファイルを同じフォルダに置き、
`OTE-RAG-Setup.exe` をダブルクリックするだけでインストーラーを起動できる。

```text
OTE-RAG-Setup.exe
OTE-RAG-win64-v1.2.0.zip
OTE-RAG-win64-v1.2.0.zip.sha256
```

Setup.exe は UAC 昇格、外側ZIPのSHA-256検証、一時展開、
既存 `install.ps1` の実行、完了後のブラウザ起動を担当する。
ZIP展開やPowerShellコマンド入力は通常手順から除外した。

## 最終成果物

| ファイル | サイズ |
|---|---:|
| `C:\LocalRAG\dist\OTE-RAG-Setup.exe` | 23,552 bytes |
| `C:\LocalRAG\dist\OTE-RAG-win64-v1.2.0.zip` | 11,019,242,796 bytes |
| `C:\LocalRAG\dist\OTE-RAG-win64-v1.2.0.zip.sha256` | 92 bytes |

ZIP SHA-256:

```text
7f49942ce9387bfc6922a485f43debef6fce0f27c272823c643b36cdbe5911ff
```

Setup.exe SHA-256（実機検証済み修正版）:

```text
61af9b89c2dc0dabbb453021f3d80a3bd20420c2a01f676b565785b63ce90107
```

## 実装

- `windows-native/Install-OTE-RAG.cmd`
  - ZIPを手動展開した場合のダブルクリック用フォールバック。
  - UAC自己昇格後、同じフォルダの `install.ps1` を実行する。
  - `--self-test` で非破壊の同梱確認ができる。
- `windows-native/setup/OTE-RAG-Setup.cs`
  - .NET Framework WinForms製のGUIブートストラッパー。
  - Windows標準機能だけで動作し、外部ランタイムを要求しない。
  - ZIPは横に1個だけ存在することを要求し、対応する `.sha256` がない場合は停止する。
  - 空欄、UNC、ドライブ直下のインストール先を拒否する。
  - ログは `C:\ProgramData\OTE-RAG\InstallerLogs` に保存する。
  - 長いnode_modulesもWindowsのパス長内に収めるため、一時展開先は `C:\OTR\<timestamp>` を使う。
- `windows-native/setup/build-setup.ps1`
  - Windows標準の .NET Framework C# コンパイラでSetup.exeを生成する。
- `windows-native/export-windows.ps1`
  - ZIP生成後、外側SHAファイルとSetup.exeを自動生成する。
  - ZIP内へ `Install-OTE-RAG.cmd` を同梱する。
- `docs/customer-windows/INSTALL_GUIDE.md`
  - Setup.exeのダブルクリックを通常手順へ変更。
  - 従来の展開・PowerShell手順は障害調査用として残した。

## 検証結果

| 検証 | 結果 |
|---|---|
| Windows標準C#コンパイラでGUIビルド | PASS |
| Setup.exeアセンブリ読込・アイコン組込 | PASS |
| 外側ZIP SHA-256 | PASS |
| Setup.exe `--verify-only` 正常系 | PASS（exit 0） |
| 意図的なSHA不一致の拒否 | PASS（exit 2） |
| 新ZIPを別ディレクトリへ完全展開 | PASS |
| 内部 `package.sha256` 全件 | PASS 100,635 / FAIL 0 |
| ZIP内 `Install-OTE-RAG.cmd` | 存在確認PASS |
| CMD `--self-test` | PASS（exit 0） |
| 一時検証環境の削除 | 完了 |

## 管理者GUI実機確認

初回実行では、ユーザープロファイル配下の長い一時展開先により、深い
`node_modules` の89ファイルが展開されず内部checksumで停止した。製品ZIPの
破損ではない。展開先を `C:\OTR\<timestamp>` へ短縮し、最長2ファイルを
フルパス最大255文字で実展開できることを確認してからSetup.exeを再ビルドした。

修正版で次を指定して再実行し、2026-07-17 12:39:19に完了した。

- インストール先: `C:\LocalRAGProd`
- 画面ポート: `3005`
- インストールログ: `C:\ProgramData\OTE-RAG\InstallerLogs\setup-20260717-123416.log`

| 実機確認 | 結果 |
|---|---|
| 外側SHA・短縮パス展開・内部checksum | PASS |
| DB migration・サービス登録 | PASS |
| Server / Collector / Ollama | 3件ともRunning・Automatic |
| localhost待受 | 3005 / 8888 / 11435 |
| UI / Server ping / Collector / Ollama API | すべてHTTP 200 |
| Ollamaモデル | `gemma4:12b` / `bge-m3:latest` |
| 日本語Embedding | PASS、1024次元 |
| Gemma日本語生成 | PASS、`動作確認完了` |
| サービス標準エラーログ | 3件とも0 bytes |

補足: インストールログのPrisma migration一覧でツリー記号が文字化けするが、
`All migrations have been successfully applied.` と記録され、DB移行と起動には影響しない。
表示品質上の軽微な改善候補として残す。

新規インストール直後でAPIキーと顧客文書がないため、文書投入を含むRAG E2Eは
今回の基本動作確認には含めていない。再起動耐性と完全オフライン確認も正式出荷前に残る。

## コード署名

このPCにはコード署名証明書と `signtool.exe` がないため、
Setup.exeは未署名である。Windowsが「不明な発行元」と表示する可能性がある。
IT担当者による導入検証は可能だが、一般顧客への正式出荷前には
組織のコード署名証明書で署名し、署名検証を配布工程へ追加することを推奨する。

## Git

この作業ではコミット・pushを実施していない。
