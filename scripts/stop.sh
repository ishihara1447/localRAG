#!/usr/bin/env bash
# stop.sh — LocalRAG サービスを停止する（データは保持される）。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "[停止] LocalRAG サービスを停止中..."
docker compose down
echo "停止しました。データ (anythingllm-storage/, ollama-models/) は保持されています。"
echo "再起動するには: bash start.sh"
