#!/usr/bin/env bash
# 埋め込み条件ごとの生成精度（防衛白書30問）を、交互実行で各3run 測る。
#
# 🔴 埋め込みは起動時に決まるため、条件を切り替えるたびにコンテナを作り直す。
#    ワークスペースは条件ごとに別（ベクトルの次元が違うので共有できない）。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
OUT=out/embswap/raw; mkdir -p "$OUT"

declare -A MODEL=( [bgem3]="bge-m3:latest" [granite]="granite-embedding:278m" [gemma]="embeddinggemma:300m" )
declare -A SLUG=(  [bgem3]="emb-bgem3"     [granite]="emb-granite"            [gemma]="emb-gemma" )
declare -A QP=(    [bgem3]=""              [granite]=""                       [gemma]="task: search result | query: " )
declare -A CP=(    [bgem3]=""              [granite]=""                       [gemma]="title: none | text: " )

switch_to() {
  local c="$1"
  ( cd runtime && EMB_MODEL="${MODEL[$c]}" EMB_QUERY_PREFIX="${QP[$c]}" EMB_CHUNK_PREFIX="${CP[$c]}" \
      docker compose -f docker-compose.yml -f docker-compose.embedding-eval.yml up -d --force-recreate anythingllm >/dev/null 2>&1 )
  for i in $(seq 1 60); do curl -sf http://localhost:3001/api/ping >/dev/null 2>&1 && break; sleep 5; done
  local act; act=$(docker exec anythingllm printenv EMBEDDING_MODEL_PREF | tr -d '\r')
  [ "$act" = "${MODEL[$c]}" ] || { echo "エラー: 埋め込みが $act（期待 ${MODEL[$c]}）" >&2; exit 1; }
}

for run in 1 2 3; do
  for c in bgem3 granite gemma; do     # 交互実行
    lbl="${c}-run${run}"
    echo "===== $lbl (${MODEL[$c]}) $(date '+%H:%M:%S') ====="
    switch_to "$c"
    CHAT_MODEL=granite4.1:8b \
    HAKUSHO_SLUG="${SLUG[$c]}" \
    HAKUSHO_RUN="emb-$lbl" \
    HAKUSHO_OUT="$OUT/gen-$lbl.json" \
      uv run scripts/hakusho-eval.py > "$OUT/gen-$lbl.log" 2>&1 || echo "  !! $lbl 異常終了"
    echo "  $(grep -oE '合計: [0-9]+/[0-9]+' "$OUT/gen-$lbl.log" | tail -1)"
  done
done
echo "完了: $(date '+%H:%M:%S')"
