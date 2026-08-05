#!/usr/bin/env python3
"""弱点の特定 — 検索と生成を突き合わせて 2x2 に分類する。

事前登録: docs/PREREG_WEAKNESS_2026-08-05.md（sha256 1fa4c7bb…）

なぜ 2x2 か
-----------
「検索が取れていない」ことと「回答が間違う」ことは別の弱点で、
切り分けないと直す場所を間違える。

    　　　　　　検索OK          検索NG
    回答OK  │ 問題なし      │ アンカー定義が過剰の疑い
    回答NG  │ 生成側の弱点  │ 検索側の弱点

弱点の定義（事前登録 §4。ここで動かさない）
    W1 決定的判定で不正解
    W2 同一カテゴリ内で3問以上に共通
    W3 検索側・生成側のどちらかに切り分けられている
"""
import json
import sys
from collections import defaultdict

RETR = "out/embswap/raw/retrieval-granite.json"   # 本日測定・同一ワークスペース
JUDGED = sys.argv[1] if len(sys.argv) > 1 else "out/weakness/judged-w1.json"

# 検索が「取れた」とみなす閾値。事前登録に明示していないので、
# 複数の閾値で出して恣意性を排す。
THRESHOLDS = [1.0, 0.5]


def load_retrieval():
    d = json.load(open(RETR, encoding="utf-8"))
    return {c["id"]: c for c in d["cases"]}


def load_judged():
    d = json.load(open(JUDGED, encoding="utf-8"))
    return d.get("cases", d) if isinstance(d, dict) else d


def element_verdicts(case):
    """要素ごとの判定を (確定した数, 正解数, 判定不能数) で返す。"""
    els = case.get("elements") or case.get("judged") or []
    ok = ng = unk = 0
    for e in els:
        v = e.get("verdict")
        if v is True:
            ok += 1
        elif v is False:
            ng += 1
        else:
            unk += 1
    return ok, ng, unk


def main():
    retr = load_retrieval()
    judged = load_judged()

    tot_unk = tot_el = 0
    for c in judged:
        ok, ng, unk = element_verdicts(c)
        tot_el += ok + ng + unk
        tot_unk += unk
    print(f"=== 判定の解像度 ===")
    print(f"  全要素 {tot_el} 件中、判定不能 [P]: {tot_unk} 件 "
          f"({100*tot_unk/tot_el:.0f}%)")
    if tot_el and tot_unk / tot_el > 0.30:
        print("  🔴 中止条件 C1 に該当（30%超）。決定的判定では弱点を特定できない。")

    for th in THRESHOLDS:
        print(f"\n=== 2x2（検索OK = anchor_coverage@8 >= {th}）===")
        cell = defaultdict(list)
        for c in judged:
            cid = c.get("id")
            r = retr.get(cid)
            if not r or not r.get("n_anchor"):
                continue
            cov = r["k"]["8"]["anchor_coverage"]
            ok, ng, unk = element_verdicts(c)
            if ok + ng == 0:
                continue          # 決定的に判定できる要素が無い設問は除外
            r_ok = cov >= th
            a_ok = ng == 0        # 1要素でも落とせば「回答NG」
            cell[(r_ok, a_ok)].append((cid, c.get("category"), ng))

        lab = {(True, True): "検索OK・回答OK  問題なし",
               (False, True): "検索NG・回答OK  アンカー定義が過剰の疑い",
               (True, False): "検索OK・回答NG  ★生成側の弱点",
               (False, False): "検索NG・回答NG  ★検索側の弱点"}
        for k in [(True, True), (False, True), (True, False), (False, False)]:
            v = cell[k]
            print(f"  {lab[k]:42s} {len(v):3d}問")

        # カテゴリ別の弱点候補（W2: 同一カテゴリ3問以上）
        print(f"  --- 弱点候補（同一カテゴリ3問以上）---")
        for k, name in [((True, False), "生成側"), ((False, False), "検索側")]:
            bycat = defaultdict(list)
            for cid, cat, ng in cell[k]:
                bycat[cat].append((cid, ng))
            for cat in sorted(bycat):
                items = bycat[cat]
                if len(items) >= 3:
                    els = sum(n for _, n in items)
                    ids = ", ".join(i for i, _ in items[:6])
                    print(f"    [{name}] {cat}: {len(items)}問 / 落とした要素 {els}個  ({ids}…)")


main()
