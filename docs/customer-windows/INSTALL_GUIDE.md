# OTE-RAG インストールガイド（Windows 版）

- 対象バージョン: v1.0.0
- 作成日: 2026-07-10

このガイドは、OTE-RAG（所内文書を検索して回答する AI システム）を
Windows パソコン 1 台にインストールする手順を説明します。
インストールは通常 1 回だけの作業です。IT 担当者または提供元の
エンジニアが実施することを想定していますが、手順どおりに進めれば
どなたでも実施できます。

## 1. 必要なもの（前提条件）

| 項目 | 条件 |
|---|---|
| OS | Windows 11（Windows 10 21H2 以降でも動作します） |
| GPU | NVIDIA 製 GPU、ビデオメモリ（VRAM）16GB 以上（RTX 5070 Ti 相当）。NVIDIA ドライバ導入済みであること |
| ディスク空き容量 | 20GB 以上（インストール先ドライブ） |
| 権限 | Windows の管理者権限（インストール時のみ必要） |
| インターネット接続 | **不要**（インストールも利用もオフラインで完結します） |

> **GPU / VRAM とは**: AI の計算を高速に行う部品（グラフィックボード）と
> その専用メモリのことです。お使いのパソコンが条件を満たすか不明な場合は、
> 提供元にお問い合わせください。

また、以下のポート（パソコン内部の通信の窓口番号）を他のソフトが
使っていないことが必要です。使用中の場合はインストール時に自動検出され、
エラーメッセージが表示されます。

- **3001**（画面表示用。`-ServerPort` オプションで変更可能）
- **8888** と **11435**（内部処理用。固定）

## 2. 配布パッケージの内容

配布物は `LocalRAG-win64-v1.0.0.zip` という 1 つの zip ファイルです
（モデルを含むため数 GB あります）。展開すると以下の構成になります。

```
LocalRAG-win64-v1.0.0\
  install.ps1                インストール用スクリプト
  uninstall.ps1              アンインストール用
  start.ps1 / stop.ps1       手動での起動・停止
  backup.ps1 / restore.ps1   バックアップ・復元
  rag-e2e-test.ps1           詳細動作確認（IT 担当者向け）
  app\                       アプリケーション本体
  runtime\                   実行環境（Node.js / Ollama）
  models\                    AI モデル本体（日本語 LLM・検索用モデル）
  winsw\                     Windows サービス登録用
  config\                    設定ファイルのひな形
  checksums\                 改ざん・破損検知用チェックサム
  fixtures\                  動作確認用サンプル文書
  LICENSES\ / NOTICE         ライセンス情報
  docs\                      本ガイドを含むドキュメント
  versions.lock              同梱ソフトのバージョン固定情報
```

## 3. パッケージの受け渡しと展開

### 3-1. パソコンへのコピー

USB メモリまたは社内 LAN 経由で、zip ファイルをインストール先
パソコンにコピーします（例: `C:\Users\<ユーザー名>\Downloads`）。

> FAT32 形式の USB メモリは 4GB を超えるファイルを扱えません。
> exFAT または NTFS 形式の USB メモリを使用してください。

### 3-2. zip の展開（重要）

展開方法は次の **どちらか** を使ってください。

**方法 A: エクスプローラーで展開**

zip ファイルを右クリック →「すべて展開」を選び、展開先を指定します。

**方法 B: コマンドで展開（tar.exe）**

PowerShell（スタートメニューで「PowerShell」と検索して起動。この段階では
管理者権限は不要です）で、zip を置いたフォルダに移動して実行します。

```powershell
cd C:\Users\<ユーザー名>\Downloads
tar.exe -xf .\LocalRAG-win64-v1.0.0.zip
```

ファイル数が多いため、展開には数分〜十数分かかることがあります。

> **注意: PowerShell の `Expand-Archive` コマンドは使用しないでください。**
> サポート対象外の展開方法であり、正常なインストールを保証できません。
> 必ず上記の方法 A または方法 B で展開してください。

## 4. インストール手順

### 4-1. 管理者として PowerShell を開く

1. スタートメニューで「PowerShell」と検索します。
2. 「Windows PowerShell」を**右クリック**し、
   「**管理者として実行**」を選びます。
3. 「このアプリがデバイスに変更を加えることを許可しますか？」と
   表示されたら「はい」を選びます。

### 4-2. インストーラを実行する

開いた PowerShell で、展開したフォルダに移動してインストーラを
実行します（2 行とも、そのままコピーして貼り付けできます）。

```powershell
cd C:\Users\<ユーザー名>\Downloads\LocalRAG-win64-v1.0.0
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

インストール先やポート番号を変えたい場合は、オプションを付けて
実行します（通常は不要です）。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -InstallRoot D:\LocalRAG -ServerPort 3002
```

- 既定のインストール先: `C:\LocalRAG`
- 既定のポート番号: `3001`

### 4-3. インストーラが自動で行うこと

1. **事前チェック（preflight）** — 管理者権限・OS バージョン・
   NVIDIA GPU と VRAM 容量・ディスク空き容量・ポートの空き・
   既存インストールの有無を確認します。問題があれば、その場で
   理由を表示して停止します（ファイルは変更されません）。
2. **チェックサム検証** — パッケージの全ファイルが壊れて
   いないか・改ざんされていないかを 1 ファイルずつ確認します。

   > **この工程では 20〜40 分ほど画面に何も表示されない時間が
   > あります。これは正常です。** ウィンドウを閉じたり、パソコンを
   > 操作して中断したりせず、そのままお待ちください。
3. **ファイルのコピー** — アプリ本体をインストール先へ、AI モデルを
   `C:\ProgramData\LocalRAG\models` へコピーします。
4. **設定ファイルの生成とデータベースの初期化**
5. **Windows サービスの登録と起動** — 次の 3 つのサービス
   （Windows が裏で自動的に動かすプログラム）が登録されます。
   いずれもパソコン起動時に自動で立ち上がり、異常終了しても
   自動で再起動します。
   - `LocalRAG-Server`（画面と回答生成の本体）
   - `LocalRAG-Collector`（文書の読み取り処理）
   - `LocalRAG-Ollama`（AI モデルの実行エンジン）
6. **疎通確認** — サーバーが応答するまで最大 120 秒待ちます。

最後に次のように表示されればインストール完了です。

```
=== Install complete ===
UI:            http://localhost:3001
Services:      LocalRAG-Server / LocalRAG-Collector / LocalRAG-Ollama (automatic start)
Data:          C:\LocalRAG\app\server\storage
Logs:          C:\ProgramData\LocalRAG\logs
```

エラーで停止した場合は、表示されたメッセージを控えて
[TROUBLESHOOTING.md](./TROUBLESHOOTING.md) を参照してください。

## 5. 初期設定（最初のログイン）

1. 同じパソコンのブラウザ（Microsoft Edge など）で
   `http://localhost:3001` を開きます。
2. 初回はセットアップ画面が表示されるので、案内に従って管理者
   アカウント（ログイン用のユーザー名とパスワード）を作成して
   ください。パスワードは所内の規程に従って安全に保管してください。
3. ログイン後、「ワークスペース」（文書をまとめる箱のようなもの）を
   作成すれば利用開始できます。日常の使い方は
   [OPERATIONS_GUIDE.md](./OPERATIONS_GUIDE.md) を参照してください。

## 6. インストール後の動作確認（任意・IT 担当者向け）

文書のアップロードから回答・出典表示までを自動で通し確認する
テストスクリプトを同梱しています。画面右上の Settings → API Keys で
API キーを発行したうえで、管理者 PowerShell から実行してください。

```powershell
cd C:\LocalRAG
$env:LOCALRAG_API_KEY = "<発行したAPIキー>"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\rag-e2e-test.ps1
```

## 7. 困ったときは

[TROUBLESHOOTING.md](./TROUBLESHOOTING.md) を参照してください。
解決しない場合は提供元にご連絡ください。
