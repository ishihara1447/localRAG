# トラブルシューティング

## Docker が起動しない

```bash
docker info
```

上記でエラーになる場合、Docker サービス自体が起動していません。

```bash
sudo systemctl start docker    # Linux
```

Windows / Mac の場合は Docker Desktop を起動してください。

## `install.sh` が「チェックサム不一致」で止まる

配布パッケージの転送中にファイルが壊れた、または一部ファイルが
欠落している可能性があります。USB メモリや LAN 転送をやり直し、
パッケージを再取得してから再実行してください。

`checksums/images.sha256` などが見つからないというエラーの場合も
同様に、パッケージが不完全な状態です。展開・コピーが完了している
か確認してください。

## GPU が見えない

```bash
docker info --format '{{.Runtimes}}'
```

に `nvidia` が含まれない場合、NVIDIA ドライバまたは
nvidia-container-toolkit が正しく導入されていません。GPU が無くても
動作しますが、応答速度が大きく低下します。IT 担当者にドライバの
導入を依頼してください。

## モデルがロードされない・応答が来ない

```bash
docker compose logs ollama
docker compose logs anythingllm
```

でエラーがないか確認してください。よくある原因:

- `ollama-models/` の内容が壊れている、または一部しかコピーされて
  いない（`install.sh` のチェックサム検証で検出されるはずです）。
- GPU メモリ不足（他のアプリケーションが VRAM を占有している）。

## RAG 回答が遅い・タイムアウトする

- GPU が使われているか `docker compose logs ollama` や
  `nvidia-smi` で確認してください。CPU のみで動作している場合は
  大幅に遅くなります。
- 使用中の LLM によっては、思考過程（thinking）を出力するモデルが
  あり、応答完了までに数分かかる場合があります。数分待っても応答
  が返らない場合は IT 担当者にご連絡ください。

## API キーが分からない

ブラウザで `http://localhost:3001` にアクセスし、
Settings → API Keys から発行・確認できます。管理者アカウントで
ログインする必要があります。

## ポート 3001 が競合する

```bash
ss -tlnp | grep :3001     # Linux
```

で既に何か使用している場合、そのプロセスを停止するか、
`runtime/docker-compose.yml` の `ports` 設定を変更してください
（変更後は IT 担当者に確認を依頼してください）。

## ワークスペースを削除できない

既定で `WORKSPACE_DELETION_PROTECTION` が有効なため、API 経由の
削除は拒否されます。ブラウザの管理画面から手動で削除してください。

## それでも解決しない場合

以下の情報を添えて IT 担当者・提供元にご連絡ください。

```bash
docker compose logs --tail=200 anythingllm > anythingllm.log
docker compose logs --tail=200 ollama > ollama.log
cat versions.lock
```
