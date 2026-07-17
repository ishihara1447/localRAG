#!/usr/bin/env -S uv run --script
# /// script
# dependencies = [
#   "datasets>=3.0",
#   "numpy>=1.26",
#   "onnxruntime>=1.20",
#   "ranx>=0.3",
#   "transformers>=4.45,<5",
# ]
# ///
"""Compare local int8 ONNX rerankers on the official JQaRA test split."""

from __future__ import annotations

import argparse
import gc
import json
import os
import resource
import time
from collections import OrderedDict
from pathlib import Path

import numpy as np
import onnxruntime as ort
from datasets import load_dataset
from ranx import Qrels, Run, evaluate
from transformers import AutoTokenizer


METRICS = ["ndcg@10", "mrr@10", "ndcg@100", "mrr@100"]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-dir", type=Path, required=True)
    parser.add_argument("--candidate-dir", type=Path, required=True)
    parser.add_argument("--baseline-name", default="current-bge-reranker-v2-m3-int8")
    parser.add_argument(
        "--candidate-name", default="japanese-bge-reranker-v2-m3-v1-int8"
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=0,
        help="Number of questions to evaluate; 0 means the full test split.",
    )
    parser.add_argument("--batch-size", type=int, default=32)
    parser.add_argument("--max-length", type=int, default=512)
    parser.add_argument("--threads", type=int, default=0)
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
    groups = OrderedDict()
    for row in dataset:
        qid = str(row["q_id"])
        if qid in selected_set:
            groups.setdefault(qid, []).append(row)
    return groups


def build_inputs(groups):
    pairs = []
    qrels = {}
    for qid, rows in groups.items():
        question = str(rows[0]["question"])
        qrels[qid] = {}
        for row in rows:
            docid = str(row["id"])
            pairs.append((question, f"{row['title']} {row['text']}"))
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


def find_model(model_dir: Path) -> Path:
    for candidate in (
        model_dir / "onnx" / "model_quantized.onnx",
        model_dir / "model_quantized.onnx",
    ):
        if candidate.is_file():
            return candidate
    raise FileNotFoundError(f"model_quantized.onnx not found under {model_dir}")


def evaluate_model(name, model_dir, groups, pairs, qrels, args):
    started = time.perf_counter()
    tokenizer = AutoTokenizer.from_pretrained(model_dir, local_files_only=True)
    options = ort.SessionOptions()
    if args.threads > 0:
        options.intra_op_num_threads = args.threads
    session = ort.InferenceSession(
        find_model(model_dir),
        sess_options=options,
        providers=["CPUExecutionProvider"],
    )
    scores = []
    inference_seconds = 0.0
    total_batches = (len(pairs) + args.batch_size - 1) // args.batch_size
    print(
        f"Evaluating {name}: pairs={len(pairs)} batches={total_batches} "
        f"batch_size={args.batch_size} threads={args.threads or 'auto'}",
        flush=True,
    )

    for batch_index, offset in enumerate(range(0, len(pairs), args.batch_size), 1):
        batch = pairs[offset : offset + args.batch_size]
        encoded = tokenizer(
            [pair[0] for pair in batch],
            [pair[1] for pair in batch],
            padding=True,
            truncation=True,
            max_length=args.max_length,
            return_tensors="np",
        )
        inputs = {
            item.name: encoded[item.name].astype(np.int64, copy=False)
            for item in session.get_inputs()
        }
        inference_started = time.perf_counter()
        logits = session.run(None, inputs)[0]
        inference_seconds += time.perf_counter() - inference_started
        scores.extend(np.asarray(logits)[:, 0].tolist())
        if batch_index == 1 or batch_index % 100 == 0 or batch_index == total_batches:
            print(
                f"  {batch_index}/{total_batches} batches "
                f"({offset + len(batch)}/{len(pairs)} pairs)",
                flush=True,
            )

    run = build_run(groups, scores)
    ranx_scores = evaluate(Qrels(qrels), Run(run), METRICS)
    result = {
        "model": name,
        "model_dir": str(model_dir),
        "questions": len(groups),
        "pairs": len(pairs),
        "ndcg@10": float(ranx_scores["ndcg@10"]),
        "mrr@10": float(ranx_scores["mrr@10"]),
        "hit@10": float(hit_at_10(run, qrels)),
        "ndcg@100": float(ranx_scores["ndcg@100"]),
        "mrr@100": float(ranx_scores["mrr@100"]),
        "inference_seconds": round(inference_seconds, 2),
        "elapsed_seconds": round(time.perf_counter() - started, 2),
        "peak_rss_mib": round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024, 1),
    }
    print(json.dumps(result, ensure_ascii=False, indent=2), flush=True)
    del tokenizer, session, scores, run
    gc.collect()
    return result


def main() -> None:
    args = parse_args()
    os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
    dataset = load_dataset("hotchpotch/JQaRA", split="test")
    groups = select_questions(dataset, args.limit)
    pairs, qrels = build_inputs(groups)
    print(
        f"Selected questions={len(groups)} pairs={len(pairs)} "
        f"max_length={args.max_length}",
        flush=True,
    )
    results = {
        "dataset": "hotchpotch/JQaRA",
        "split": "test",
        "backend": "onnxruntime-cpu-int8",
        "models": [
            evaluate_model(
                args.baseline_name,
                args.baseline_dir,
                groups,
                pairs,
                qrels,
                args,
            ),
            evaluate_model(
                args.candidate_name,
                args.candidate_dir,
                groups,
                pairs,
                qrels,
                args,
            ),
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
