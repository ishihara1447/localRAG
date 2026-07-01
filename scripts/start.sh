#!/usr/bin/env bash
# start.sh — LocalRAG サービスを起動する。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "[起動] LocalRAG サービスを起動中..."
docker compose up -d

echo "[待機] AnythingLLM の起動を待機中..."
for i in $(seq 1 36); do
  if curl -sf http://localhost:3001/api/ping >/dev/null 2>&1; then
    echo ""
    echo "起動完了: http://localhost:3001"
    exit 0
  fi
  printf "."
  sleep 5
done
echo ""
echo "警告: 3 分以内に起動を確認できませんでした。ログ: docker compose logs -f"
exit 1
