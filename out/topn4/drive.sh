#!/usr/bin/env bash
# topN=8 vs topN=4 の A/B 生成測定ドライバ（交互実行 A1→B1→A2→B2→A3→B3）
# 事前登録: docs/TOPN4_EVAL_2026-08-04.md §2-6
# scripts/ fixtures/ は一切変更しない。--top-n はハーネスの既存オプション。
set -u
export PATH="$HOME/.local/bin:$PATH"
cd /home/ishihara1447/projects/fukugyo/repos/localRAG
export HAKUSHO_SLUG=ttft-hakusho
OUT=out/topn4

gpucheck() {  # W1: PROCESSOR が 100% GPU であることの確認
  echo "--- ollama ps ($1) $(date -Iseconds) ---"
  docker exec rag-ollama ollama ps 2>&1
  nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader 2>&1
}

run() {  # $1=topN  $2=runno
  local n=$1 r=$2 tag out
  tag="t${n}r${r}"
  out="${OUT}/topn${n}-gen-run${r}.json"
  if [ -s "$out" ]; then echo "SKIP $out (already exists)"; return 0; fi
  gpucheck "before topN=${n} run${r}"
  echo "=== START topN=${n} run${r} $(date -Iseconds) ==="
  uv run scripts/complex-eval.py --phase generate --run "$tag" --top-n "$n" \
      --out "$out" > "${OUT}/gen-topn${n}-run${r}.log" 2>&1
  echo "exit=$? $(date -Iseconds)"
  tail -3 "${OUT}/gen-topn${n}-run${r}.log"
  gpucheck "after topN=${n} run${r}"
}

for r in 1 2 3; do
  run 8 "$r"
  run 4 "$r"
done
echo "=== ALL DONE $(date -Iseconds) ==="
