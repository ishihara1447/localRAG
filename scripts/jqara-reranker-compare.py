#!/usr/bin/env -S uv run --script
# /// script
# dependencies = [
#   "datasets>=3.0",
#   "ranx>=0.3",
#   "sentence-transformers>=3.0",
# ]
# ///
"""Compare Japanese rerankers on the official JQaRA test split.

The candidate set, passage formatting, metrics, and truncation length are kept
constant so that only the reranker changes between runs.
"""

from __future__ import annotations

import argparse
import gc
import json
import os
import time
from collections import OrderedDict
from pathlib import Path

from datasets import load_dataset
from ranx import Qrels, Run, evaluate
from sentence_transformers import CrossEncoder
import torch


DEFAULT_BASELINE = "BAAI/bge-reranker-v2-m3"
DEFAULT_CANDIDATE = "hotchpotch/japanese-bge-reranker-v2-m3-v1"
METRICS = ["ndcg@10", "mrr@10", "ndcg@100", "mrr@100"]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", default=DEFAULT_BASELINE)
    parser.add_argument("--candidate", default=DEFAULT_CANDIDATE)
    parser.add_argument(
        "--limit",
        type=int,
        default=0,
        help="Number of questions to evaluate; 0 means the full test split.",
    )
    parser.add_argument("--batch-size", type=int, default=32)
    parser.add_argument("--max-length", type=int, default=512)
    parser.add_argument("--device", default=None, help="cpu, cuda, or auto")
    parser.add_argument(
        "--precision",
        choices=("auto", "fp16", "fp32"),
        default="auto",
        help="Model precision; auto uses fp16 when CUDA is available.",
    )
    parser.add_argument("--output", type=Path, default=None)
    return parser.parse_args()


def select_questions(dataset, limit: int):
    selected = []
    seen = set()
    for row in dataset:
        qid = str(row["q_id"])
        if qid in seen:
            continue
        seen.add(qid)
        selected.append(qid)
        if limit > 0 and len(selected) >= limit:
            break
    selected_set = set(selected)
    rows = [row for row in dataset if str(row["q_id"]) in selected_set]
    groups = OrderedDict()
    for row in rows:
        groups.setdefault(str(row["q_id"]), []).append(row)
    return groups


def build_inputs(groups):
    pairs = []
    qrels = {}
    for qid, rows in groups.items():
        question = str(rows[0]["question"])
        qrels[qid] = {}
        for row in rows:
            docid = str(row["id"])
            passage = f"{row['title']} {row['text']}"
            pairs.append((question, passage))
            qrels[qid][docid] = int(row["label"])
    return pairs, qrels


def build_run(groups, scores):
    run = {}
    offset = 0
    for qid, rows in groups.items():
        run[qid] = {}
        for row in rows:
            run[qid][str(row["id"])] = float(scores[offset])
            offset += 1
    return run


def hit_at_10(run, qrels):
    hits = 0
    for qid, scores in run.items():
        ranked = sorted(scores, key=scores.get, reverse=True)[:10]
        if any(qrels[qid].get(docid, 0) > 0 for docid in ranked):
            hits += 1
    return hits / len(run) if run else 0.0


def evaluate_model(model_name, groups, pairs, qrels, args):
    device = None if args.device in (None, "auto") else args.device
    use_fp16 = args.precision == "fp16" or (
        args.precision == "auto"
        and args.device != "cpu"
        and torch.cuda.is_available()
    )
    started = time.perf_counter()
    print(
        f"Loading {model_name} (device={args.device or 'auto'}, "
        f"precision={'fp16' if use_fp16 else 'fp32'})",
        flush=True,
    )
    model = CrossEncoder(
        model_name,
        max_length=args.max_length,
        device=device,
        model_kwargs={"torch_dtype": torch.float16} if use_fp16 else None,
    )
    scores = model.predict(
        pairs,
        batch_size=args.batch_size,
        show_progress_bar=True,
        convert_to_numpy=True,
    )
    run = build_run(groups, scores)
    ranx_scores = evaluate(Qrels(qrels), Run(run), METRICS)
    result = {
        "model": model_name,
        "questions": len(groups),
        "pairs": len(pairs),
        "ndcg@10": float(ranx_scores["ndcg@10"]),
        "mrr@10": float(ranx_scores["mrr@10"]),
        "hit@10": float(hit_at_10(run, qrels)),
        "ndcg@100": float(ranx_scores["ndcg@100"]),
        "mrr@100": float(ranx_scores["mrr@100"]),
        "elapsed_seconds": round(time.perf_counter() - started, 2),
    }
    print(json.dumps(result, ensure_ascii=False, indent=2), flush=True)
    del model, scores, run
    gc.collect()
    return result


def main() -> None:
    args = parse_args()
    os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
    print("Loading hotchpotch/JQaRA test split...", flush=True)
    dataset = load_dataset("hotchpotch/JQaRA", split="test")
    groups = select_questions(dataset, args.limit)
    pairs, qrels = build_inputs(groups)
    print(
        f"Selected questions={len(groups)} pairs={len(pairs)} "
        f"max_length={args.max_length} batch_size={args.batch_size}",
        flush=True,
    )

    results = {
        "dataset": "hotchpotch/JQaRA",
        "split": "test",
        "models": [
            evaluate_model(args.baseline, groups, pairs, qrels, args),
            evaluate_model(args.candidate, groups, pairs, qrels, args),
        ],
    }
    baseline, candidate = results["models"]
    results["delta_candidate_minus_baseline"] = {
        key: round(candidate[key] - baseline[key], 6)
        for key in ("ndcg@10", "mrr@10", "hit@10", "ndcg@100", "mrr@100")
    }
    print(json.dumps(results, ensure_ascii=False, indent=2), flush=True)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(
            json.dumps(results, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )


if __name__ == "__main__":
    main()
