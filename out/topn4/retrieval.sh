#!/usr/bin/env bash
# 補助（決定的・LLM非依存）: 本環境での anchor_coverage@k（k=4/8/16/32）を1run測る。
# retrieval は BASELINE_166Q §2-8 で決定的（V1 PASS）と実証済みなので1runでよい。
set -u
export PATH="$HOME/.local/bin:$PATH"
cd /home/ishihara1447/projects/fukugyo/repos/localRAG
export HAKUSHO_SLUG=ttft-hakusho
uv run scripts/complex-eval.py --phase retrieval \
    --out out/topn4/topn4-retrieval-run1.json > out/topn4/retrieval-run1.log 2>&1
echo "retrieval exit=$? $(date -Iseconds)"
