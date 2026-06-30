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
#     install.sh              インストールスクリプト（オフライン機で実行）
#     uninstall.sh            アンインストールスクリプト
#     smoke-test.sh           動作確認スクリプト
#     docker-compose.yml      Compose 設定
#     versions.lock           バージョン固定ファイル
#     images/
#       rag-images.tar.gz     Docker イメージ（anythingllm + ollama）
#       rag-images.tar.gz.sha256  チェックサム
#     ollama-models/          Ollama モデルファイル群

set -euo pipefail

# ---------------------------------------------------------------------------
# 設定
# ---------------------------------------------------------------------------
ANYTHINGLLM_IMAGE="mintplexlabs/anythingllm:latest"
OLLAMA_IMAGE="ollama/ollama:latest"
LLM_MODEL="llama3.1:8b"
EMBED_MODEL="mxbai-embed-large:latest"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNTIME_DIR="$PROJECT_ROOT/runtime"
OUTPUT_DIR="${1:-$PROJECT_ROOT/dist/localrag-package}"

TEMP_CONTAINER="localrag-export-ollama-$$"
LOG_FILE="$OUTPUT_DIR/export.log"

# ---------------------------------------------------------------------------
# ログ関数
# ---------------------------------------------------------------------------
log() {
  local level="$1"; shift
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
  echo "$msg"
  [[ -f "$LOG_FILE" ]] && echo "$msg" >> "$LOG_FILE"
}

# ---------------------------------------------------------------------------
# クリーンアップ（成功・失敗どちらでも実行）
# ---------------------------------------------------------------------------
cleanup() {
  local exit_code=$?
  if docker ps -a --format '{{.Names}}' | grep -q "^${TEMP_CONTAINER}$" 2>/dev/null; then
    log INFO "一時コンテナを削除中..."
    docker rm -f "$TEMP_CONTAINER" >/dev/null 2>&1 || true
  fi
  if [[ $exit_code -ne 0 ]]; then
    log ERROR "エクスポートが失敗しました (exit $exit_code)。ログ: $LOG_FILE"
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# メイン処理
# ---------------------------------------------------------------------------
mkdir -p "$OUTPUT_DIR/images" "$OUTPUT_DIR/ollama-models"
exec > >(tee -a "$LOG_FILE") 2>&1

log INFO "=== LocalRAG オフライン配布パッケージ作成 ==="
log INFO "出力先: $OUTPUT_DIR"

# --- 前提条件チェック ---
log INFO "[チェック] 前提条件を確認中..."
command -v docker >/dev/null || { log ERROR "Docker がインストールされていません"; exit 1; }
docker info >/dev/null 2>&1 || { log ERROR "Docker デーモンが起動していません"; exit 1; }
command -v sha256sum >/dev/null || command -v shasum >/dev/null \
  || { log ERROR "sha256sum / shasum が見つかりません"; exit 1; }

# ディスク空き容量チェック（最低 25GB）
AVAIL_KB=$(df -k "$OUTPUT_DIR" | awk 'NR==2 {print $4}')
REQUIRED_KB=$((25 * 1024 * 1024))
if [[ "$AVAIL_KB" -lt "$REQUIRED_KB" ]]; then
  log ERROR "空きディスク容量不足。必要: 25GB、現在: $((AVAIL_KB / 1024 / 1024))GB"
  exit 2
fi
log INFO "      ディスク空き: $((AVAIL_KB / 1024 / 1024))GB  OK"

# --- 1. Docker イメージ取得 ---
log INFO "[1/5] Docker イメージをプル中..."
docker pull "$ANYTHINGLLM_IMAGE"
docker pull "$OLLAMA_IMAGE"

# イメージダイジェスト（バージョン固定用）
ANYTHINGLLM_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "$ANYTHINGLLM_IMAGE" 2>/dev/null || echo "unknown")
OLLAMA_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "$OLLAMA_IMAGE" 2>/dev/null || echo "unknown")

# --- 2. Docker イメージ保存 ---
log INFO "[2/5] Docker イメージを保存中 (images/rag-images.tar.gz)..."
docker save "$ANYTHINGLLM_IMAGE" "$OLLAMA_IMAGE" | gzip > "$OUTPUT_DIR/images/rag-images.tar.gz"
IMAGE_SIZE=$(du -sh "$OUTPUT_DIR/images/rag-images.tar.gz" | cut -f1)
log INFO "      サイズ: $IMAGE_SIZE"

log INFO "      SHA-256 チェックサムを生成中..."
if command -v sha256sum >/dev/null; then
  sha256sum "$OUTPUT_DIR/images/rag-images.tar.gz" > "$OUTPUT_DIR/images/rag-images.tar.gz.sha256"
else
  shasum -a 256 "$OUTPUT_DIR/images/rag-images.tar.gz" > "$OUTPUT_DIR/images/rag-images.tar.gz.sha256"
fi
log INFO "      チェックサム: $(cat "$OUTPUT_DIR/images/rag-images.tar.gz.sha256" | awk '{print $1}')"

# --- 3. Ollama モデル取得 ---
log INFO "[3/5] Ollama モデルをダウンロード中..."
docker run -d --name "$TEMP_CONTAINER" \
  -v "$OUTPUT_DIR/ollama-models:/root/.ollama" \
  "$OLLAMA_IMAGE" >/dev/null

sleep 5  # サービス起動待機

log INFO "      $LLM_MODEL をダウンロード中..."
docker exec "$TEMP_CONTAINER" ollama pull "$LLM_MODEL"

log INFO "      $EMBED_MODEL をダウンロード中..."
docker exec "$TEMP_CONTAINER" ollama pull "$EMBED_MODEL"

# モデルのダイジェスト取得
LLM_DIGEST=$(docker exec "$TEMP_CONTAINER" ollama show "$LLM_MODEL" --modelfile 2>/dev/null \
  | grep "^FROM" | awk '{print $2}' || echo "unknown")

docker rm -f "$TEMP_CONTAINER" >/dev/null
MODEL_SIZE=$(du -sh "$OUTPUT_DIR/ollama-models" | cut -f1)
log INFO "      モデルサイズ: $MODEL_SIZE"

# --- 4. versions.lock 生成 ---
log INFO "[4/5] versions.lock を生成中..."
cat > "$OUTPUT_DIR/versions.lock" << EOF
# LocalRAG バージョン固定ファイル
# 生成日時: $(date '+%Y-%m-%d %H:%M:%S')
#
# このファイルはインストール時の再現性を保証するために使用します。
# 配布後は変更しないでください。

ANYTHINGLLM_IMAGE=$ANYTHINGLLM_IMAGE
ANYTHINGLLM_DIGEST=$ANYTHINGLLM_DIGEST

OLLAMA_IMAGE=$OLLAMA_IMAGE
OLLAMA_DIGEST=$OLLAMA_DIGEST

LLM_MODEL=$LLM_MODEL
EMBED_MODEL=$EMBED_MODEL
EOF

# --- 5. 設定ファイルとスクリプトをコピー ---
log INFO "[5/5] 設定ファイルとスクリプトをコピー中..."
cp "$RUNTIME_DIR/docker-compose.yml" "$OUTPUT_DIR/docker-compose.yml"
cp "$SCRIPT_DIR/install.sh"     "$OUTPUT_DIR/install.sh"
cp "$SCRIPT_DIR/uninstall.sh"   "$OUTPUT_DIR/uninstall.sh"
cp "$SCRIPT_DIR/smoke-test.sh"  "$OUTPUT_DIR/smoke-test.sh"
chmod +x "$OUTPUT_DIR/install.sh" "$OUTPUT_DIR/uninstall.sh" "$OUTPUT_DIR/smoke-test.sh"

# --- 完了 ---
TOTAL_SIZE=$(du -sh "$OUTPUT_DIR" | cut -f1)
log INFO ""
log INFO "=== エクスポート完了 ==="
log INFO "パッケージサイズ: $TOTAL_SIZE"
log INFO "出力先: $OUTPUT_DIR"
log INFO ""
log INFO "配布先（オフライン環境）での手順:"
log INFO "  1. このフォルダ全体をオフライン環境へコピー（USBまたはLAN転送）"
log INFO "  2. bash install.sh"
log INFO ""
log INFO "注意: FAT32 形式 USB の場合、rag-images.tar.gz が 4GB を超えると"
log INFO "      コピーできません。exFAT または NTFS でフォーマットしてください。"
