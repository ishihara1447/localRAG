#!/usr/bin/env bash
# restore.sh — バックアップから顧客データ (anythingllm-storage) を復元する。
#
# 使い方:
#   bash restore.sh <backup.tar.gz>
#
# 既存の anythingllm-storage/ は削除前に退避される（anythingllm-storage.bak-<日時>）。

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BACKUP_FILE="${1:-}"
if [[ -z "$BACKUP_FILE" ]]; then
  echo "使い方: bash restore.sh <backup.tar.gz>"
  echo ""
  echo "利用可能なバックアップ:"
  ls -1 "$SCRIPT_DIR/backups/"*.tar.gz 2>/dev/null || echo "  (backups/ にバックアップがありません)"
  exit 1
fi

if [[ ! -f "$BACKUP_FILE" ]]; then
  echo "エラー: バックアップファイルが見つかりません: $BACKUP_FILE"
  exit 1
fi

# バックアップ内容の妥当性チェック（anythingllm-storage を含むか）
if ! tar tzf "$BACKUP_FILE" 2>/dev/null | grep -q '^anythingllm-storage/'; then
  echo "エラー: このファイルは LocalRAG のバックアップではないようです。"
  echo "       (anythingllm-storage/ が含まれていません)"
  exit 1
fi

echo "復元元: $BACKUP_FILE"
echo "警告: 現在の anythingllm-storage/ は退避されます。"
read -r -p "続行しますか？ [y/N]: " ans
[[ "$ans" =~ ^[Yy]$ ]] || { echo "キャンセルしました。"; exit 0; }

echo "[1/4] サービスを停止中..."
docker compose down 2>/dev/null || true

# 既存データを退避
if [[ -d "$SCRIPT_DIR/anythingllm-storage" ]]; then
  TS=$(date '+%Y%m%d-%H%M%S')
  BAK_DIR="$SCRIPT_DIR/anythingllm-storage.bak-$TS"
  echo "[2/4] 既存データを退避中: $(basename "$BAK_DIR")"
  mv "$SCRIPT_DIR/anythingllm-storage" "$BAK_DIR"
else
  echo "[2/4] 既存データなし（退避スキップ）"
fi

echo "[3/4] バックアップを展開中..."
tar xzf "$BACKUP_FILE" -C "$SCRIPT_DIR"

echo "[4/4] サービスを起動中..."
docker compose up -d

echo ""
echo "=== 復元完了 ==="
echo "ブラウザ: http://localhost:3001"
echo "退避した旧データが不要なら手動削除してください: anythingllm-storage.bak-*"
