# 運用ガイド

## 起動・停止・再起動

```bash
bash start.sh      # 起動（起動完了まで待機し、URLを表示）
bash stop.sh        # 停止（データは保持されます）
docker compose restart   # 再起動
```

`stop.sh` はコンテナを停止するだけで、文書やチャット履歴、設定は
削除されません。

## バックアップ

```bash
bash backup.sh              # 既定: サービスを一時停止して整合性のあるバックアップを作成
bash backup.sh --live       # サービスを止めずにバックアップ（書き込み中の不整合の恐れあり）
```

バックアップは `backups/localrag-backup-<日時>.tar.gz` に作成されます。
定期的に外部媒体（社内バックアップサーバー等）へコピーすることを
推奨します。

## 復元

```bash
bash restore.sh backups/localrag-backup-<日時>.tar.gz
```

復元前の既存データは `anythingllm-storage.bak-<日時>` として退避され、
自動削除はされません。復元後に問題がないことを確認してから、不要に
なった退避データを手動削除してください。

## ログ確認

```bash
docker compose logs -f              # 全サービスのログをリアルタイム表示
docker compose logs anythingllm     # AnythingLLM のみ
docker compose logs ollama          # Ollama のみ
```

## データ保存場所

| データ | 保存先 |
|---|---|
| 文書・チャット履歴・ベクターDB・設定 | `anythingllm-storage/` |
| LLM / embedding モデル本体 | `ollama-models/` |
| バックアップファイル | `backups/` |

いずれもインストール先フォルダ配下にあり、コンテナを削除しても
消えません（`uninstall.sh` 実行時は別途確認が入ります）。

## アンインストール

```bash
bash uninstall.sh
```

データを完全に削除する場合と、`anythingllm-storage/` を残したまま
コンテナのみ削除する場合の選択肢が案内されます。判断に迷う場合は、
先に `bash backup.sh` でバックアップを取得してから実行してください。

## ワークスペースの誤削除防止について

本製品は既定で `WORKSPACE_DELETION_PROTECTION` を有効にしており、
API 経由でのワークスペース削除を拒否します。ワークスペースを削除
する場合は、管理者が UI 上から明示的に操作してください。

## 動作確認・監視

```bash
bash smoke-test.sh   # API疎通・Ollama疎通・GPU状態などの簡易確認
```

定期的な稼働確認（週次など）としての実行を推奨します。
