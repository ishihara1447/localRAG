# OTE-RAG 日常運用ガイド（Windows 版）

- 対象バージョン: v1.0.0
- 作成日: 2026-07-10

このガイドは、インストール済みの OTE-RAG を日々使う・管理するための
手順書です。以下、インストール先は既定の `C:\LocalRAG` として説明します
（変更している場合は読み替えてください）。

## 1. ふだんの使い方

OTE-RAG は **Windows サービス**（パソコン起動時に裏で自動的に動く
プログラム）として動作しているため、**毎日の起動・停止操作は不要**です。
パソコンの電源を入れれば自動で立ち上がります。

使うときは、ブラウザ（Microsoft Edge など）で次の URL を開くだけです。

```
http://localhost:3001
```

（インストール時にポート番号を変更した場合は、その番号に読み替えて
ください。）

> パソコン起動直後は、AI モデルの読み込みのため最初の回答に時間が
> かかることがあります。2 回目以降は速くなります。

## 2. 文書の入れ方（アップロード）

1. ブラウザで OTE-RAG を開き、ログインします。
2. 対象の**ワークスペース**（文書をまとめる箱。案件別・分野別に
   作成できます）を開きます。
3. ワークスペース名の横のアップロードアイコン（書類マーク）を
   クリックし、文書ファイルをドラッグ＆ドロップまたは選択します。
4. アップロードした文書を選び、「Move to Workspace」→「Save and Embed」で
   ワークスペースに取り込みます。取り込み処理（文書を検索できる形に
   変換する処理）には文書量に応じて数十秒〜数分かかります。
5. 取り込みが終われば、チャット欄からその文書について質問できます。
   回答には出典（どの文書のどの部分に基づくか）が表示されます。
   文書に書かれていないことを質問した場合は「不明」と答える設計です。

対応ファイルの目安: PDF・Word（.docx）・テキスト（.txt）など。
文字情報を持たないスキャン画像だけの PDF は、内容を読み取れない
場合があります。

## 3. 手動での停止・起動

Windows の再起動時は自動で復帰するため通常は不要ですが、
メンテナンス等で明示的に止めたい場合は、**管理者として実行した
PowerShell**（スタートメニューで「PowerShell」を検索 → 右クリック →
「管理者として実行」）から以下を実行します。

**停止**（文書やチャット履歴は消えません）:

```powershell
cd C:\LocalRAG
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\stop.ps1
```

**起動**:

```powershell
cd C:\LocalRAG
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\start.ps1
```

現在の稼働状況は次のコマンドで確認できます。3 つのサービスがすべて
`Running` なら正常です。

```powershell
Get-Service LocalRAG-*
```

## 4. バックアップ

文書・チャット履歴・設定を 1 つの zip ファイルに保存します。
**週 1 回程度の定期実行を推奨**します。

管理者 PowerShell から:

```powershell
cd C:\LocalRAG
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\backup.ps1
```

- バックアップ中はサービスが**自動で一時停止**され（データの整合性を
  保つため）、完了後に**自動で再開**します。停止している数分間は
  ブラウザから利用できません。業務時間外の実行がおすすめです。
- 保存先（既定）: `C:\ProgramData\LocalRAG\backups\localrag-backup-<日時>.zip`
- 保存先を変えたい場合:

  ```powershell
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\backup.ps1 -OutputDir D:\backups
  ```

- AI モデル本体はバックアップに含まれません（配布パッケージから
  復元できるためです）。
- 作成された zip は、パソコンの故障に備えて**外部媒体（社内サーバーや
  バックアップ用ディスク）にも定期的にコピー**してください。

## 5. 復元（リストア）

バックアップ zip から文書・履歴・設定を書き戻します。
**復元すると現在のデータはバックアップ時点の内容で上書きされる**ため、
実行前に提供元または IT 担当者に相談することをおすすめします。

管理者 PowerShell から（zip のファイル名は実際のものに置き換えて
ください）:

```powershell
cd C:\LocalRAG
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\restore.ps1 -BackupZip C:\ProgramData\LocalRAG\backups\localrag-backup-20260710-090000.zip
```

サービスの停止・再開は自動で行われます。ポート番号などの設定
ファイルまで書き戻す場合は `-RestoreEnv` を付けますが、別の
パソコンへ移す場合など特別な場合以外は不要です。

## 6. データの保存場所

| データ | 保存先 |
|---|---|
| 文書・チャット履歴・検索用データ・設定（データベース） | `C:\LocalRAG\app\server\storage` |
| AI モデル本体 | `C:\ProgramData\LocalRAG\models` |
| 動作記録（ログ） | `C:\ProgramData\LocalRAG\logs` |
| バックアップ（既定） | `C:\ProgramData\LocalRAG\backups` |

すべてこのパソコンの中にあり、外部には送信されません
（詳細は [SECURITY_GUIDE.md](./SECURITY_GUIDE.md) を参照）。
これらのフォルダの中身を手作業で移動・削除しないでください。

## 7. ワークスペースの誤削除防止

本製品は既定で削除保護（`WORKSPACE_DELETION_PROTECTION`）が有効で、
プログラム（API）経由のワークスペース削除は拒否されます。
ワークスペースを削除する場合は、管理者がブラウザの画面上から
明示的に操作してください。

## 8. アンインストール

管理者 PowerShell から:

```powershell
cd C:\LocalRAG
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

- **既定ではデータは削除されません。** 文書・履歴などのデータは
  `C:\ProgramData\LocalRAG\uninstalled-<日時>\storage` に退避され、
  再インストール後に復元できます。AI モデル・ログ・バックアップも
  残ります。
- データも含めて**完全に削除**する場合は `-RemoveData` を付けます
  （元に戻せません。実行前に必ずバックアップを検討してください）:

  ```powershell
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1 -RemoveData
  ```

## 9. 困ったときは

[TROUBLESHOOTING.md](./TROUBLESHOOTING.md) を参照してください。
