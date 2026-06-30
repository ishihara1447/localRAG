#!/usr/bin/env bash
# install.sh — オフライン環境で実行。LocalRAG をインストールして起動する。
#
# 使い方:
#   bash install.sh
#
# 必要条件:
#   - Docker & Docker Compose が使用可能（インターネット接続不要）
#   - NVIDIA GPU + nvidia-container-toolkit がインストール済み
#   - このスクリプトと同じディレクトリに以下が存在すること:
#       images/rag-images.tar.gz
#       models/  (Ollama モデルファイル群)
#       docker-compose.yml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== LocalRAG インストーラー ==="
echo ""

# --- 前提条件チェック ---
echo "[チェック] 前提条件を確認中..."

if ! command -v docker &>/dev/null; then
  echo "エラー: Docker がインストールされていません。"
  echo "  公式サイト: https://docs.docker.com/engine/install/"
  exit 1
fi

if ! docker compose version &>/dev/null 2>&1; then
  echo "エラー: Docker Compose (v2) がインストールされていません。"
  exit 1
fi

if ! docker info --format '{{.Runtimes}}' 2>/dev/null | grep -q nvidia; then
  echo "警告: NVIDIA Container Runtime が検出されませんでした。"
  echo "      GPU を使用しない場合は続行できますが、推論速度が極めて遅くなります。"
  read -r -p "      続行しますか？ [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]] || exit 1
fi

if [[ ! -f "$SCRIPT_DIR/images/rag-images.tar.gz" ]]; then
  echo "エラー: images/rag-images.tar.gz が見つかりません。"
  echo "  export.sh を使ってオンライン環境でパッケージを作成してください。"
  exit 1
fi

if [[ ! -d "$SCRIPT_DIR/ollama-models" ]]; then
  echo "エラー: ollama-models/ ディレクトリが見つかりません。"
  exit 1
fi

echo "      OK"

# --- 1. Docker イメージのロード ---
echo ""
echo "[1/3] Docker イメージを読み込み中..."
docker load < "$SCRIPT_DIR/images/rag-images.tar.gz"
echo "      OK"

# --- 2. モデルファイルの配置 ---
echo ""
echo "[2/3] Ollama モデルを確認中..."
# docker-compose.yml の volumes: ./ollama-models:/root/.ollama に対応
echo "      モデルサイズ: $(du -sh "$SCRIPT_DIR/ollama-models" | cut -f1)  OK"

# --- 3. ストレージディレクトリ作成 ---
echo ""
echo "[3/3] データディレクトリを準備中..."
mkdir -p "$SCRIPT_DIR/anythingllm-storage"
echo "      OK"

# --- サービス起動 ---
echo ""
echo "[起動] サービスを起動中..."
cd "$SCRIPT_DIR"
docker compose up -d

# ヘルスチェック（最大2分待機）
echo "      AnythingLLM の起動を待機中..."
for i in $(seq 1 24); do
  if curl -sf http://localhost:3001/api/ping >/dev/null 2>&1; then
    echo ""
    echo "=== インストール完了 ==="
    echo ""
    echo "ブラウザで以下の URL にアクセスしてください:"
    echo "  http://localhost:3001"
    echo ""
    echo "停止するには: docker compose down"
    echo "再起動するには: docker compose up -d"
    exit 0
  fi
  printf "."
  sleep 5
done

echo ""
echo "警告: 起動タイムアウト（2分）。ログを確認してください:"
echo "  docker compose logs anythingllm"
echo "  docker compose logs ollama"
exit 1
