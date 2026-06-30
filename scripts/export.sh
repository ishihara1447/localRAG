#!/usr/bin/env bash
# export.sh — オンライン環境で実行。オフライン配布パッケージを作成する。
#
# 使い方:
#   bash scripts/export.sh [出力先ディレクトリ]
#   例: bash scripts/export.sh ./dist/localrag-v1.0
#
# 必要条件:
#   - Docker & Docker Compose が使用可能
#   - インターネット接続（Docker イメージ・モデルのダウンロード用）
#
# 出力物:
#   <出力先>/
#     install.sh           インストールスクリプト（オフライン機で実行）
#     docker-compose.yml   Compose 設定
#     images/
#       rag-images.tar.gz  Docker イメージ（anythingllm + ollama, 合計 ~6GB）
#     ollama-models/
#       (Ollama モデルファイル群)  ← compose の ./ollama-models と対応

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNTIME_DIR="$PROJECT_ROOT/runtime"
OUTPUT_DIR="${1:-$PROJECT_ROOT/dist/localrag-package}"

ANYTHINGLLM_IMAGE="mintplexlabs/anythingllm:latest"
OLLAMA_IMAGE="ollama/ollama:latest"
LLM_MODEL="llama3.1:8b"
EMBED_MODEL="mxbai-embed-large:latest"

echo "=== LocalRAG オフライン配布パッケージ作成 ==="
echo "出力先: $OUTPUT_DIR"
echo ""

# --- 1. 出力ディレクトリ準備 ---
mkdir -p "$OUTPUT_DIR/images"
mkdir -p "$OUTPUT_DIR/ollama-models"

# --- 2. Docker イメージ取得 ---
echo "[1/4] Docker イメージをプル中..."
docker pull "$ANYTHINGLLM_IMAGE"
docker pull "$OLLAMA_IMAGE"

echo "[2/4] Docker イメージを保存中 (images/rag-images.tar.gz)..."
docker save "$ANYTHINGLLM_IMAGE" "$OLLAMA_IMAGE" | gzip > "$OUTPUT_DIR/images/rag-images.tar.gz"
echo "      サイズ: $(du -sh "$OUTPUT_DIR/images/rag-images.tar.gz" | cut -f1)"

# --- 3. Ollama モデル取得 ---
echo "[3/4] Ollama モデルをダウンロード中..."

# 一時的に Ollama コンテナを起動してモデルをダウンロード
TEMP_CONTAINER="localrag-export-ollama"
docker run -d --name "$TEMP_CONTAINER" \
  -v "$OUTPUT_DIR/ollama-models:/root/.ollama" \
  "$OLLAMA_IMAGE" >/dev/null

# コンテナが起動するまで待機
sleep 3

echo "      $LLM_MODEL をダウンロード中..."
docker exec "$TEMP_CONTAINER" ollama pull "$LLM_MODEL"

echo "      $EMBED_MODEL をダウンロード中..."
docker exec "$TEMP_CONTAINER" ollama pull "$EMBED_MODEL"

# 一時コンテナを削除
docker rm -f "$TEMP_CONTAINER" >/dev/null

echo "      モデルサイズ: $(du -sh "$OUTPUT_DIR/ollama-models" | cut -f1)"

# --- 4. 設定ファイルとインストールスクリプトをコピー ---
echo "[4/4] 設定ファイルをコピー中..."
cp "$RUNTIME_DIR/docker-compose.yml" "$OUTPUT_DIR/docker-compose.yml"
cp "$SCRIPT_DIR/install.sh" "$OUTPUT_DIR/install.sh"
chmod +x "$OUTPUT_DIR/install.sh"

# --- 完了 ---
TOTAL_SIZE=$(du -sh "$OUTPUT_DIR" | cut -f1)
echo ""
echo "=== 完了 ==="
echo "パッケージサイズ: $TOTAL_SIZE"
echo "出力先: $OUTPUT_DIR"
echo ""
echo "配布先（オフライン環境）での手順:"
echo "  1. このフォルダをオフライン環境へコピー"
echo "  2. bash install.sh"
