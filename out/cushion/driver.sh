#!/usr/bin/env bash
# SENTENCE_CUSHION_TOPK の A/B/C（事前登録 PREREG_CUSHION_TOPK_2026-08-05.md）
# 交互実行 A→B→C を1周として3周。条件ごとにコンテナを作り直す。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
OUT=out/cushion/raw; mkdir -p "$OUT"
declare -A K=( [a8]=8 [b16]=16 [c24]=24 )

switch() {
  ( cd runtime && EMB_MODEL=granite-embedding:278m CUSHION_TOPK="$1" \
      docker compose -f docker-compose.yml -f docker-compose.embedding-eval.yml \
      up -d --force-recreate anythingllm >/dev/null 2>&1 )
  for i in $(seq 1 60); do curl -sf http://localhost:3001/api/ping >/dev/null 2>&1 && break; sleep 5; done
  local act; act=$(docker exec anythingllm printenv SENTENCE_CUSHION_TOPK | tr -d '\r')
  [ "$act" = "$1" ] || { echo "エラー: TOPK='$act'（期待 $1）" >&2; exit 1; }
}

for run in 1 2 3; do
  for c in a8 b16 c24; do
    lbl="${c}-run${run}"
    echo "===== $lbl (TOPK=${K[$c]}) $(date '+%H:%M:%S') ====="
    switch "${K[$c]}"
    CHAT_MODEL=granite4.1:8b HAKUSHO_SLUG=emb-granite \
    HAKUSHO_RUN="cushion-$lbl" HAKUSHO_OUT="$OUT/$lbl.json" \
      uv run scripts/hakusho-eval.py > "$OUT/$lbl.log" 2>&1 || echo "  !! 異常終了"
    echo "  $(grep -oE '合計: [0-9]+/[0-9]+' "$OUT/$lbl.log" | tail -1)"
  done
done
echo "完了: $(date '+%H:%M:%S')"
