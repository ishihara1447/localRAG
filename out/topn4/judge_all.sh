#!/usr/bin/env bash
# 6本の生成JSONに決定的採点（Layer0/1）を掛ける。judge モデルは使わない（[P]は未判定）。
set -u
export PATH="$HOME/.local/bin:$PATH"
cd /home/ishihara1447/projects/fukugyo/repos/localRAG
OUT=out/topn4
for n in 8 4; do
  for r in 1 2 3; do
    g="${OUT}/topn${n}-gen-run${r}.json"
    j="${OUT}/topn${n}-judged-run${r}.json"
    [ -s "$g" ] || { echo "MISSING $g"; continue; }
    [ -s "$j" ] && { echo "SKIP $j"; continue; }
    uv run scripts/complex-eval.py --phase judge --in "$g" --out "$j" \
        > "${OUT}/judge-topn${n}-run${r}.log" 2>&1
    echo "judged topN=${n} run${r} exit=$? -> $(grep -o 'プール比率: [0-9]*/[0-9]* = [0-9.]*' "${OUT}/judge-topn${n}-run${r}.log" | tail -1)"
  done
done
echo "=== JUDGE DONE $(date -Iseconds) ==="
