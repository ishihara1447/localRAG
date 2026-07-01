# インストールガイド

## 前提条件

- Docker Engine + Docker Compose v2 がインストール済みであること
  （インターネット接続は不要です）。
- NVIDIA GPU をお使いの場合は、NVIDIA ドライバと
  nvidia-container-toolkit が導入されていること（無くても動作しますが
  応答速度が大きく低下します）。
- ディスク空き容量: 最低 30GB、推奨 100GB 以上。
- ポート 3001 が他のアプリケーションで使用されていないこと。

## パッケージの内容

配布されたフォルダには、以下が含まれています。

```
localrag-<バージョン>/
  install.sh              インストール用スクリプト
  uninstall.sh             アンインストール用スクリプト
  start.sh / stop.sh       起動・停止
  backup.sh / restore.sh   バックアップ・復元
  smoke-test.sh            簡易動作確認
  rag-e2e-test.sh          RAG動作の詳細確認
  docker-compose.yml       サービス定義
  versions.lock            バージョン・イメージ固定情報
  checksums/               改ざん検知用チェックサム（必須）
  images/                  Docker イメージ本体
  ollama-models/           LLM・embedding モデル本体
  fixtures/                動作確認用サンプル文書
  LICENSES/ NOTICE         ライセンス情報
```

## インストール手順

1. 配布されたフォルダ一式を、USB メモリまたは社内 LAN 経由で
   インストール先マシンにコピーします。
   （FAT32 形式の USB は 4GB を超えるファイルを扱えません。
   exFAT または NTFS 形式を使用してください。）
2. コピーしたフォルダに移動し、以下を実行します。

   ```bash
   cd localrag-<バージョン>
   bash install.sh
   ```

3. `install.sh` は以下を自動で行います。

   - Docker / GPU 等の前提条件チェック
   - チェックサムによるパッケージ真正性の検証
     （ファイルが壊れている・改ざんされている場合はここで停止します）
   - Docker イメージの読み込み
   - サービスの起動と起動完了待機

4. 「インストール完了」と表示されたら、ブラウザで
   `http://localhost:3001` にアクセスします。

## 初期ログイン

初回アクセス時は、AnythingLLM のセットアップ画面に従って管理者
アカウントを作成してください。マルチユーザー機能を使わない場合は
シングルユーザーモードのまま利用できます。

API 経由でのテスト・自動化を行う場合は、画面右上の
Settings → API Keys から API キーを発行してください。

## インストール後の動作確認

```bash
bash smoke-test.sh
```

より詳しく、文書アップロードから RAG 回答・出典・文書外質問への
「不明」応答までを確認する場合は、API キーを発行したうえで以下を
実行してください。

```bash
LOCALRAG_API_KEY=<発行したAPIキー> bash rag-e2e-test.sh
```

## 困ったときは

[TROUBLESHOOTING.md](./TROUBLESHOOTING.md) を参照してください。
