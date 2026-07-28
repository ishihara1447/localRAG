#!/usr/bin/env bash
# OTE-RAG をアンインストールする。
#
#   sudo /opt/ote-rag/uninstall.sh              # プログラムのみ削除（文書データは残す）
#   sudo /opt/ote-rag/uninstall.sh --purge      # 文書データとモデルも削除（元に戻せない）
#   sudo /opt/ote-rag/uninstall.sh --keep-images  # Docker イメージを残す
#
# 既定では文書データ（<データ領域>/anythingllm-storage）を削除しない。
set -euo pipefail

INSTALL_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PURGE=0
KEEP_IMAGES=0
ASSUME_YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --purge)       PURGE=1; shift ;;
    --keep-images) KEEP_IMAGES=1; shift ;;
    -y|--yes)      ASSUME_YES=1; shift ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "不明なオプション: $1" >&2; exit 1 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo "エラー: root 権限が必要です。 sudo $0" >&2; exit 1; }

DATA_DIR=""
if [ -f "$INSTALL_ROOT/.env" ]; then
  DATA_DIR="$(awk -F= '/^OTE_RAG_DATA=/{print $2}' "$INSTALL_ROOT/.env" | tail -1)"
fi

echo "════════════════════════════════════════════════════════"
echo " OTE-RAG のアンインストール"
echo "   プログラム: $INSTALL_ROOT"
echo "   データ    : ${DATA_DIR:-（不明）}"
if [ "$PURGE" -eq 1 ]; then
  echo "   🔴 --purge が指定されています。文書データとモデルも削除します（元に戻せません）。"
else
  echo "   文書データとモデルは残します（削除するには --purge）。"
fi
echo "════════════════════════════════════════════════════════"

if [ "$ASSUME_YES" -eq 0 ]; then
  printf '続行しますか？ [y/N]: '
  read -r ans
  case "$ans" in [yY]*) ;; *) echo "中止しました。"; exit 0 ;; esac
fi

# 1. サービス停止・削除
if [ -f "$INSTALL_ROOT/docker-compose.yml" ]; then
  echo "[1/5] コンテナを停止・削除しています..."
  ( cd "$INSTALL_ROOT" && docker compose down --remove-orphans ) || true
fi

# 2. systemd
if command -v systemctl >/dev/null 2>&1 && [ -f /etc/systemd/system/ote-rag.service ]; then
  echo "[2/5] systemd の登録を解除しています..."
  systemctl disable --now ote-rag.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/ote-rag.service
  systemctl daemon-reload || true
fi

# 3. Docker イメージ
if [ "$KEEP_IMAGES" -eq 0 ]; then
  echo "[3/5] Docker イメージを削除しています..."
  docker image rm localrag-anythingllm:1.1.0 >/dev/null 2>&1 || true
  docker image rm ollama/ollama:0.30.11 >/dev/null 2>&1 || true
else
  echo "[3/5] Docker イメージは残します（--keep-images）。"
fi

# 4. データ
if [ "$PURGE" -eq 1 ] && [ -n "$DATA_DIR" ] && [ -d "$DATA_DIR" ]; then
  echo "[4/5] データを削除しています: $DATA_DIR"
  rm -rf "${DATA_DIR:?}/ollama-models" "${DATA_DIR:?}/anythingllm-storage"
  rmdir "$DATA_DIR" 2>/dev/null || true
else
  echo "[4/5] データは残しました: ${DATA_DIR:-（不明）}"
fi

# 5. プログラム本体（データがこの中にある場合は --purge のときだけ消す）
echo "[5/5] プログラムを削除しています: $INSTALL_ROOT"
if [ "$PURGE" -eq 0 ] && [ -n "$DATA_DIR" ] && case "$DATA_DIR" in "$INSTALL_ROOT"/*) true ;; *) false ;; esac; then
  # データが INSTALL_ROOT の下にある構成。データ以外だけ消す。
  find "$INSTALL_ROOT" -mindepth 1 -maxdepth 1 ! -path "$DATA_DIR" -exec rm -rf {} +
  echo "  データ（$DATA_DIR）は残しました。"
else
  rm -rf "${INSTALL_ROOT:?}"
fi

echo
echo "アンインストールが完了しました。"
if [ "$PURGE" -eq 0 ]; then
  echo "文書データとモデルは ${DATA_DIR:-（不明）} に残っています。"
  echo "完全に削除するには手動で削除するか、再インストール後に --purge で実行してください。"
fi
