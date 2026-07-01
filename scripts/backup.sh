#!/usr/bin/env bash
# backup.sh — 顧客データ (anythingllm-storage) をバックアップする。
#
# 使い方:
#   bash backup.sh [--live]
#     (既定)  サービスを一時停止してから整合性の取れたバックアップを作成
#     --live  サービスを止めずにバックアップ（DB 書き込み中は不整合の恐れ）
#
# 出力: backups/localrag-backup-<日時>.tar.gz

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

LIVE=false
[[ "${1:-}" == "--live" ]] && LIVE=true

STORAGE_DIR="$SCRIPT_DIR/anythingllm-storage"
if [[ ! -d "$STORAGE_DIR" ]]; then
  echo "エラー: anythingllm-storage/ が見つかりません。バックアップ対象がありません。"
  exit 1
fi

TS=$(date '+%Y%m%d-%H%M%S')
mkdir -p "$SCRIPT_DIR/backups"
BACKUP_FILE="$SCRIPT_DIR/backups/localrag-backup-$TS.tar.gz"

WAS_RUNNING=false
if docker compose ps --status running --quiet 2>/dev/null | grep -q .; then
  WAS_RUNNING=true
fi

# 整合性確保のためサービス停止（--live 指定時は停止しない）
if [[ "$LIVE" == false && "$WAS_RUNNING" == true ]]; then
  echo "[1/3] 整合性確保のためサービスを一時停止中..."
  docker compose stop
else
  [[ "$LIVE" == true ]] && echo "[1/3] --live 指定: サービスを停止せずにバックアップします（不整合の恐れ）"
fi

echo "[2/3] バックアップを作成中: $BACKUP_FILE"
BACKUP_ITEMS=(anythingllm-storage)
[[ -f "$SCRIPT_DIR/versions.lock" ]] && BACKUP_ITEMS+=(versions.lock)
tar czf "$BACKUP_FILE" -C "$SCRIPT_DIR" "${BACKUP_ITEMS[@]}"

# サービスを元の状態に戻す
if [[ "$LIVE" == false && "$WAS_RUNNING" == true ]]; then
  echo "[3/3] サービスを再起動中..."
  docker compose start
else
  echo "[3/3] 完了"
fi

echo ""
echo "=== バックアップ完了 ==="
echo "ファイル: $BACKUP_FILE"
echo "サイズ:   $(du -sh "$BACKUP_FILE" | cut -f1)"
echo ""
echo "復元するには: bash restore.sh '$BACKUP_FILE'"
