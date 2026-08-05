# /// script
# requires-python = ">=3.10"
# dependencies = ["httpx>=0.27"]
# ///
"""complex-eval.py — 複雑質問20問（集約/マルチホップ/比較/要約/推論/unanswerable）の評価。

設計: `docs/COMPLEX_QA_EVAL_SET_DESIGN_2026-07-26.md`
実装計画: `docs/QUALITY_ROADMAP_2026-07-26.md` §4 Phase A（S05〜S07）
設問データ: `fixtures/complex/hakusho-complex-qa.json`（**コードに設問を埋めない**）

既存3スクリプト（hakusho / ambiguous / scale）とは**別レポート・別ファイル**で扱う。
難易度が違うセットなので合計点を混ぜてはならない（設計書 §7-4）。

フェーズ
--------
    --phase retrieval   LLM不使用。vector-search を叩き Coverage@k / All-Hit@k /
                        Hit Rate@k / MRR / nDCG@k を k=4/8/16/32 で出す。決定的。
    --phase generate    chat API を叩き、**回答全文をJSONに保存する**だけ（採点しない）。
                        設問ごとに一意な sessionId、openAiTemp=0。
    --phase judge       保存済みJSONに Layer0/1（[N]/[E]/[X] の決定的判定）を適用。
                        生成をやり直さずに採点だけ掛け直せる。
                        `--judge-model` を渡したときだけ Layer2（[P] の LLM-as-judge）が動く。
    --phase calibrate   S08。judge を**決定的要素([N]/[E])**にも当て、決定的採点との
                        Cohen's κ を測る（人手ラベル無しの擬似正解キャリブレーション）。
                        `--human-labels` を渡すと人手ラベルとの κ も出す。
    --phase report      複数runの集計・クラスタブートストラップCI・Wilson CI・McNemar。
    --phase failmode    保存済み retrieval JSON（＋任意で judge JSON）から失敗モードを分類。
                        **anchor_coverage@8 が主・page_coverage は参考値**（A1, 2026-07-27）。

実行例
------
    HAKUSHO_SLUG=<slug> uv run scripts/complex-eval.py --phase retrieval \
        --out /tmp/complex-retrieval.json
    HAKUSHO_SLUG=<slug> uv run scripts/complex-eval.py --phase generate --run 1 \
        --out /tmp/complex-gen-run1.json
    uv run scripts/complex-eval.py --phase judge --in /tmp/complex-gen-run1.json \
        --out /tmp/complex-judged-run1.json
    # judge層あり（[P]も採点する。決定的採点は影響を受けない）
    uv run scripts/complex-eval.py --phase judge --in /tmp/complex-gen-run1.json \
        --judge-model qwen3:8b --out /tmp/complex-judged-run1.json
    # S08 キャリブレーション（擬似正解 = 決定的採点）
    uv run scripts/complex-eval.py --phase calibrate --judge-model qwen3:8b \
        /tmp/complex-gen-run1.json --out /tmp/calib.json
    uv run scripts/complex-eval.py --phase report /tmp/complex-judged-run*.json

環境変数: LOCALRAG_BASE_URL, HAKUSHO_SLUG(必須), LOCALRAG_STORAGE_DOCS,
          PAGE_OFFSET, PAGE_TOLERANCE,
          JUDGE_OLLAMA_URL(既定 http://localhost:11435 = **開発機の評価専用 Ollama**),
          JUDGE_MODEL, JUDGE_SEED。

🔴 judge モデルは開発機専用であり顧客配布物に含めない（`scripts/_judge.py` の冒頭を参照）。
   製品の Ollama（rag-ollama / runtime/ollama-models）には置かないこと。
"""

from __future__ import annotations

import argparse
import json
import math
import os
import random
import re
import sys
import time
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import httpx  # noqa: E402

from _eval_common import (  # noqa: E402
    contains_marked,
    iter_bounded,
    normalize,
    normalize_marked,
    strip_think,
)
from _judge import (available as judge_available,  # noqa: E402
                    cohen_kappa, judge_element_llm, kappa_ci, unload as judge_unload)
from _retrieval import (BASE_URL, TIMEOUT, PAGE_TOLERANCE, PageIndex,  # noqa: E402
                        annotate, delete_api_keys, new_api_key, vector_search)

# 開発機の評価専用 Ollama（製品コンテナ rag-ollama とは別物）。
JUDGE_URL = os.environ.get("JUDGE_OLLAMA_URL", "http://127.0.0.1:11435")
KAPPA_MIN = 0.7   # S08 の採用下限（設計書 §6-4）

FIXTURE = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       "fixtures", "complex", "hakusho-complex-qa.json")
KS = (4, 8, 16, 32)
CATS = ("C1", "C2", "C3", "C4", "C5", "C6")
CAT_LABEL = {"C1": "集約・構成", "C2": "マルチホップ", "C3": "比較",
             "C4": "要約", "C5": "推論・含意", "C6": "unanswerable"}


def load_set(path: str = FIXTURE) -> dict:
    with open(path, encoding="utf-8") as f:
        return json.load(f)


# ==========================================================================
# phase: retrieval
# ==========================================================================

def _gold_phys(case: dict) -> dict[int, int]:
    """{物理ページ: weight}"""
    return {int(g["phys"]): int(g["weight"]) for g in case["gold_pages"]}


def _covered_pages(results, gold: dict[int, int]) -> dict[int, int]:
    """gold物理ページ -> それを最初に取れた rank。±PAGE_TOLERANCE を許容。"""
    ranks: dict[int, int] = {}
    for g in gold:
        for r in results:
            p = r.get("page")
            if p is not None and abs(int(p) - g) <= PAGE_TOLERANCE:
                ranks[g] = r["rank"]
                break
    return ranks


def _covered_anchors(results, anchors) -> dict[str, int]:
    texts = [(r["rank"], normalize(r["text"])) for r in results]
    ranks: dict[str, int] = {}
    for a in anchors:
        na = normalize(a)
        if not na:
            continue
        for rank, t in texts:
            if na in t:
                ranks[a] = rank
                break
    return ranks


def _ndcg(results, gold: dict[int, int], k: int) -> float:
    seen: set[int] = set()
    rels: list[float] = []
    for r in results[:k]:
        p = r.get("page")
        rel = 0.0
        if p is not None:
            for g, w in gold.items():
                if g not in seen and abs(int(p) - g) <= PAGE_TOLERANCE:
                    rel, _ = float(w), seen.add(g)
                    break
        rels.append(rel)
    def dcg(v): return sum(x / math.log2(i + 2) for i, x in enumerate(v))
    ideal = sorted((float(w) for w in gold.values()), reverse=True)[:k]
    return dcg(rels) / dcg(ideal) if ideal and dcg(ideal) > 0 else 0.0


def phase_retrieval(args) -> dict:
    data = load_set(args.fixture)
    index = PageIndex.autodetect()
    slug = os.environ["HAKUSHO_SLUG"]
    out = {"phase": "retrieval", "slug": slug, "ks": list(KS),
           "document": os.path.basename(index.path), "cases": []}

    with httpx.Client() as c:
        h = {"Authorization": f"Bearer {new_api_key(c, 'complex-eval')}"}
        try:
            for case in data["cases"]:
                gold = _gold_phys(case)
                row = {"id": case["id"], "category": case["category"],
                       "n_gold": len(gold), "n_anchor": len(case["anchors"]), "k": {}}
                for k in KS:
                    res = annotate(vector_search(c, h, slug, case["question"], k), index)
                    pr = _covered_pages(res, gold)
                    ar = _covered_anchors(res, case["anchors"])
                    row["k"][str(k)] = {
                        "returned": len(res),
                        "pages": [r.get("page") for r in res],
                        "page_covered": sorted(pr), "page_ranks": {str(p): r for p, r in pr.items()},
                        "anchor_covered": sorted(ar), "anchor_ranks": ar,
                        "coverage": (len(pr) / len(gold)) if gold else None,
                        "anchor_coverage": (len(ar) / len(case["anchors"])) if case["anchors"] else None,
                        "hit": bool(pr) if gold else None,
                        "anchor_hit": bool(ar) if case["anchors"] else None,
                        "mrr": (1.0 / min(pr.values())) if pr else 0.0,
                        "anchor_mrr": (1.0 / min(ar.values())) if ar else 0.0,
                        "ndcg": _ndcg(res, gold, k) if gold else None,
                    }
                out["cases"].append(row)
                m = row["k"]["8"]
                cov = "n/a" if m["coverage"] is None else f"{m['coverage']:.2f}"
                print(f"[{case['id']}] {case['category']} "
                      f"Coverage@8={cov} ({len(m['page_covered'])}/{row['n_gold']}) "
                      f"Anchor@8={len(m['anchor_covered'])}/{row['n_anchor']} "
                      f"MRR={m['mrr']:.3f}  {case['question'][:28]}…")
        finally:
            delete_api_keys(c, h)

    report_retrieval(out)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump(out, f, ensure_ascii=False, indent=1)
        print(f"\n(retrieval結果JSON → {args.out})")
    return out


def _mean(v):
    v = [x for x in v if x is not None]
    return sum(v) / len(v) if v else 0.0


def report_retrieval(out: dict) -> None:
    cases = out["cases"]
    ans = [c for c in cases if c["n_gold"] > 0]   # gold を持つ設問のみ指標対象
    print("\n=== retrieval 指標（gold ページ方式 / n="
          f"{len(ans)}問, gold無しのunanswerable {len(cases)-len(ans)}問は除外） ===")
    print(f"{'k':>4} {'Coverage':>9} {'All-Hit':>8} {'HitRate':>8} {'MRR':>7} {'nDCG':>7}")
    for k in out["ks"]:
        m = [c["k"][str(k)] for c in ans]
        print(f"{k:>4} {_mean([x['coverage'] for x in m]):>9.3f}"
              f" {sum(1 for x in m if x['coverage'] == 1.0)/len(m):>8.3f}"
              f" {sum(1 for x in m if x['hit'])/len(m):>8.3f}"
              f" {_mean([x['mrr'] for x in m]):>7.3f}"
              f" {_mean([x['ndcg'] for x in m]):>7.3f}")

    aa = [c for c in cases if c["n_anchor"] > 0]
    print(f"\n=== retrieval 指標（アンカー方式 / n={len(aa)}問） ===")
    print(f"{'k':>4} {'Coverage':>9} {'All-Hit':>8} {'HitRate':>8} {'MRR':>7}")
    for k in out["ks"]:
        m = [c["k"][str(k)] for c in aa]
        print(f"{k:>4} {_mean([x['anchor_coverage'] for x in m]):>9.3f}"
              f" {sum(1 for x in m if x['anchor_coverage'] == 1.0)/len(m):>8.3f}"
              f" {sum(1 for x in m if x['anchor_hit'])/len(m):>8.3f}"
              f" {_mean([x['anchor_mrr'] for x in m]):>7.3f}")

    print("\n=== カテゴリ別 Coverage@8 / Coverage@32（ページ方式） ===")
    for cat in CATS:
        sub = [c for c in ans if c["category"] == cat]
        if not sub:
            print(f"  {cat} {CAT_LABEL[cat]:<14}: (gold無し)")
            continue
        print(f"  {cat} {CAT_LABEL[cat]:<14}: @8={_mean([c['k']['8']['coverage'] for c in sub]):.3f}"
              f"  @32={_mean([c['k']['32']['coverage'] for c in sub]):.3f}  (n={len(sub)})")

    print("\n=== カテゴリ別 anchor_coverage@8 / @32（★アンカー方式・主指標） ===")
    for cat in CATS:
        sub = [c for c in aa if c["category"] == cat]
        if not sub:
            print(f"  {cat} {CAT_LABEL[cat]:<14}: (anchor無し)")
            continue
        print(f"  {cat} {CAT_LABEL[cat]:<14}: "
              f"@8={_mean([c['k']['8']['anchor_coverage'] for c in sub]):.3f}"
              f"  @32={_mean([c['k']['32']['anchor_coverage'] for c in sub]):.3f}  (n={len(sub)})")

    # ★ k を増やせば取れるのか / 増やしても取れないのか の切り分け
    #
    # 【2026-07-27 A1】判定の主軸を page_coverage → **anchor_coverage** に切り替えた。
    #   ページ方式は「その gold ページのチャンクが1つでも取れたか」しか見ないため、
    #   **必要な数値を1つも含まない隣接チャンクでも 1.00 を返す**。
    #   実際にこの指標に2度誤誘導されている（クッションの k 非単調性の解釈 /
    #   Q12・Q15 を「生成失敗」と誤分類）。ページ方式の値は参考として併記するが、
    #   **分類の根拠には使わない**（docs/HANDOFF.md §2）。
    print("\n=== 設問別: k を増やしたときの anchor_coverage の伸び（★投資判断の根拠／アンカー方式） ===")
    print(f"{'ID':<5}{'cat':<4}{'a@4':>6}{'a@8':>6}{'a@16':>6}{'a@32':>6}"
          f" |{'p@8':>6}{'p@32':>7} | 判定")
    rank_bound, index_bound, solved, partial = [], [], [], []
    for c in aa:
        v = [c["k"][str(k)]["anchor_coverage"] for k in out["ks"]]
        c4, c8, c16, c32 = v
        if c8 == 1.0:
            verdict, bucket = "既に全anchor取得済み(@8)", solved
        elif c32 > c8:
            verdict, bucket = "★kを増やせば取れる＝ランキングの問題", rank_bound
        elif c32 < 1.0:
            verdict, bucket = "★kを増やしても取れない＝索引・チャンク分割の問題", index_bound
        else:
            verdict, bucket = "その他", partial
        bucket.append(c["id"])
        p8 = c["k"]["8"]["coverage"]
        p32 = c["k"]["32"]["coverage"]
        ps8 = " n/a" if p8 is None else f"{p8:.2f}"
        ps32 = " n/a" if p32 is None else f"{p32:.2f}"
        print(f"{c['id']:<5}{c['category']:<4}{c4:>6.2f}{c8:>6.2f}{c16:>6.2f}{c32:>6.2f}"
              f" |{ps8:>6}{ps32:>7} | {verdict}")
    print(f"\n  @8で全anchor取得済み          : {len(solved)}問 {solved}")
    print(f"  kを増やせば取れる(ランキング) : {len(rank_bound)}問 {rank_bound}")
    print(f"  kを増やしても取れない(索引)   : {len(index_bound)}問 {index_bound}"
          f"  ← この件数が Phase E（チャンク構造化）の投資判断の根拠")
    if partial:
        print(f"  その他                        : {len(partial)}問 {partial}")
    print("  ※ p@8 / p@32 はページ方式の参考値。分類には使っていない（A1）")

    print("\n=== 取り切れていない anchor（@32時点）===")
    for c in aa:
        m = c["k"]["32"]
        if m["anchor_coverage"] is not None and m["anchor_coverage"] < 1.0:
            miss = [a for a in _case_anchors(c) if a not in set(m["anchor_covered"])] \
                if _case_anchors(c) else []
            print(f"  {c['id']}: anchor {len(m['anchor_covered'])}/{c['n_anchor']}件取得"
                  f"（未取得 {c['n_anchor'] - len(m['anchor_covered'])}件"
                  f"{'' if not miss else ': ' + ', '.join(miss)}）"
                  f" / 参考: page {len(m['page_covered'])}/{c['n_gold']}件")

    classify_and_report(out, None)


def _case_anchors(row: dict) -> list[str]:
    """fixture 側のアンカー一覧（retrieval JSON には未取得アンカー名が残らないため補う）。"""
    try:
        data = load_set()
    except Exception:
        return []
    for c in data["cases"]:
        if c["id"] == row["id"]:
            return list(c.get("anchors") or [])
    return []


# ==========================================================================
# 失敗モード分類（A1: アンカー方式を主・ページ方式を従）
# ==========================================================================
#
# 【なぜアンカー方式が主なのか】
#   page_coverage は「gold ページ由来のチャンクが1つでも取れたか」だけを見る。
#   本製品は文抽出クッションでチャンク本文を非連続な文の集合に置き換えるため、
#   **必要な数値・固有名詞を1つも含まないチャンクでも page_coverage=1.00 になる**。
#   実測で Q12・Q15・Q18 は page_coverage@8=1.00 / anchor_coverage@8=0.00 であり、
#   ページ方式だけを見て「生成失敗」と分類したのは誤りだった（docs/HANDOFF.md §2）。
#
# 分類則（すべて @8 = 製品既定 topN。しきい値はコードに固定して事後変更しない）
#   ret 側: anchor_coverage@8   （anchors を持たない設問のみ page_coverage@8 に退避）
#   gen 側: det_coverage        （[N]/[E] 必須要素。judge 出力がある場合のみ）
#
#   anchor@8 == 0.0                      → (A) 検索失敗（必要な事実が1つも届いていない）
#   0 < anchor@8 < 1.0 かつ gen 未達      → (A') 検索の部分失敗
#   0 < anchor@8 < 1.0 かつ gen 達成      → (B) 出典なき正答の疑い
#   anchor@8 == 1.0 かつ gen 未達         → (C) 生成失敗
#   anchor@8 == 1.0 かつ gen 達成         → OK
#   （gen 情報が無い場合は ret 側だけで (A)/(A')/検索OK を出す）

RET_METRIC_K = "8"


def _ret_signal(row: dict) -> tuple[float | None, str]:
    """(主指標の値, 使った指標名)。アンカーが定義されていれば必ずアンカーを使う。"""
    m = row["k"][RET_METRIC_K]
    if row.get("n_anchor", 0) > 0 and m.get("anchor_coverage") is not None:
        return m["anchor_coverage"], "anchor_coverage@8"
    if row.get("n_gold", 0) > 0 and m.get("coverage") is not None:
        return m["coverage"], "page_coverage@8(退避)"
    return None, "n/a"


def classify_failure(ret_row: dict, judge_row: dict | None) -> dict:
    """1設問の失敗モードを返す。**anchor_coverage が主、page_coverage は参考値**。"""
    a, metric = _ret_signal(ret_row)
    m8 = ret_row["k"][RET_METRIC_K]
    page = m8.get("coverage")
    det = judge_row.get("det_coverage") if judge_row else None
    hall = bool(judge_row.get("hallucination")) if judge_row else None

    if a is None:
        mode, why = "n/a", "gold/anchor が定義されていない設問（unanswerable）"
    elif a == 0.0:
        mode = "(A) 検索失敗"
        why = "必要な事実が1つもLLMに届いていない"
    elif a < 1.0:
        if det is not None and det >= 1.0:
            mode, why = "(B) 出典なき正答の疑い", "検索が不完全なのに決定的要素は全充足"
        else:
            mode, why = "(A') 検索の部分失敗", "必要な事実の一部しか届いていない"
    else:
        if det is None:
            mode, why = "検索OK", "必要な事実はすべて届いている（生成側は未評価）"
        elif det >= 1.0:
            mode, why = "OK", "検索・生成とも達成"
        else:
            mode, why = "(C) 生成失敗", "事実は届いているのに回答に出せていない"
    return {"id": ret_row["id"], "category": ret_row["category"], "mode": mode, "why": why,
            "metric": metric, "ret": a, "page_coverage@8": page,
            "det_coverage": det, "hallucination": hall}


def classify_and_report(ret: dict, judged: dict | None) -> list[dict]:
    jmap = {c["id"]: c for c in judged["cases"]} if judged else {}
    rows = [classify_failure(r, jmap.get(r["id"])) for r in ret["cases"]]
    title = "失敗モード分類（★anchor_coverage@8 が主・page_coverage は参考）"
    if judged:
        title += f" / 生成 run={judged.get('run')}"
    print(f"\n=== {title} ===")
    print(f"{'ID':<5}{'cat':<4}{'anchor@8':>9}{'page@8':>8}{'det':>7}  モード")
    fallback = []
    for r in rows:
        rv = " n/a" if r["ret"] is None else f"{r['ret']:.2f}"
        pv = " n/a" if r["page_coverage@8"] is None else f"{r['page_coverage@8']:.2f}"
        dv = "  -" if r["det_coverage"] is None else f"{r['det_coverage']:.2f}"
        flag = " ★HALLUCINATION" if r["hallucination"] else ""
        # アンカー未定義でページ方式に退避した設問は、判定が弱いことを必ず明示する
        if not r["metric"].startswith("anchor"):
            rv = "(page)"
            fallback.append(r["id"])
        print(f"{r['id']:<5}{r['category']:<4}{rv:>9}{pv:>8}{dv:>7}  {r['mode']}{flag}")
    if fallback:
        print(f"  ⚠ アンカー未定義のためページ方式に退避した設問（判定の信頼度が低い）: {fallback}")
    print("  ---- 内訳:")
    for mode in ("(A) 検索失敗", "(A') 検索の部分失敗", "(B) 出典なき正答の疑い",
                 "(C) 生成失敗", "検索OK", "OK", "n/a"):
        ids = [r["id"] for r in rows if r["mode"] == mode]
        if ids:
            print(f"       {mode:<22}: {len(ids)}問 {ids}")
    # ★ページ方式に従っていたら誤分類していた設問を明示する（再発防止）
    misled = [r for r in rows
              if r["metric"].startswith("anchor") and r["page_coverage@8"] == 1.0
              and r["ret"] is not None and r["ret"] < 1.0]
    if misled:
        print("  ---- ★ページ方式なら『検索は成功』と誤判定していた設問: "
              f"{[r['id'] for r in misled]}")
    return rows


def phase_failmode(args) -> None:
    ret = json.load(open(args.retrieval, encoding="utf-8"))
    judged = json.load(open(args.files[0], encoding="utf-8")) if args.files else None
    classify_and_report(ret, judged)


# ==========================================================================
# phase: generate
# ==========================================================================

def phase_generate(args) -> dict:
    data = load_set(args.fixture)
    slug = os.environ["HAKUSHO_SLUG"]
    run_tag = args.run or uuid.uuid4().hex[:8]
    out = {"phase": "generate", "slug": slug, "run": str(run_tag),
           "started_at": time.strftime("%Y-%m-%dT%H:%M:%S"), "cases": []}
    with httpx.Client() as c:
        h = {"Authorization": f"Bearer {new_api_key(c, 'complex-eval')}"}
        try:
            # 決定性の担保: 評価は必ず temperature=0（内部監査 2026-07-16）
            c.post(f"{BASE_URL}/api/v1/workspace/{slug}/update", headers=h,
                   json={"openAiTemp": 0})
            if args.top_n:
                c.post(f"{BASE_URL}/api/v1/workspace/{slug}/update", headers=h,
                       json={"topN": args.top_n})
            if args.chat_model:
                c.post(f"{BASE_URL}/api/v1/workspace/{slug}/update", headers=h,
                       json={"chatProvider": "ollama", "chatModel": args.chat_model})
            print(f"(temperature=0, mode=query, run={run_tag}, sessionId per question)")
            for case in data["cases"]:
                t0 = time.time()
                # 設問ごとに一意な sessionId。複雑質問は回答が長く、
                # 前問が履歴に残ると次問を汚染するため必須。
                sid = f"complex-{run_tag}-{case['id']}"
                r = c.post(f"{BASE_URL}/api/v1/workspace/{slug}/chat", headers=h,
                           json={"message": case["question"], "mode": "query",
                                 "sessionId": sid},
                           timeout=TIMEOUT)
                r.raise_for_status()
                d = r.json()
                out["cases"].append({
                    "id": case["id"], "category": case["category"],
                    "question": case["question"],
                    "answer": strip_think(d.get("textResponse", "") or ""),
                    "sec": round(time.time() - t0, 1),
                    "sources": d.get("sources", []) or [],
                })
                print(f"[gen] {case['id']} {out['cases'][-1]['sec']}s "
                      f"{len(out['cases'][-1]['answer'])}字")
        finally:
            delete_api_keys(c, h)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump(out, f, ensure_ascii=False, indent=1)
        print(f"(生成結果JSON → {args.out})")
    return out


# ==========================================================================
# phase: judge （Layer0 + Layer1 = 決定的判定。LLM不要）
# ==========================================================================

# --------------------------------------------------------------------------
# 排他語 `match.not_preceded_by`（2026-07-27 追加）
#
# 何をするか
#   `[N]`/`[E]` の alias、および `[X]` の regex が当たったとき、
#   **その一致の直前**（回答本文側）がここに挙げた語で終わっていたら、その一致を採らない。
#   ＝ 否定後読み `(?<!即応)` を、フィクスチャ側から宣言的に足せるようにしたもの。
#   判定は Layer0 正規化した文字列どうしで行うので、`即応 予備自衛官手当` のように
#   途中に空白・改行が入っていても効く。
#
#   **一致の位置**を見るのであって「回答のどこかに排他語があるか」を見るのではない。
#   したがって同じ回答に正しい表記と誤った表記が両方あれば、誤った側だけが従来どおり出る。
#   また、一致が排他語の**先頭から**始まっている場合（`即応予備自衛官…` に
#   `即応予備自衛官.{0,16}12,?300` が当たる場合）は直前に `即応` が無いのでブロックされない。
#   ＝ 同じ [X] の中の別の選択肢を巻き添えにしない。
#
# なぜ必要か
#   日本語には語境界の空白が無く、`即応予備自衛官手当` ⊃ `予備自衛官手当` のような
#   包含関係を部分一致では区別できない。Q11 の [X] 正規表現
#   `予備自衛官手当.{0,10}18,?500` は、**正しい表記**
#   `即応予備自衛官手当（月額18,500円）` にも発火していた
#   （実測: scratchpad/a1c1c2/probe_after.json i=1）。
#   docs/RESEARCH_SCORING_AND_EXTRACTION_NOISE_2026-07-27.md の推奨度A
#   「alias定義に排他語フィールドを追加」に対応する。
#
# 🔴 これは**恒久策ではない**（応急処置）
#   同調査の結論（推奨度A+）は「`[X]` の判定単位を文字列一致から
#   **claim の含意判定（LLM-as-judge）**に変え、正規表現は候補抽出の前段フィルタへ
#   降格する2層構成にする」であり、本フィールドはその**設計変更までのつなぎ**である。
#   限界を明示しておく:
#     1. 競合語をあらかじめ列挙できる場合にしか効かない（一般化しない）
#     2. 前方向しか見ない。`自衛隊` ⊂ `自衛隊員` のような**後方**の包含は救えない
#     3. **文脈は見ない。** Q11 で実際に多いのは、見出し `**即応予備自衛官**` の配下で
#        `予備自衛官手当（月額18,500円）` と**略記**するケースで、
#        一致の直前に `即応` が無いため本フィールドでは救えない
#        （＝ 表層の包含事故は消せるが、主張の当否は判定できない）
# --------------------------------------------------------------------------

NOT_PRECEDED_BY = "not_preceded_by"


def _blocked_by_prefix(text_before_match: str, terms) -> bool:
    """一致の直前 `text_before_match` が排他語で終わっているか（正規化して比較）。"""
    if not terms:
        return False
    left = normalize(text_before_match)
    return any(nt and left.endswith(nt) for nt in (normalize(t) for t in terms))


# --------------------------------------------------------------------------
# [X] 判定の誤検出ガード（2026-08-05 追加）
# --------------------------------------------------------------------------
#
# なぜ要るか: 166問での実測で、[X] が発火した11件のうち**10件が誤検出**だった
# （誤検出率91%）。真の捏造は1件のみ。この状態では捏造の有無を測れず、
# 「文脈を増やす施策が精度を上げたのか忠実性を売り払ったのか」を判別できない。
# 実際 2026-08-05 に、捏造が1→3件に増える変更を「増加なし」と誤報告している。
#
# 誤検出の型は4つあった:
#   ① 否定語尾を見ない  「変更されていません」を「変更」と判定（Q077/Q083/Q090）
#   ② 文をまたぐ        `.{0,30}` が `。` を越えて別の文の語を拾う（Q19）
#   ③ 比較対象またぎ    `機能別[^。]{0,8}7つ` が「機能別で4つ、地域別で7つ」に一致（Q088）
#   ④ 文脈語の取り違え  「沖縄分を合わせて」を「沖縄分が大きい」と判定（Q091）
#
# ここでは①②を機械的に潰す。③④は型が個別なので fixture 側で対処する
# （164個すべてを直すのではなく、実測で誤検出が出た2個だけ）。
#
# 🔴 真の捏造を消さないことが最優先。Q158/Q139/Q17 が残ることを
#    test_scoring_mft.py で検証している。

# 一致箇所の直後に来たら「捏造ではない」と判断する否定語尾。
# 「〜ません」「〜ない」等。肯定文にも現れる語幹（変更/達成/増加）は、
# これが後続するかどうかでしか肯定否定を判別できない。
_X_NEGATION = re.compile(r"(ません|ませんでした|ない(?![ぁ-ん])|なかった|ず(?:に|、|。)|できかね)")

# 一致直後の何字までを見るか。日本語の述語は概ねこの範囲に収まる。
_X_NEG_WINDOW = 30


def _x_false_positive(text: str, match: "re.Match") -> bool:
    """[X] の一致が誤検出なら True。

    G1: 一致直後に否定語尾がある（「変更されていません」等）
    G2: 一致が文境界（。）をまたいでいる（別の文の語を拾っている）
    """
    # G2: またいだ文をつないで拾っている一致は信用しない
    if "。" in match.group(0):
        return True
    # G1: 直後の窓に否定語尾があれば、その主張は否定されている
    tail = text[match.end(): match.end() + _X_NEG_WINDOW]
    if _X_NEGATION.search(tail):
        return True
    return False


def judge_element(answer: str, el: dict) -> dict:
    """1要素のYES/NO判定。[N]/[E] は alias 一致、[X] は禁止正規表現。

    [P] は LLM-as-judge が必要なため、ここでは verdict=None（未判定）を返す。
    設計上 [P] 無しでも『決定的要素カバー率』で運用できる（設計書 §6-3-1）。

    `match.not_preceded_by`（排他語）を**書いていない要素の挙動は従来と完全に同一**である。
    排他語は述語を狭めるだけで、広げることはない（上のブロックコメント参照）。
    """
    t = el["type"]
    m = el.get("match") or {}
    excl = m.get(NOT_PRECEDED_BY)
    if t in ("N", "E"):
        # 2026-07-26: 単純な `in` から**桁境界つき**一致に変更した。
        # 旧実装は `70000円` が `約270000円` の内部に、`17100` が `約1710000円` の
        # 内部に桁を跨いで一致し、誤ってYES判定していた（S08較正中に発覚）。
        # `normalize_marked()` は1回だけ実行し、alias ループで使い回す。
        marked = normalize_marked(answer)
        if not excl:
            for a in m["alias"]:
                if normalize(a) and contains_marked(marked, a):
                    return {"verdict": True, "evidence": a}
            return {"verdict": False, "evidence": None}
        # 排他語あり: 1件目が弾かれても後続の出現を見に行く（`iter_bounded`）。
        clean = normalize(answer)
        for a in m["alias"]:
            na = normalize(a)
            if not na:
                continue
            for i in iter_bounded(marked, na):
                if not _blocked_by_prefix(clean[:i], excl):
                    return {"verdict": True, "evidence": a}
        return {"verdict": False, "evidence": None}
    if t == "X":
        # [X] は「書いてはいけない主張」。正規化前後の両方で当てる
        # （正規化で空白が消えると .{0,N} の距離感が変わるため）。
        rx = re.compile(m["regex"])
        for s in (answer, normalize(answer)):
            # 排他語が無いときの初回一致は `rx.search(s)` と同一（従来経路と同じ結果）。
            for mt in rx.finditer(s):
                if _blocked_by_prefix(s[:mt.start()], excl):
                    continue
                if _x_false_positive(s, mt):
                    continue
                return {"verdict": True, "evidence": mt.group(0)}
        return {"verdict": False, "evidence": None}
    return {"verdict": None, "evidence": None}


def _p_reference(el: dict) -> str:
    """[P] 要素の Instance-Specific Rubric に使う原典抜粋。"""
    return el.get("judge_reference") or (el.get("match") or {}).get("value") or ""


def _x_reference(case: dict) -> str:
    """[X] の judge に渡す原典抜粋。fixture の gold_quotes を使う。

    [X] 要素自身は judge_reference を持たないため（164個中0個）、
    設問の gold_quotes で代用する。これが無いと judge は照合先を持たず、
    原典どおりに書いた回答を捏造と誤判定する（実測: Q092 は文書をほぼ逐語で
    引用しているのに3回とも捏造判定された）。
    """
    if not case:
        return ""
    qs = case.get("gold_quotes") or []
    out = []
    for q in qs:
        t = q if isinstance(q, str) else (q.get("quote") or q.get("text") or "")
        if t:
            out.append(t.strip())
    return "\n".join(out[:6])


def _judge_x_confirm(jc, args, g: dict, el: dict, det: dict, case: dict) -> dict:
    """決定的判定が [X] を発火させたとき、LLM に真偽を確かめる。

    決定的判定は「禁止された主張が書かれている」と言うが、その9割は
    誤検出だった。ここでは **発火を覆せるかどうか** だけを見る。
    覆せなければ発火のまま（＝捏造）とする。

    3回判定して多数決。割れた場合は verdict=None（人手確認）にする。
    **自動で「捏造なし」と決めてしまわない**のが要点。
    """
    # 🔴 gold_quotes を原典として渡す案は**撤回した**（2026-08-05、実測）。
    # 「文書に無いことを答えた」型の捏造（Q158）で、原典に近い数値が
    # 抜粋に含まれていたため judge が正当と判断し、**3回とも見逃した**。
    # 誤検出の救済（8/10）は変わらず、真の捏造の検出だけ壊れた。
    # 「文書に無いこと」を検出する判定に文書の抜粋を渡してはならない。
    ref = _p_reference(el)
    votes = []
    for i in range(3):
        r = judge_element_llm(
            jc, args.judge_model, g["question"], g["answer"],
            el["claim"], ref, url=args.judge_url,
            partial_is_hit=args.partial_is_hit,
            seed=args.judge_seed + i,          # seed を変えて揺れを見る
            prompt_version=args.judge_prompt)
        votes.append(r.get("verdict"))
    yes = sum(1 for v in votes if v is True)
    no = sum(1 for v in votes if v is False)
    if yes >= 2:
        return {**det, "verdict": True, "x_confirm": "llm_yes", "x_votes": votes}
    if no >= 2:
        return {**det, "verdict": False, "x_confirm": "llm_no", "x_votes": votes}
    # 割れた or 判定不能。自動では決めない
    return {**det, "verdict": None, "x_confirm": "split", "x_votes": votes}


def phase_judge(args) -> dict:
    data = load_set(args.fixture)
    by_id = {c["id"]: c for c in data["cases"]}
    gen = json.load(open(args.inp, encoding="utf-8"))
    out = {"phase": "judge", "run": gen.get("run"), "source": os.path.basename(args.inp),
           "judge_model": args.judge_model or None,
           "judge_prompt": args.judge_prompt if args.judge_model else None, "cases": []}

    # Layer2 は judge モデルを明示したときだけ動く。落ちても評価は止めない（S08 の必須要件）。
    jc = httpx.Client() if args.judge_model else None
    if jc is not None:
        tags = judge_available(jc, args.judge_url)
        if args.judge_model not in tags:
            print(f"警告: judge モデル {args.judge_model} が {args.judge_url} に見つかりません "
                  f"（利用可能: {tags}）。[P] は未判定のまま続行します。", file=sys.stderr)
            jc.close()
            jc = None
            out["judge_model"] = None

    try:
        for g in gen["cases"]:
            case = by_id[g["id"]]
            els = []
            for el in case["elements"]:
                v = judge_element(g["answer"], el)
                # [X] の二次判定（2026-08-05 追加）
                # 決定的判定は誤検出が91%あった（166問で11件発火、真の捏造は1件）。
                # 誤検出の型は「AよりもBが大きい」を「Bが大きい」と読む等、
                # **比較の向きや文脈の理解を要する**ものが主で、正規表現では
                # 原理的に判別できない（PREREG_X_JUDGE_2026-08-05.md §9-2）。
                #
                # そこで決定的判定は**一次フィルタ**として使い、
                # **発火した件だけ** LLM に真偽を確かめさせる。
                # 発火は166問中11件なので判定コストは小さい。
                # 揺れ対策として3回判定し多数決を採る。割れたら None（人手確認へ）。
                if el["type"] == "X" and v.get("verdict") is True and jc is not None:
                    v = _judge_x_confirm(jc, args, g, el, v, case)
                if el["type"] == "P" and jc is not None:
                    v = judge_element_llm(jc, args.judge_model, g["question"], g["answer"],
                                          el["claim"], _p_reference(el), url=args.judge_url,
                                          partial_is_hit=args.partial_is_hit,
                                          seed=args.judge_seed,
                                          prompt_version=args.judge_prompt)
                els.append({"id": el["id"], "type": el["type"], "required": el["required"],
                            "claim": el["claim"], **v})
            req_det = [e for e in els if e["required"] and e["type"] in ("N", "E")]
            hit = sum(1 for e in req_det if e["verdict"])
            x_hits = [e for e in els if e["type"] == "X" and e["verdict"]]
            # [P]（judge依存）は決定的指標とは**別枠**で集計する。
            req_p = [e for e in els if e["required"] and e["type"] == "P"]
            p_judged = [e for e in req_p if e["verdict"] is not None]
            p_hit = sum(1 for e in p_judged if e["verdict"])
            out["cases"].append({
                "id": g["id"], "category": g["category"], "elements": els,
                "det_required": len(req_det), "det_hit": hit,
                "det_coverage": (hit / len(req_det)) if req_det else None,
                "p_required": len(req_p), "p_judged": len(p_judged), "p_hit": p_hit,
                "p_coverage": (p_hit / len(p_judged)) if p_judged else None,
                "hallucination": bool(x_hits),
                "x_evidence": [e["evidence"] for e in x_hits],
                "full_correct": bool(req_det) and hit == len(req_det) and not x_hits,
                "answer_len": len(g["answer"]),
            })
            if jc is not None and req_p:
                print(f"[judge] {g['id']} [P] {p_hit}/{len(p_judged)}"
                      f"{'' if len(p_judged) == len(req_p) else f' (未判定{len(req_p)-len(p_judged)}件)'}")
    finally:
        if jc is not None:
            if args.judge_unload:
                judge_unload(jc, args.judge_model, args.judge_url)
            jc.close()

    report_judge(out)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump(out, f, ensure_ascii=False, indent=1)
        print(f"\n(採点結果JSON → {args.out})")
    return out


def report_judge(out: dict) -> None:
    cs = out["cases"]
    print(f"\n=== 決定的要素カバー率（[N]/[E] の必須要素のみ。judge非依存）run={out.get('run')} ===")
    for c in cs:
        cov = "n/a" if c["det_coverage"] is None else f"{c['det_coverage']:.2f}"
        flag = " ★HALLUCINATION" if c["hallucination"] else ""
        print(f"  {c['id']} {c['category']} {c['det_hit']}/{c['det_required']} = {cov}{flag}")
    tot_r = sum(c["det_required"] for c in cs)
    tot_h = sum(c["det_hit"] for c in cs)
    print(f"  ---- プール比率: {tot_h}/{tot_r} = {tot_h/tot_r:.3f}")
    print(f"  ---- 完全正答(決定的要素のみ): {sum(1 for c in cs if c['full_correct'])}/{len(cs)}")
    print(f"  ---- ハルシネーション: {sum(1 for c in cs if c['hallucination'])}/{len(cs)}")
    print("\n=== カテゴリ別 ===")
    for cat in CATS:
        sub = [c for c in cs if c["category"] == cat]
        if not sub:
            continue
        r = sum(c["det_required"] for c in sub)
        h = sum(c["det_hit"] for c in sub)
        print(f"  {cat} {CAT_LABEL[cat]:<14}: {h}/{r} = {h/r:.3f} (n={len(sub)}問)")

    if out.get("judge_model"):
        pj = sum(c.get("p_judged", 0) for c in cs)
        ph = sum(c.get("p_hit", 0) for c in cs)
        pr = sum(c.get("p_required", 0) for c in cs)
        print(f"\n=== [P] 命題要素（LLM-as-judge / model={out['judge_model']}）※参考値 ===")
        print(f"  judge済み {pj}/{pr} 要素、うち充足 {ph} "
              f"= {ph/pj:.3f}" if pj else "  judge済み 0 要素")
        print("  ※ 主指標は上の『決定的要素カバー率』のまま。judge の κ が採用下限を満たすまで、")
        print("     [P] を含む値を製品判断の根拠にしないこと（docs/JUDGE_MODEL_CALIBRATION_2026-07-26.md）")


# ==========================================================================
# phase: calibrate （S08。judge の信頼性を測る）
# ==========================================================================
#
# 本フェーズの中心的な工夫:
#   S06 で **[N]/[E] の79個の必須要素の正誤が決定的に確定している**。
#   同じ要素を judge にも判定させ、決定的採点との Cohen's κ を測れば
#   **人手ラベル0件で judge の信頼性を推定できる**。
#
#   ⚠ ただしこれは人手ラベルの完全な代替にはならない。決定的に判定できる要素は
#     「文字列が出ていれば正解」という判定が容易な部類に偏っており、
#     judge が本番で担当する [P]（命題・含意・否定）はより難しい。
#     擬似正解の κ は **judge 性能の上限側の推定**として読むこと。
#     最終判断には `--emit-human-sheet` で出した [P] の人手ラベルを併用する。

def _det_reference(el: dict) -> str:
    """[N]/[E] 要素を judge にかけるときの原典抜粋（alias の先頭＝原文表記）。"""
    m = el.get("match") or {}
    return m.get("value") or (m.get("alias") or [""])[0]


def _calib_items(data: dict, gens: list[dict], types: tuple[str, ...],
                 required_only: bool = True) -> list[dict]:
    by_id = {c["id"]: c for c in data["cases"]}
    items = []
    for gen in gens:
        run = str(gen.get("run"))
        for g in gen["cases"]:
            case = by_id[g["id"]]
            for el in case["elements"]:
                if el["type"] not in types or (required_only and not el["required"]):
                    continue
                items.append({
                    "key": f"{run}/{g['id']}/{el['id']}",
                    "run": run, "qid": g["id"], "eid": el["id"], "type": el["type"],
                    "category": g["category"], "question": g["question"],
                    "answer": g["answer"], "claim": el["claim"],
                    "reference": _p_reference(el) if el["type"] == "P" else _det_reference(el),
                    "deterministic": judge_element(g["answer"], el)["verdict"],
                })
    return items


def phase_calibrate(args) -> dict:
    data = load_set(args.fixture)
    gens = [json.load(open(p, encoding="utf-8")) for p in args.files]
    if not args.judge_model:
        print("エラー: --judge-model が必要です。", file=sys.stderr)
        raise SystemExit(2)

    det_items = _calib_items(data, gens, ("N", "E"))
    p_items = _calib_items(data, gens, ("P",), required_only=False)
    if args.calib_limit:
        det_items = det_items[:args.calib_limit]

    out = {"phase": "calibrate", "judge_model": args.judge_model,
           "judge_url": args.judge_url, "seed": args.judge_seed,
           "prompt_version": args.judge_prompt,
           "sources": [os.path.basename(p) for p in args.files],
           "det_items": [], "p_items": [], "determinism": None}

    with httpx.Client() as jc:
        tags = judge_available(jc, args.judge_url)
        if args.judge_model not in tags:
            print(f"エラー: judge モデル {args.judge_model} が {args.judge_url} にありません "
                  f"（利用可能: {tags}）", file=sys.stderr)
            raise SystemExit(3)

        print(f"=== 擬似正解キャリブレーション: {args.judge_model} vs 決定的採点 "
              f"([N]/[E] 必須要素 n={len(det_items)}) ===")
        t0 = time.time()
        for i, it in enumerate(det_items, 1):
            v = judge_element_llm(jc, args.judge_model, it["question"], it["answer"],
                                  it["claim"], it["reference"], url=args.judge_url,
                                  partial_is_hit=args.partial_is_hit, seed=args.judge_seed,
                                  prompt_version=args.judge_prompt)
            rec = {**{k: it[k] for k in
                      ("key", "run", "qid", "eid", "type", "category", "claim", "deterministic")},
                   "judge": v["verdict"], "verdict3": v["verdict3"],
                   "status": v["status"], "evidence": v["evidence"]}
            out["det_items"].append(rec)
            if i % 10 == 0 or i == len(det_items):
                print(f"  {i}/{len(det_items)} 判定済み ({time.time()-t0:.0f}s)")

        # [P] も一度判定しておく（人手ラベル用シートに judge の答えを載せるため）
        print(f"\n=== [P] 要素の judge 判定 (n={len(p_items)}) ===")
        for i, it in enumerate(p_items, 1):
            v = judge_element_llm(jc, args.judge_model, it["question"], it["answer"],
                                  it["claim"], it["reference"], url=args.judge_url,
                                  partial_is_hit=args.partial_is_hit, seed=args.judge_seed,
                                  prompt_version=args.judge_prompt)
            out["p_items"].append({
                **{k: it[k] for k in ("key", "run", "qid", "eid", "category", "claim")},
                "reference": it["reference"], "question": it["question"],
                "answer": it["answer"],
                "judge": v["verdict"], "verdict3": v["verdict3"],
                "status": v["status"], "evidence": v["evidence"]})
            if i % 10 == 0 or i == len(p_items):
                print(f"  {i}/{len(p_items)} 判定済み")

        # 決定性チェック: 先頭 N 件を同一 seed で再判定して一致を見る
        n_rep = min(args.determinism, len(det_items))
        if n_rep:
            print(f"\n=== 決定性チェック: 先頭 {n_rep} 件を再判定 ===")
            same = 0
            for it, rec in zip(det_items[:n_rep], out["det_items"][:n_rep]):
                v = judge_element_llm(jc, args.judge_model, it["question"], it["answer"],
                                      it["claim"], it["reference"], url=args.judge_url,
                                      partial_is_hit=args.partial_is_hit, seed=args.judge_seed,
                                      prompt_version=args.judge_prompt)
                if (v["verdict3"], v["verdict"]) == (rec["verdict3"], rec["judge"]):
                    same += 1
            out["determinism"] = {"n": n_rep, "same": same, "rate": same / n_rep}
            print(f"  一致 {same}/{n_rep} = {same/n_rep:.3f}"
                  f"{'  ✅ 完全一致' if same == n_rep else '  ❌ 再現しない（判定の信頼性以前の問題）'}")

        if args.judge_unload:
            judge_unload(jc, args.judge_model, args.judge_url)

    report_calibrate(out, args)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump(out, f, ensure_ascii=False, indent=1)
        print(f"\n(キャリブレーション結果JSON → {args.out})")
    if args.emit_human_sheet:
        emit_human_sheet(out, args.emit_human_sheet)
    return out


def report_calibrate(out: dict, args) -> None:
    ok = [r for r in out["det_items"] if r["judge"] is not None]
    ng = [r for r in out["det_items"] if r["judge"] is None]
    a = [bool(r["deterministic"]) for r in ok]
    b = [bool(r["judge"]) for r in ok]
    k = cohen_kappa(a, b)
    lo, hi = kappa_ci(a, b)

    print(f"\n{'='*70}")
    print(f"=== S08 擬似正解キャリブレーション結果 (judge={out['judge_model']}) ===")
    print(f"  判定できた要素: {len(ok)}/{len(out['det_items'])}"
          f"（未判定 {len(ng)}件: "
          f"{ {s: sum(1 for r in ng if r['status']==s) for s in {r['status'] for r in ng}} }）")
    if k["kappa"] is None:
        print("  κ: 算出不能（片方のラベルが一定）")
        return
    print(f"  一致率 (Po)   : {k['po']:.3f}   偶然一致 (Pe): {k['pe']:.3f}")
    print(f"  **Cohen's κ  : {k['kappa']:.3f}**  [95%CI {lo:.3f}–{hi:.3f}]（ブートストラップ2000回）")
    print(f"  混同行列: 決定的YES/judgeYES={k['tt']}  決定的YES/judgeNO={k['tf']}"
          f"  決定的NO/judgeYES={k['ft']}  決定的NO/judgeNO={k['ff']}")
    det_yes = k["tt"] + k["tf"]
    det_no = k["ft"] + k["ff"]
    if det_yes:
        print(f"  偽陰性率（決定的YESをjudgeがNO）: {k['tf']}/{det_yes} = {k['tf']/det_yes:.3f}")
    if det_no:
        print(f"  偽陽性率（決定的NOをjudgeがYES）: {k['ft']}/{det_no} = {k['ft']/det_no:.3f}")
    verdict = "採用可（κ ≥ 0.7）" if k["kappa"] >= KAPPA_MIN else \
              f"**採用不可（κ < {KAPPA_MIN}）→ [P] の評価は諦め、決定的要素のみで運用する**"
    print(f"  → 判定: {verdict}")
    print(f"  ⚠ この κ は擬似正解（決定的採点）に対するもの。決定的に判定できる要素は")
    print(f"     判定が容易な部類に偏るため、**[P] に対する judge 性能の上限側の推定**である。")

    if k["tf"] or k["ft"]:
        print("\n  --- 不一致の内訳（judge の癖を見る）---")
        for r in ok:
            if bool(r["deterministic"]) != bool(r["judge"]):
                print(f"    {r['key']} [{r['type']}] 決定的={r['deterministic']} "
                      f"judge={r['verdict3']}  {r['claim'][:40]}")
    if ng:
        print("\n  --- 未判定（人手キュー行き）---")
        for r in ng:
            print(f"    {r['key']} status={r['status']} {r['claim'][:40]}")

    # 人手ラベルがあるなら、judge vs 人手 の κ（本命）も出す
    if args.human_labels and os.path.exists(args.human_labels):
        hmap = load_human_labels(args.human_labels)
        pairs = [(hmap[r["key"]], bool(r["judge"])) for r in out["p_items"]
                 if r["key"] in hmap and r["judge"] is not None]
        print(f"\n=== [P] 人手ラベルとの κ（本命 / n={len(pairs)}） ===")
        if not pairs:
            print("  人手ラベルと突き合わせられる要素がありません。")
            return
        ha, jb = [x for x, _ in pairs], [y for _, y in pairs]
        k2 = cohen_kappa(ha, jb)
        lo2, hi2 = kappa_ci(ha, jb)
        if k2["kappa"] is None:
            print("  κ: 算出不能（片方のラベルが一定）")
            return
        print(f"  一致率 {k2['po']:.3f} / **κ = {k2['kappa']:.3f}** [95%CI {lo2:.3f}–{hi2:.3f}]")
        print(f"  → 判定: {'採用可' if k2['kappa'] >= KAPPA_MIN else '**採用不可 → [P] を諦める**'}")


def load_human_labels(path: str) -> dict[str, bool]:
    """人手ラベルを読む。**記入済みシート(.md) と JSON のどちらでも受け付ける**。

    .md 側は `### \\`<key>\\`` の直後にある `- label: YES|NO`（大小文字不問、○/×/はい/いいえ可）
    を拾う。ユーザーが1ファイルだけ触れば済むようにするための実装。
    """
    if path.endswith(".json"):
        d = json.load(open(path, encoding="utf-8"))
        return {k: bool(v) for k, v in d.get("labels", {}).items() if v in (True, False)}

    yes = {"yes", "y", "ok", "○", "◯", "o", "true", "はい", "1"}
    no = {"no", "n", "ng", "×", "x", "false", "いいえ", "0"}
    labels: dict[str, bool] = {}
    key = None
    for line in open(path, encoding="utf-8"):
        m = re.match(r"^###\s+`([^`]+)`", line.strip())
        if m:
            key = m.group(1)
            continue
        m = re.match(r"^-\s*label:\s*(.*)$", line.strip())
        if m and key:
            v = m.group(1).strip().lower()
            if v in yes:
                labels[key] = True
            elif v in no:
                labels[key] = False
            key = None
    return labels


def emit_human_sheet(out: dict, path: str) -> None:
    """人手ラベル用シート（そのまま ○/× を書ける Markdown）を出力する。

    人手コストを最小化するため、**judge が実際に担当する [P] 要素だけ**を並べる。
    judge の判定は**伏せない**（隠すと再確認のコストが上がる）が、
    アンカリングを避けるため各項目の末尾に置く。
    """
    items = out["p_items"]
    # 人手の読む量を最小化するため**設問単位でまとめる**（同じ回答を要素の数だけ
    # 読み返さなくて済む）。26要素は 20問中 12問にしか現れないので、
    # 実際に読む回答は 12 本で足りる。
    groups: dict[tuple[str, str], list[dict]] = {}
    for r in items:
        groups.setdefault((r["run"], r["qid"]), []).append(r)

    lines = [
        "# judge キャリブレーション用 人手ラベルシート",
        "",
        f"- judge モデル: `{out['judge_model']}`（**開発機専用・顧客配布物には含めない**）",
        f"- 対象: `[P]`（命題）要素 **{len(items)} 件** / 読む回答は **{len(groups)} 本**だけ",
        "- お願い: 各要素の `label:` の行に "
        "**`YES`（回答がその内容を述べている）** か **`NO`（述べていない・誤っている）** を書いてください。",
        "- 「その回答が良い回答か」ではなく、**その1点を述べているかどうか**だけを見てください。",
        "- 判断に迷うものは空欄のままで構いません（κ の計算から除外します）。",
        "- **このファイルに直接書いて構いません**（`- label: YES` / `- label: NO`）。"
        "隣の `*.labels.json` に `true`/`false` を入れてもよいです。",
        "- 記入後、次で κ を計算します:",
        "  `uv run scripts/complex-eval.py --phase calibrate --judge-model <model> "
        "<gen.json> --human-labels <labels.json>`",
        "",
        "---",
        "",
    ]
    labels = {}
    for gi, ((run, qid), rs) in enumerate(groups.items(), 1):
        lines += [
            f"## {gi}. {qid}（{rs[0]['category']} / run {run}） — 判定 {len(rs)} 件",
            "",
            f"**設問**: {rs[0]['question']}",
            "",
            "**回答（判定対象）**:",
            "",
            "```",
            rs[0]["answer"].strip(),
            "```",
            "",
        ]
        for r in rs:
            labels[r["key"]] = "SKIP"
            lines += [
                f"### `{r['key']}`",
                "",
                f"- 判定したい内容: **{r['claim']}**",
                f"- 原典の根拠: {r['reference']}",
                f"- judge の判定: **{r['verdict3']}**"
                f"（evidence: {(r['evidence'] or '')[:60]}）",
                "- label: ",
                "",
            ]
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    stub = os.path.splitext(path)[0] + ".labels.json"
    with open(stub, "w", encoding="utf-8") as f:
        json.dump({"note": "各キーに true/false を入れる。SKIP は書き換えない。",
                   "labels": labels}, f, ensure_ascii=False, indent=1)
    print(f"\n(人手ラベルシート → {path})")
    print(f"(記入用JSONの雛形 → {stub})")


# ==========================================================================
# phase: report （複数run集計・CI・McNemar）
# ==========================================================================

def wilson(k: int, n: int, z: float = 1.96) -> tuple[float, float]:
    if n == 0:
        return (0.0, 0.0)
    p = k / n
    d = 1 + z * z / n
    c = p + z * z / (2 * n)
    r = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))
    return ((c - r) / d, (c + r) / d)


def cluster_bootstrap(cases, iters=1000, seed=20260726) -> tuple[float, float]:
    """リサンプル単位を『設問』にしたブートストラップ95%CI（設計書 §7-2）。

    要素は設問内で相関する（同じ検索結果に依存する）ため、単純な二項CIは狭すぎる。
    """
    rnd = random.Random(seed)
    n = len(cases)
    if n == 0:
        return (0.0, 0.0)
    pts = []
    for _ in range(iters):
        s = [cases[rnd.randrange(n)] for _ in range(n)]
        r = sum(c["det_required"] for c in s)
        h = sum(c["det_hit"] for c in s)
        if r:
            pts.append(h / r)
    pts.sort()
    if not pts:
        return (0.0, 0.0)
    return (pts[int(0.025 * len(pts))], pts[min(len(pts) - 1, int(0.975 * len(pts)))])


def mcnemar(a_hits: list[bool], b_hits: list[bool]) -> tuple[int, int, float]:
    """対応ありの2条件の比較。b=01, c=10 の不一致ペアで二項検定（両側・厳密）。"""
    b = sum(1 for x, y in zip(a_hits, b_hits) if x and not y)
    c = sum(1 for x, y in zip(a_hits, b_hits) if y and not x)
    n = b + c
    if n == 0:
        return b, c, 1.0
    k = min(b, c)
    p = sum(math.comb(n, i) for i in range(0, k + 1)) / (2 ** n) * 2
    return b, c, min(1.0, p)


def _elementwise(runs) -> dict[str, list[bool]]:
    """要素ID(`Qxx/eY`) -> run ごとの判定。McNemar の要素単位用。"""
    d: dict[str, list[bool]] = {}
    for r in runs:
        for c in r["cases"]:
            for e in c["elements"]:
                if e["type"] in ("N", "E") and e["required"]:
                    d.setdefault(f"{c['id']}/{e['id']}", []).append(bool(e["verdict"]))
    return d


def phase_report(args) -> None:
    groups = {"A": [json.load(open(p, encoding="utf-8")) for p in args.files]}
    if args.compare:
        groups["B"] = [json.load(open(p, encoding="utf-8")) for p in args.compare]

    summary = {}
    for name, runs in groups.items():
        print(f"\n{'='*70}\n条件 {name}: {len(runs)} run"
              f"{'（★最低3run必要）' if len(runs) < 3 else ''}")
        rates, fulls = [], []
        for r in runs:
            cs = r["cases"]
            tr = sum(c["det_required"] for c in cs)
            th = sum(c["det_hit"] for c in cs)
            rates.append(th / tr if tr else 0.0)
            fulls.append(sum(1 for c in cs if c["full_correct"]))
        pooled = [c for r in runs for c in r["cases"]]
        lo, hi = cluster_bootstrap(pooled)
        n_q = len(runs[0]["cases"]) * len(runs)
        wlo, whi = wilson(sum(fulls), n_q)
        # 設計書 §7-2 の固定フォーマット
        print(f"  要素カバー率 {_mean(rates):.3f} [95%CI {lo:.3f}–{hi:.3f}]"
              f"（{len(runs)}run: {' / '.join(f'{x:.3f}' for x in rates)}）"
              f"  min={min(rates):.3f} max={max(rates):.3f}")
        print(f"  完全正答率 {sum(fulls)/n_q:.3f} [95%Wilson {wlo:.3f}–{whi:.3f}]"
              f"（各run: {fulls} / {len(runs[0]['cases'])}問）")
        halluc = sum(1 for c in pooled if c["hallucination"])
        print(f"  ハルシネーション率 {halluc/len(pooled):.3f}（{halluc}/{len(pooled)}）")
        print("  カテゴリ別要素カバー率:")
        for cat in CATS:
            sub = [c for c in pooled if c["category"] == cat]
            if not sub:
                continue
            r_ = sum(c["det_required"] for c in sub)
            h_ = sum(c["det_hit"] for c in sub)
            print(f"    {cat} {CAT_LABEL[cat]:<14}: {h_/r_:.3f} ({h_}/{r_})")
        summary[name] = {"rates": rates, "ci": (lo, hi), "runs": runs}

    if "B" not in summary:
        return

    print(f"\n{'='*70}\n=== A/B 判定（設計書 §7-3 の事前固定した判定則）===")
    ea, eb = _elementwise(summary["A"]["runs"]), _elementwise(summary["B"]["runs"])
    keys = sorted(set(ea) & set(eb))
    av = [any(ea[k]) for k in keys]
    bv = [any(eb[k]) for k in keys]
    b, c, p_el = mcnemar(av, bv)
    print(f"  McNemar(要素単位) b={b} c={c} p={p_el:.4f}  (n={len(keys)}要素)")
    qa = {c_["id"]: c_["full_correct"] for r in summary["A"]["runs"] for c_ in r["cases"]}
    qb = {c_["id"]: c_["full_correct"] for r in summary["B"]["runs"] for c_ in r["cases"]}
    qk = sorted(set(qa) & set(qb))
    b2, c2, p_q = mcnemar([qa[k] for k in qk], [qb[k] for k in qk])
    print(f"  McNemar(設問単位) b={b2} c={c2} p={p_q:.4f}  (n={len(qk)}問)")

    (alo, ahi), (blo, bhi) = summary["A"]["ci"], summary["B"]["ci"]
    ci_disjoint = ahi < blo or bhi < alo
    ra, rb = summary["A"]["rates"], summary["B"]["rates"]
    same_dir = (all(x < y for x, y in zip(ra, rb)) or all(x > y for x, y in zip(ra, rb))) \
        if len(ra) == len(rb) else False
    print(f"  (a) CIが重ならない      : {ci_disjoint}  A[{alo:.3f}–{ahi:.3f}] B[{blo:.3f}–{bhi:.3f}]")
    print(f"  (b) McNemar p<0.05      : {p_el < 0.05}")
    print(f"  (c) 3run全てで方向一致  : {same_dir}")
    if ci_disjoint and p_el < 0.05 and same_dir:
        print("  → **改善した（3条件すべて成立）**")
    else:
        print("  → **差は誤差範囲**（1条件でも欠けたらこう記載する。§7-3）")


# ==========================================================================

def main() -> int:
    ap = argparse.ArgumentParser(description="複雑質問20問の評価（Phase A）")
    ap.add_argument("--phase", required=True,
                    choices=["retrieval", "generate", "judge", "calibrate", "report",
                             "failmode"])
    ap.add_argument("--retrieval", default=None,
                    help="failmode: retrieval フェーズの出力JSON（必須）")
    ap.add_argument("--fixture", default=FIXTURE)
    ap.add_argument("--out", default=None)
    ap.add_argument("--in", dest="inp", default=None, help="judge の入力（generate の出力）")
    ap.add_argument("--run", default=None, help="generate の run 識別子")
    ap.add_argument("--top-n", type=int, default=None)
    ap.add_argument("--chat-model", default=None)
    ap.add_argument("files", nargs="*",
                    help="report: 条件Aの judge 出力JSON（複数run） / "
                         "calibrate: generate 出力JSON（複数可）")
    ap.add_argument("--compare", nargs="*", default=None,
                    help="report: 条件Bの judge 出力JSON（A/B比較）")
    # --- judge 層（S08）。**開発機専用。配布物には含めない** ---
    ap.add_argument("--judge-model", default=os.environ.get("JUDGE_MODEL") or None,
                    help="[P] 判定に使う judge モデル（例 qwen3:8b）。未指定なら [P] は未判定")
    ap.add_argument("--judge-url", default=JUDGE_URL,
                    help="評価専用 Ollama の URL（既定 %(default)s。製品の rag-ollama ではない）")
    ap.add_argument("--judge-seed", type=int,
                    default=int(os.environ.get("JUDGE_SEED", "20260726")))
    ap.add_argument("--judge-prompt", default="v1", choices=["v1", "v2"],
                    help="judge プロンプト版。既定 v1（採用モデル qwen3.5:4b では v1 のほうが "
                         "κ が高いことを実測。v2 は厳格化版で qwen3:8b 向け）")
    ap.add_argument("--judge-unload", action="store_true",
                    help="終了時に judge モデルを VRAM から降ろす")
    ap.add_argument("--partial-is-hit", action="store_true",
                    help="judge の PARTIAL を充足として数える（既定は不充足＝保守側）")
    ap.add_argument("--determinism", type=int, default=20,
                    help="calibrate: 決定性チェックで再判定する要素数（0で無効）")
    ap.add_argument("--calib-limit", type=int, default=0,
                    help="calibrate: 決定的要素の判定数を先頭N件に制限（動作確認用）")
    ap.add_argument("--emit-human-sheet", default=None,
                    help="calibrate: 人手ラベル用 Markdown シートの出力先")
    ap.add_argument("--human-labels", default=None,
                    help="calibrate: 記入済みの人手ラベル（.md シートでも .json でも可）。"
                         "judge vs 人手の κ を出す")
    args = ap.parse_args()

    if args.phase in ("retrieval", "generate") and not os.environ.get("HAKUSHO_SLUG"):
        print("エラー: HAKUSHO_SLUG が未設定です。", file=sys.stderr)
        return 2
    if args.phase == "retrieval":
        phase_retrieval(args)
    elif args.phase == "generate":
        phase_generate(args)
    elif args.phase == "judge":
        if not args.inp:
            print("エラー: --in が必要です。", file=sys.stderr)
            return 2
        phase_judge(args)
    elif args.phase == "calibrate":
        if not args.files:
            print("エラー: calibrate には generate 出力JSONを1つ以上渡してください。",
                  file=sys.stderr)
            return 2
        phase_calibrate(args)
    elif args.phase == "failmode":
        if not args.retrieval:
            print("エラー: failmode には --retrieval <retrieval出力JSON> が必要です。",
                  file=sys.stderr)
            return 2
        phase_failmode(args)
    else:
        if not args.files:
            print("エラー: report には judge 出力JSONを1つ以上渡してください。", file=sys.stderr)
            return 2
        phase_report(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
