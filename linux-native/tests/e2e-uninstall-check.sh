#!/usr/bin/env bash
# アンインストール前後の状態を機械的に判定する。
#   bash check-uninstall.sh before   # 実行前の状態を記録
#   bash check-uninstall.sh after    # 実行後と突き合わせて合否を出す
set -uo pipefail

E2E="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DATA="$E2E/data"
ROOT="$E2E/opt/ote-rag"
DOC="$DATA/anythingllm-storage/documents/custom-documents"
SNAP="$E2E/.uninstall-snapshot"

case "${1:-}" in
  before)
    {
      echo "doc_count=$(find "$DOC" -name '*.json' 2>/dev/null | wc -l)"
      echo "doc_sha=$(cat "$DOC"/*.json 2>/dev/null | sha256sum | cut -d' ' -f1)"
      echo "lance_count=$(ls -d "$DATA/anythingllm-storage/lancedb"/*.lance 2>/dev/null | wc -l)"
      echo "models_size=$(du -sb "$DATA/ollama-models" 2>/dev/null | cut -f1)"
      echo "sqlite=$(ls "$DATA/anythingllm-storage"/*.db 2>/dev/null | wc -l)"
    } > "$SNAP"
    echo "--- 実行前の状態を記録した ---"
    cat "$SNAP"
    ;;
  after)
    [ -f "$SNAP" ] || { echo "before が実行されていません" >&2; exit 1; }
    # shellcheck disable=SC1090
    . "$SNAP"
    pass=0; fail=0
    chk() { # $1=項目 $2=期待 $3=実際
      if [ "$2" = "$3" ]; then printf '  \033[32mPASS\033[0m  %-42s %s\n' "$1" "$3"; pass=$((pass+1))
      else printf '  \033[31mFAIL\033[0m  %-42s 期待=%s 実際=%s\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
    }

    echo
    echo "═══ 顧客データが残っているか（最重要）═══"
    echo
    chk "文書ファイルの数"        "$doc_count"   "$(find "$DOC" -name '*.json' 2>/dev/null | wc -l)"
    chk "文書の内容（SHA-256）"   "$doc_sha"     "$(cat "$DOC"/*.json 2>/dev/null | sha256sum | cut -d' ' -f1)"
    chk "ベクトルDB の数"          "$lance_count" "$(ls -d "$DATA/anythingllm-storage/lancedb"/*.lance 2>/dev/null | wc -l)"
    chk "モデルのサイズ"           "$models_size" "$(du -sb "$DATA/ollama-models" 2>/dev/null | cut -f1)"
    chk "SQLite の数"              "$sqlite"      "$(ls "$DATA/anythingllm-storage"/*.db 2>/dev/null | wc -l)"

    echo
    echo "═══ プログラムが削除されたか ═══"
    echo
    for f in docker-compose.yml start.sh stop.sh .env config; do
      if [ -e "$ROOT/$f" ]; then printf '  \033[31mFAIL\033[0m  %-42s 残存\n' "$f"; fail=$((fail+1))
      else printf '  \033[32mPASS\033[0m  %-42s 削除済み\n' "$f"; pass=$((pass+1)); fi
    done

    echo
    echo "═══ コンテナが停止・削除されたか ═══"
    echo
    n=$(docker ps -a --filter 'name=ote-rag' --format '{{.Names}}' 2>/dev/null | wc -l)
    chk "残存コンテナ数" "0" "$n"

    echo
    echo "──────────────────────────────────────────────"
    printf '  合計: PASS=%d FAIL=%d\n' "$pass" "$fail"
    [ "$fail" -eq 0 ]
    ;;
  *)
    echo "使い方: bash check-uninstall.sh {before|after}" >&2; exit 1 ;;
esac
