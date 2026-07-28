#!/usr/bin/env bash
# OTE-RAG を停止する（データは消えない）。
#   sudo /opt/ote-rag/stop.sh
set -euo pipefail

INSTALL_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$INSTALL_ROOT"

if [ "$(id -u)" -ne 0 ] && ! docker info >/dev/null 2>&1; then
  echo "エラー: docker を実行できません。root で実行してください:  sudo $0" >&2
  exit 1
fi

echo "OTE-RAG を停止しています..."
docker compose stop
echo "停止しました。文書データとモデルはそのまま残っています。"
echo "再開するには: sudo $INSTALL_ROOT/start.sh"
