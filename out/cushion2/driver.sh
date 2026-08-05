#!/usr/bin/env bash
# クッション 12/16 の166問評価（事前登録 PREREG_CUSHION_12_16_2026-08-05.md）
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
OUT=out/cushion2; mkdir -p "$OUT"
C=$(docker ps -qf name=rag-ollama|head -1)
N=$(docker inspect "$C" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$v.IPAddress}}{{end}}')
for k in 12 16; do
  echo "===== TOPK=$k 開始 $(date '+%H:%M:%S') ====="
  ( cd runtime && EMB_MODEL=granite-embedding:278m CUSHION_TOPK="$k" \
      docker compose -f docker-compose.yml -f docker-compose.embedding-eval.yml \
      up -d --force-recreate anythingllm >/dev/null 2>&1 )
  for i in $(seq 1 60); do curl -sf http://localhost:3001/api/ping >/dev/null 2>&1 && break; sleep 5; done
  act=$(docker exec anythingllm printenv SENTENCE_CUSHION_TOPK | tr -d '\r')
  [ "$act" = "$k" ] || { echo "エラー: TOPK='$act'（期待 $k）" >&2; exit 1; }
  HAKUSHO_SLUG=emb-granite uv run scripts/complex-eval.py --phase generate \
    --run "k$k" --chat-model granite4.1:8b --top-n 8 \
    --out "$OUT/gen-$k.json" > "$OUT/gen-$k.log" 2>&1
  JUDGE_OLLAMA_URL="http://$N:11434" uv run scripts/complex-eval.py --phase judge \
    --in "$OUT/gen-$k.json" --judge-model gemma4:12b --judge-url "http://$N:11434" \
    --out "$OUT/judged-$k.json" > "$OUT/judge-$k.log" 2>&1
  echo "  TOPK=$k 完了 $(date '+%H:%M:%S')"
done
echo "完了: $(date '+%H:%M:%S')"
