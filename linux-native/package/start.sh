#!/usr/bin/env bash
# OTE-RAG を起動する。
#   sudo /opt/ote-rag/start.sh
set -euo pipefail

INSTALL_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$INSTALL_ROOT"

if [ "$(id -u)" -ne 0 ] && ! docker info >/dev/null 2>&1; then
  echo "エラー: docker を実行できません。root で実行してください:  sudo $0" >&2
  exit 1
fi

[ -f .env ] || { echo "エラー: $INSTALL_ROOT/.env がありません。install.sh をやり直してください。" >&2; exit 1; }

echo "OTE-RAG を起動しています..."
docker compose up -d

# .env から公開ポートを読む（無ければ既定 3001）
PORT="$(awk -F= '/^OTE_RAG_PORT=/{print $2}' .env | tail -1)"
BIND="$(awk -F= '/^OTE_RAG_BIND=/{print $2}' .env | tail -1)"
[ -n "$PORT" ] || PORT=3001
[ -n "$BIND" ] || BIND=127.0.0.1

echo "起動を待っています（初回はモデル読み込みに時間がかかります）..."
for _ in $(seq 1 60); do
  sleep 5
  status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' ote-rag-app 2>/dev/null || echo missing)"
  if [ "$status" = "healthy" ]; then
    host="localhost"
    if [ "$BIND" = "0.0.0.0" ]; then host="$(hostname -I 2>/dev/null | awk '{print $1}')"; fi
    echo "起動しました。 Web UI: http://${host:-localhost}:${PORT}"
    exit 0
  fi
done

echo "注意: 5分以内に応答がありませんでした。状態を確認してください:" >&2
echo "  cd $INSTALL_ROOT && docker compose ps" >&2
echo "  cd $INSTALL_ROOT && docker compose logs --tail=100" >&2
exit 3
