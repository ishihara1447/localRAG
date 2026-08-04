# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""topN=8 vs topN=4 の A/B 解析。

事前登録: docs/TOPN4_EVAL_2026-08-04.md §2-4 / §2-5
scripts/ と fixtures/ は一切変更しない（本ファイルは新規の解析専用スクリプト）。

出す数字:
  1. 条件ごとの要素カバー率（run別・3run平均）と設問単位クラスタブートストラップCI
  2. ★ペア差 A-B の点推定と95%CI（設問単位クラスタブートストラップ / seed=20260804 / 10,000回）
  3. McNemar（要素単位）— 対応runペア3組 ＋ any()集約
  4. 完全正答率（Wilson CI）＋ 設問単位 McNemar
  5. カテゴリ別 C1..C6（n併記）
  6. ハルシネーション / 棄権 / 過剰拒否 / 空回答 / 回答長
"""
import json
import math
import random
import re
import sys
from collections import defaultdict

CATS = ("C1", "C2", "C3", "C4", "C5", "C6")
CAT_LABEL = {"C1": "集約・構成", "C2": "マルチホップ", "C3": "比較",
             "C4": "要約", "C5": "推論・含意", "C6": "unanswerable"}

# 事前登録 §2-5: 棄権検出は scripts/hakusho-eval.py の UNKNOWN 正規表現をそのまま使う
# （凍結ファイル / sha256 fbfaf52f... を §5 に記録）。既知欠陥 c04/c05 を含むため
# **絶対値は使わず A と B の差だけを見る**。
UNKNOWN = re.compile(
    r"不明|見つかり|ありません|情報がない"
    r"|含まれていない|含まれていません|含まれておりません"
    r"|記載がない|記載されていない|記載されていません"
    r"|わかりません|お答えでき|存在しません"
)

BOOT_ITERS = 10000
BOOT_SEED = 20260804


def wilson(k, n, z=1.96):
    if n == 0:
        return (0.0, 0.0)
    p = k / n
    d = 1 + z * z / n
    c = p + z * z / (2 * n)
    r = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))
    return ((c - r) / d, (c + r) / d)


def mcnemar(a_hits, b_hits):
    """scripts/complex-eval.py の mcnemar() と同一（両側・厳密二項）。"""
    b = sum(1 for x, y in zip(a_hits, b_hits) if x and not y)
    c = sum(1 for x, y in zip(a_hits, b_hits) if y and not x)
    n = b + c
    if n == 0:
        return b, c, 1.0
    k = min(b, c)
    p = sum(math.comb(n, i) for i in range(0, k + 1)) / (2 ** n) * 2
    return b, c, min(1.0, p)


def cluster_bootstrap_single(per_q, iters=1000, seed=20260726):
    """条件単独のCI。scripts/complex-eval.py の cluster_bootstrap() と同じ規則
    （リサンプル単位=設問・1,000回・seed=20260726）。per_q: [(req, hit), ...]"""
    rnd = random.Random(seed)
    n = len(per_q)
    pts = []
    for _ in range(iters):
        s = [per_q[rnd.randrange(n)] for _ in range(n)]
        r = sum(x[0] for x in s)
        h = sum(x[1] for x in s)
        if r:
            pts.append(h / r)
    pts.sort()
    return (pts[int(0.025 * len(pts))], pts[min(len(pts) - 1, int(0.975 * len(pts)))])


def paired_cluster_bootstrap(qids, req3, hitA, hitB, iters=BOOT_ITERS, seed=BOOT_SEED):
    """★事前登録 §2-4-2: ペア差 A-B の95%CI。リサンプル単位=設問。"""
    rnd = random.Random(seed)
    n = len(qids)
    pts = []
    for _ in range(iters):
        idx = [rnd.randrange(n) for _ in range(n)]
        R = sum(req3[qids[i]] for i in idx)
        if not R:
            continue
        a = sum(hitA[qids[i]] for i in idx) / R
        b = sum(hitB[qids[i]] for i in idx) / R
        pts.append(a - b)
    pts.sort()
    lo = pts[int(0.025 * len(pts))]
    hi = pts[min(len(pts) - 1, int(0.975 * len(pts)))]
    return lo, hi, pts


def load(paths):
    return [json.load(open(p, encoding="utf-8")) for p in paths]


def elementwise(runs):
    d = defaultdict(list)
    for r in runs:
        for c in r["cases"]:
            for e in c["elements"]:
                if e["type"] in ("N", "E") and e["required"]:
                    d[f"{c['id']}/{e['id']}"].append(bool(e["verdict"]))
    return d


def summarize(name, judged, gens):
    print(f"\n{'='*74}\n条件 {name}: judged {len(judged)} run / gen {len(gens)} run")
    rates, fulls, halluc, absten, empty, lens = [], [], [], [], [], []
    for jr in judged:
        cs = jr["cases"]
        tr = sum(c["det_required"] for c in cs)
        th = sum(c["det_hit"] for c in cs)
        rates.append(th / tr)
        fulls.append(sum(1 for c in cs if c["full_correct"]))
        halluc.append(sum(1 for c in cs if c["hallucination"]))
    for gr in gens:
        ans = [c["answer"] for c in gr["cases"]]
        absten.append(sum(1 for a in ans if UNKNOWN.search(a)))
        empty.append(sum(1 for a in ans if len(a.strip()) == 0))
        lens.append(sorted(len(a) for a in ans)[len(ans) // 2])
    per_q = [(c["det_required"], c["det_hit"]) for jr in judged for c in jr["cases"]]
    lo, hi = cluster_bootstrap_single(per_q)
    nq = len(judged[0]["cases"]) * len(judged)
    wlo, whi = wilson(sum(fulls), nq)
    print(f"  要素カバー率 {sum(rates)/len(rates):.4f} [95%CI {lo:.4f}–{hi:.4f}]"
          f"（run別: {' / '.join(f'{x:.4f}' for x in rates)}）")
    print(f"  生の値: {[f'{h}/{r}' for r,h in [(sum(c['det_required'] for c in jr['cases']), sum(c['det_hit'] for c in jr['cases'])) for jr in judged]]}")
    print(f"  完全正答率 {sum(fulls)/nq:.4f} [95%Wilson {wlo:.4f}–{whi:.4f}]（run別: {fulls} / {len(judged[0]['cases'])}問）")
    print(f"  ハルシネーション([X]発火問数) run別: {halluc}")
    print(f"  棄権(緩い定義・UNKNOWN一致問数) run別: {absten}   ※絶対値は使わない")
    print(f"  空回答 run別: {empty}   回答長中央値 run別: {lens}")
    print("  カテゴリ別要素カバー率（3runプール）:")
    catrows = {}
    for cat in CATS:
        sub = [c for jr in judged for c in jr["cases"] if c["category"] == cat]
        r = sum(c["det_required"] for c in sub)
        h = sum(c["det_hit"] for c in sub)
        nq_ = len(sub) // len(judged)
        catrows[cat] = (h, r, h / r, nq_)
        print(f"    {cat} {CAT_LABEL[cat]:<14}: {h/r:.4f} ({h}/{r})  n={nq_}問")
    return {"rates": rates, "ci": (lo, hi), "fulls": fulls, "halluc": halluc,
            "absten": absten, "empty": empty, "cats": catrows, "judged": judged, "gens": gens}


def over_refusal(judged, gens):
    """事前登録 §2-5: C6以外で「棄権に一致 かつ det_coverage==0」を 3run中2run以上で満たす設問。"""
    votes = defaultdict(int)
    cat = {}
    for jr, gr in zip(judged, gens):
        cov = {c["id"]: c["det_coverage"] for c in jr["cases"]}
        for c in gr["cases"]:
            cat[c["id"]] = c["category"]
            if c["category"] == "C6":
                continue
            if UNKNOWN.search(c["answer"]) and (cov.get(c["id"]) == 0.0):
                votes[c["id"]] += 1
    return sorted(q for q, v in votes.items() if v >= 2)


def main():
    A_j = load([f"out/topn4/topn8-judged-run{r}.json" for r in (1, 2, 3)])
    B_j = load([f"out/topn4/topn4-judged-run{r}.json" for r in (1, 2, 3)])
    A_g = load([f"out/topn4/topn8-gen-run{r}.json" for r in (1, 2, 3)])
    B_g = load([f"out/topn4/topn4-gen-run{r}.json" for r in (1, 2, 3)])

    A = summarize("A (topN=8)", A_j, A_g)
    B = summarize("B (topN=4)", B_j, B_g)

    print(f"\n{'='*74}\n=== 1. ペア差 A-B（★主判定。事前登録 §2-4-2）===")
    qids = [c["id"] for c in A_j[0]["cases"]]
    req3, hitA, hitB = {}, defaultdict(int), defaultdict(int)
    for c in A_j[0]["cases"]:
        req3[c["id"]] = c["det_required"] * 3
    for jr in A_j:
        for c in jr["cases"]:
            hitA[c["id"]] += c["det_hit"]
    for jr in B_j:
        for c in jr["cases"]:
            hitB[c["id"]] += c["det_hit"]
    R = sum(req3.values())
    dpoint = sum(hitA.values()) / R - sum(hitB.values()) / R
    lo, hi, pts = paired_cluster_bootstrap(qids, req3, hitA, hitB)
    print(f"  劣化(A-B) 点推定 = {dpoint*100:+.2f}pt")
    print(f"  95%CI（設問単位クラスタブートストラップ, {BOOT_ITERS}回, seed={BOOT_SEED}） "
          f"= [{lo*100:+.2f}pt, {hi*100:+.2f}pt]")
    print(f"  ブートストラップ分布が 0 を跨ぐか: {'YES（0を含む）' if lo <= 0 <= hi else 'NO（0を含まない）'}")
    print(f"  P(δ>0)（＝topN=8 の方が良い割合） = {sum(1 for x in pts if x>0)/len(pts):.4f}")

    print(f"\n=== 2. run別のペア差 ===")
    for i in range(3):
        ra = sum(c["det_hit"] for c in A_j[i]["cases"]) / sum(c["det_required"] for c in A_j[i]["cases"])
        rb = sum(c["det_hit"] for c in B_j[i]["cases"]) / sum(c["det_required"] for c in B_j[i]["cases"])
        print(f"  run{i+1}: A={ra:.4f} B={rb:.4f}  差={(ra-rb)*100:+.2f}pt")

    print(f"\n=== 3. McNemar（要素単位）===")
    ea, eb = elementwise(A_j), elementwise(B_j)
    keys = sorted(set(ea) & set(eb))
    print(f"  対応runペア（★主。事前登録 §2-4-1）:")
    sig = []
    for i in range(3):
        av = [ea[k][i] for k in keys]
        bv = [eb[k][i] for k in keys]
        b, c, p = mcnemar(av, bv)
        sig.append(p < 0.05)
        print(f"    A_run{i+1} vs B_run{i+1}: b={b} c={c} p={p:.6g}  (n={len(keys)}要素)")
    print(f"    → 3組すべてで p<0.05 か: {all(sig)}")
    av = [any(ea[k]) for k in keys]
    bv = [any(eb[k]) for k in keys]
    b, c, p_any = mcnemar(av, bv)
    print(f"  any()集約（ハーネス既定・併記）: b={b} c={c} p={p_any:.6g} (n={len(keys)}要素)")

    print(f"\n=== 4. McNemar（設問単位・完全正答）===")
    for i in range(3):
        qa = {c["id"]: c["full_correct"] for c in A_j[i]["cases"]}
        qb = {c["id"]: c["full_correct"] for c in B_j[i]["cases"]}
        ks = sorted(set(qa) & set(qb))
        b, c, p = mcnemar([qa[k] for k in ks], [qb[k] for k in ks])
        print(f"    run{i+1}: b={b} c={c} p={p:.6g} (n={len(ks)}問)")

    print(f"\n=== 5. カテゴリ別の差（診断のみ。単独で採否を決めない）===")
    print(f"  {'cat':<4} {'n問':>4} {'要素/3run':>10} {'A':>8} {'B':>8} {'差(pt)':>9}")
    for cat in CATS:
        ha, ra, pa, nq = A["cats"][cat]
        hb, rb, pb, _ = B["cats"][cat]
        print(f"  {cat:<4} {nq:>4} {ra:>10} {pa:>8.4f} {pb:>8.4f} {(pa-pb)*100:>+9.2f}")

    print(f"\n=== 6. 安全側（S1〜S4）===")
    print(f"  S1 ハルシネーション: A={A['halluc']} B={B['halluc']}  増加={sum(B['halluc'])>sum(A['halluc'])}")
    ora, orb = over_refusal(A_j, A_g), over_refusal(B_j, B_g)
    print(f"  S2 過剰拒否(C6以外・棄権かつ要素0・3run中2run以上): A={len(ora)}問 B={len(orb)}問  差={len(orb)-len(ora):+d}")
    print(f"     A: {ora}")
    print(f"     B: {orb}")
    print(f"     Bのみ(新規に過剰拒否になった設問): {sorted(set(orb)-set(ora))}")
    print(f"  S3 C6: A={A['cats']['C6'][2]:.4f} B={B['cats']['C6'][2]:.4f} 差={(A['cats']['C6'][2]-B['cats']['C6'][2])*100:+.2f}pt")
    worst = max(CATS, key=lambda c: A["cats"][c][2] - B["cats"][c][2])
    print(f"  S4 最大低下カテゴリ: {worst} {(A['cats'][worst][2]-B['cats'][worst][2])*100:+.2f}pt")

    print(f"\n=== 7. 判定則 S07 (a)(b)(c) ===")
    (alo, ahi), (blo, bhi) = A["ci"], B["ci"]
    ci_disjoint = ahi < blo or bhi < alo
    same_dir = all(x > y for x, y in zip(A["rates"], B["rates"])) or \
               all(x < y for x, y in zip(A["rates"], B["rates"]))
    print(f"  (a) CIが重ならない : {ci_disjoint}  A[{alo:.4f}–{ahi:.4f}] B[{blo:.4f}–{bhi:.4f}]")
    print(f"  (b) McNemar p<0.05 (any集約): {p_any < 0.05}  (p={p_any:.6g})")
    print(f"  (c) 3run全てで方向一致: {same_dir}")

    print(f"\n=== 8. ハルシネーション発火の内訳 ===")
    for nm, jl in (("A", A_j), ("B", B_j)):
        s = defaultdict(int)
        for jr in jl:
            for c in jr["cases"]:
                if c["hallucination"]:
                    s[c["id"]] += 1
        print(f"  {nm}: {dict(sorted(s.items()))}")


if __name__ == "__main__":
    sys.exit(main())
