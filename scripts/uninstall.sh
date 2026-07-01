#!/usr/bin/env bash
# uninstall.sh — LocalRAG をアンインストールする。
#
# 使い方:
#   bash uninstall.sh              # データを削除して完全除去
#   bash uninstall.sh --keep-data  # anythingllm-storage/ を残す（RAG データ保持）
#
# このスクリプトはアップグレード時の「クリーンアップ → 再インストール」にも使える。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/uninstall.log"
KEEP_DATA=false

# オプション解析
for arg in "$@"; do
  case "$arg" in
    --keep-data) KEEP_DATA=true ;;
    --help|-h)
      echo "使い方: bash uninstall.sh [--keep-data]"
      echo "  --keep-data  文書・ベクターDBを含む anythingllm-storage/ を削除しない"
      exit 0
      ;;
    *)
      echo "不明なオプション: $arg"
      echo "使い方: bash uninstall.sh [--keep-data]"
      exit 1
      ;;
  esac
done

log() {
  local level="$1"; shift
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
  echo "$msg"
  echo "$msg" >> "$LOG_FILE"
}

exec > >(tee -a "$LOG_FILE") 2>&1

log INFO "=== LocalRAG アンインストーラー ==="
log INFO "データ保持モード: $( [[ "$KEEP_DATA" == true ]] && echo "有効（anythingllm-storage/ を残す）" || echo "無効（全削除）" )"
echo ""

# --- 確認プロンプト ---
if [[ "$KEEP_DATA" == false ]]; then
  echo "警告: anythingllm-storage/ (アップロード済み文書・ベクターDB) も削除されます。"
  echo "      文書データを保持する場合は '--keep-data' オプションを使ってください。"
  echo ""
  read -r -p "続行しますか？ [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { log INFO "アンインストールをキャンセルしました。"; exit 0; }
fi

# --- 1. サービス停止とコンテナ削除 ---
log INFO "[1/3] サービスを停止・削除中..."
cd "$SCRIPT_DIR"
if docker compose ps --quiet 2>/dev/null | grep -q .; then
  docker compose down --remove-orphans 2>&1 | while read -r line; do log INFO "      $line"; done
  log INFO "      コンテナ・ネットワークを削除しました"
else
  log INFO "      起動中のサービスはありませんでした"
fi

# --- 2. Docker イメージ削除 ---
log INFO "[2/3] Docker イメージを削除中..."
# 実際にインストールされた image は versions.lock に記録されている
# (バージョンにより image 名・タグが変わり得るため、それを優先する)。
# versions.lock が無い場合のみ、現行既定値にフォールバックする。
ANYTHINGLLM_IMAGE_TO_REMOVE="localrag-anythingllm:1.0.0"
OLLAMA_IMAGE_TO_REMOVE="ollama/ollama:latest"
if [[ -f "$SCRIPT_DIR/versions.lock" ]]; then
  ANYTHINGLLM_IMAGE_TO_REMOVE=$(grep '^ANYTHINGLLM_IMAGE=' "$SCRIPT_DIR/versions.lock" | cut -d= -f2- || echo "$ANYTHINGLLM_IMAGE_TO_REMOVE")
  OLLAMA_IMAGE_TO_REMOVE=$(grep '^OLLAMA_IMAGE=' "$SCRIPT_DIR/versions.lock" | cut -d= -f2- || echo "$OLLAMA_IMAGE_TO_REMOVE")
fi
IMAGES_REMOVED=0
for img in "$ANYTHINGLLM_IMAGE_TO_REMOVE" "$OLLAMA_IMAGE_TO_REMOVE"; do
  if docker image inspect "$img" &>/dev/null 2>&1; then
    docker rmi "$img" 2>&1 | while read -r line; do log INFO "      $line"; done
    ((IMAGES_REMOVED++)) || true
  fi
done
if [[ $IMAGES_REMOVED -eq 0 ]]; then
  log INFO "      削除対象のイメージはありませんでした"
else
  log INFO "      $IMAGES_REMOVED 個のイメージを削除しました"
fi

# --- 3. データディレクトリ処理 ---
log INFO "[3/3] データディレクトリを処理中..."
if [[ "$KEEP_DATA" == true ]]; then
  log INFO "      anythingllm-storage/ を保持します（--keep-data 指定）"
  log INFO "      ★ 再インストール後もこのデータは引き続き使えます"
else
  if [[ -d "$SCRIPT_DIR/anythingllm-storage" ]]; then
    rm -rf "$SCRIPT_DIR/anythingllm-storage"
    log INFO "      anythingllm-storage/ を削除しました"
  fi
fi

# --- 完了 ---
log INFO ""
log INFO "=== アンインストール完了 ==="
log INFO ""
log INFO "【削除されたもの】"
log INFO "  - コンテナ: anythingllm, rag-ollama"
log INFO "  - ネットワーク: rag-internal, rag-public"
log INFO "  - Docker イメージ: $ANYTHINGLLM_IMAGE_TO_REMOVE, $OLLAMA_IMAGE_TO_REMOVE"
if [[ "$KEEP_DATA" == false ]]; then
  log INFO "  - データ: anythingllm-storage/"
fi
log INFO ""
log INFO "【削除されていないもの】"
log INFO "  - Ollama モデルファイル: ollama-models/ （大容量のため手動削除してください）"
log INFO "    削除するには: rm -rf '$SCRIPT_DIR/ollama-models'"
if [[ "$KEEP_DATA" == true ]]; then
  log INFO "  - アプリデータ: anythingllm-storage/ （--keep-data 指定）"
fi
log INFO "  - Docker Engine 本体（システム全体に影響するため自動削除しません）"
