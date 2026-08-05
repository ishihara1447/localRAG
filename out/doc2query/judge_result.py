#!/usr/bin/env python3
"""経路B（索引時の仮想質問生成）の合否判定。

事前登録: docs/PREREG_DOC2QUERY_2026-08-06.md
  P1 カバー率が対照 +3pt 以上（0.676 以上）
  P2 真の捏造が 1件以下（絶対条件）
  P3 C6 の棄権が 13問以上
  P4 空回答ゼロ
  P5 B < C（条件B を省いたため**判定不能**。§10-1 に逸脱として記録済み）

🔴 基準はここで動かさない。結果を見てから閾値を変えない。
"""
import json
import re
from collections import defaultdict

CTRL = "out/xjudge/judged-topk8-fix2.json"      # 対照（TOPK=8・現行）
TEST = "out/doc2query/judged-d2q2.json"          # 条件C（仮想質問あり・フィルタあり）
GEN = "out/doc2query/gen-d2q2.json"

UNK = re.compile(r"見つかりません|見つかりませんでした|記載がありません|記載されていません"
                 r"|含まれていません|見当たりません|明示されていません|情報がない|ありません")


def agg(path):
    d = json.load(open(path, encoding="utf-8"))["cases"]
    tot = sum(c["det_hit"] for c in d)
    req = sum(c["det_required"] for c in d)
    hall = [c["id"] for c in d
            if any(e["type"] == "X" and e["verdict"] is True for e in c["elements"])]
    split = [c["id"] for c in d
             if any(e["type"] == "X" and e.get("x_confirm") == "split" for e in c["elements"])]
    cat = defaultdict(lambda: [0, 0])
    for c in d:
        cat[c["category"]][0] += c["det_hit"]
        cat[c["category"]][1] += c["det_required"]
    return tot / req, hall, split, {k: v[0] / v[1] for k, v in cat.items()}


def main():
    b, hb, _, gb = agg(CTRL)
    c, hc, sc, gc = agg(TEST)

    print("=== 経路B: 索引時の仮想質問生成（166問・修理後の判定器）===")
    print(f"  カバー率: {b:.4f} → {c:.4f}  ({100*(c-b):+.2f}pt)")
    print(f"  真の捏造: {len(hb)}件 {hb} → {len(hc)}件 {hc}")
    if sc:
        print(f"  判定が割れた（人手確認）: {sc}")

    print("\n  カテゴリ別:")
    for k in sorted(gb):
        print(f"    {k}: {gb[k]:.3f} → {gc[k]:.3f}  ({100*(gc[k]-gb[k]):+5.1f}pt)")

    # C6 の棄権と空回答
    gen = {x["id"]: x for x in json.load(open(GEN, encoding="utf-8"))["cases"]}
    d = json.load(open(TEST, encoding="utf-8"))["cases"]
    c6 = [x["id"] for x in d if x["category"] == "C6"]
    abst = [i for i in c6 if UNK.search(gen[i]["answer"] or "")]
    empty = [i for i in gen if not (gen[i]["answer"] or "").strip()]

    print("\n=== 合否（事前登録 §5。基準は動かさない）===")
    print(f"  P1 カバー率 +3pt 以上   : {'✅' if (c-b) >= 0.03 else '❌'}  ({100*(c-b):+.2f}pt)")
    print(f"  P2 真の捏造 1件以下     : {'✅' if len(hc) <= 1 else '❌'}  ({len(hc)}件)")
    print(f"  P3 C6 棄権 13問以上     : {'✅' if len(abst) >= 13 else '❌'}  ({len(abst)}/{len(c6)}問)")
    print(f"  P4 空回答ゼロ           : {'✅' if not empty else '❌'}  ({len(empty)}件)")
    print("  P5 B < C                : ⚪ 判定不能（条件Bを省いた。§10-1）")

    ok = (c - b) >= 0.03 and len(hc) <= 1 and len(abst) >= 13 and not empty
    print(f"\n  → {'採用候補（P1〜P4 合格）' if ok else '不採用（基準未達）'}")
    if not ok:
        print("     事前登録 §5「どれも満たさなければ現行を据え置き、経路B も打ち切る」")


main()
