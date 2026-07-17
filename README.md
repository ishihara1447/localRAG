# OTE-RAG

OTE-RAG は、顧客の Windows PC だけで動く日本語 RAG パッケージです。所内文書をアップロードし、文書に基づく回答と出典を確認できます。クラウド AI に文書や質問を送らないことを前提に、AnythingLLM の fork を Windows native 配布向けに整備しています。

現在の顧客配布ターゲット: **OTE-RAG Windows native v1.2.0**  
配布方針: **Windows 11 に直接インストール**。顧客環境に WSL / Docker は不要です。
インストールは `OTE-RAG-Setup.exe` の**ダブルクリック**で完結します（zip 展開や PowerShell の手入力は不要）。

## まず絵で見る

### インストールとアンインストール

<img src="docs/customer-windows/onepagers/01_install-uninstall.svg" alt="OTE-RAG のインストールとアンインストール" width="100%">

### ふだんの使い方

<img src="docs/customer-windows/onepagers/02_usage-overview.svg" alt="OTE-RAG の使い方概要" width="100%">

### 文書を取り込んで質問する

<img src="docs/customer-windows/onepagers/03-1_usage-upload.svg" alt="OTE-RAG の文書アップロードと質問の流れ" width="100%">

### バックアップと復元

<img src="docs/customer-windows/onepagers/03-2_usage-backup.svg" alt="OTE-RAG のバックアップと復元" width="100%">

### 日常の管理と保存場所

<img src="docs/customer-windows/onepagers/03-3_usage-manage.svg" alt="OTE-RAG のサービス管理と保存場所" width="100%">

### 制約と注意事項

<img src="docs/customer-windows/onepagers/04_constraints-notes.svg" alt="OTE-RAG の制約と注意事項" width="100%">

## この製品でできること

OTE-RAG は、顧客 PC 内の文書を検索対象にして、チャット形式で質問できるようにします。回答には出典を表示し、文書に書かれていない内容は「不明」と答える設計です。

Windows native 版では、次の 3 つの Windows サービスとして動作します。

- `LocalRAG-Server`: 画面、API、回答生成の本体
- `LocalRAG-Collector`: 文書の読み取りと取り込み処理
- `LocalRAG-Ollama`: ローカル AI モデルの実行エンジン

利用者は同じ PC のブラウザで次の URL を開きます。

```text
http://localhost:3001
```

## 同梱する AI モデル（すべてローカル実行）

| 役割 | モデル | ライセンス |
|---|---|---|
| 回答生成（LLM） | Google **Gemma 4 12B**（`gemma4:12b`） | Apache-2.0 |
| 文書検索（Embedding） | BAAI **bge-m3** | MIT |
| 再順位付け（Reranker / 文抽出クッション） | BAAI **bge-reranker-v2-m3**（ONNX int8） | MIT |

検索は日本語 bi-gram BM25 と dense 検索を RRF で融合するハイブリッド方式が既定で、
検索後にリランカーで文単位の再順位付け（「文抽出クッション」）を行い、関連する文と
その周辺のみを LLM へ渡します。詳細は [モデルカード](docs/MODEL_CARDS.md) を参照してください。

## 重要な前提条件

- OS: Windows 11、または Windows 10 21H2 以降
- GPU: NVIDIA GPU、VRAM 16GB 級
- ディスク: インストール先ドライブに 20GB 以上の空き容量
- 権限: インストール、サービス操作、バックアップ、復元、アンインストールには Windows 管理者権限が必要
- ネットワーク: インストールにも日常利用にもインターネット接続は不要
- ポート: 画面用に `3001`、内部処理用に `8888` と `11435` を使用

既定のインストール先は `C:\LocalRAG` です。モデル、ログ、バックアップは `C:\ProgramData\LocalRAG` 配下に保存されます。

## セキュリティとデータの扱い

OTE-RAG はローカル完結を前提にしています。

- 顧客文書、質問、回答、チャット履歴、検索用データは顧客 PC 内に保存します。
- OpenAI / Anthropic / Google Gemini などの外部 AI provider は有効化しません。
- Telemetry、Swagger docs、Web scraping、実行時のモデルダウンロードは無効化します。
- AI 実行エンジンは `127.0.0.1:11435` で待ち受け、PC 内部からのみ使います。
- バックアップ zip には文書と履歴が含まれるため、機密文書と同じ扱いで保管してください。
- `LICENSES/` と `NOTICE` に含まれる OSS / モデルのライセンス表示は削除しないでください。

## インストールの要点

配布物は次の 3 ファイルです（zip はモデルを含むため約 11GB あります）。

```text
OTE-RAG-Setup.exe
OTE-RAG-win64-v1.2.0.zip
OTE-RAG-win64-v1.2.0.zip.sha256
```

3 ファイルを同じフォルダに置き、`OTE-RAG-Setup.exe` を**ダブルクリック**するだけです。
Setup.exe（.NET Framework 製の GUI、外部ランタイム不要）が UAC 昇格・外側 zip の SHA-256 検証・
展開・アプリのチェックサム検証・環境設定生成・DB 初期化・サービス登録・起動・API 疎通確認・
ブラウザ起動までを自動で行います。

> 現時点の Setup.exe はコード署名証明書を未取得のため、Windows が「不明な発行元」と
> 表示する場合があります。正式出荷前に組織のコード署名証明書での署名を推奨します。

障害調査などで手動インストールが必要な場合は、zip を Windows エクスプローラーの
「すべて展開」または `tar.exe -xf` で展開し（`Expand-Archive` はサポート対象外）、
管理者 PowerShell で `install.ps1` を実行します。詳細は
[Windows 顧客向けインストールガイド](docs/customer-windows/INSTALL_GUIDE.md) を参照してください。

## 日常運用

通常の利用者は、ブラウザで `http://localhost:3001` を開くだけです。Windows 起動時に 3 つのサービスが自動起動します。

管理者向けの主な操作は、インストール先フォルダで実行します。

```powershell
.\start.ps1
.\stop.ps1
.\backup.ps1
.\restore.ps1 -BackupZip <backup.zip>
.\uninstall.ps1
```

バックアップは既定で `C:\ProgramData\LocalRAG\backups` に作成されます。AI モデル本体と実行バイナリは、配布パッケージから復元できるためバックアップ対象外です。

## 現在の検証状況

Windows native v1.2.0 は、`OTE-RAG-Setup.exe` によるダブルクリックでの管理者インストールを
実機で通過しています（2026-07-17）。確認済みの範囲は、外側 zip の SHA-256 検証、展開、
アプリのチェックサム検証、DB マイグレーション、3 サービス（Server / Collector / Ollama）の
登録・自動起動、各ポート（3001/8888/11435）の待受、UI・各 API の応答、GPU 上での
`gemma4:12b` / `bge-m3` のロード、日本語 embedding（1024 次元）、Gemma の日本語生成です。
これに先立ち、v1.2.0 zip の全ファイルチェックサム検証（PASS 約 10 万件）も通過しています。

リリース前の仕上げ確認として、Setup.exe の**コード署名（現状は未署名）**、
Windows 再起動後の自動復帰、ネットワークを完全に切断した状態での通し検証、
API キー発行と実文書を用いた RAG E2E が残っています。最新状況は
[docs/HANDOFF.md](docs/HANDOFF.md) を参照してください。

## 詳細ドキュメント

- [Windows 顧客向けインストールガイド](docs/customer-windows/INSTALL_GUIDE.md)
- [Windows 顧客向け日常運用ガイド](docs/customer-windows/OPERATIONS_GUIDE.md)
- [Windows 顧客向けセキュリティガイド](docs/customer-windows/SECURITY_GUIDE.md)
- [Windows 顧客向けトラブルシューティング](docs/customer-windows/TROUBLESHOOTING.md)
- [モデルカード](docs/MODEL_CARDS.md)
- [最新ハンドオフ](docs/HANDOFF.md)
- [顧客配布計画](docs/anythingllm_customer_distribution_plan.md)
