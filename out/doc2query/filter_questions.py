#!/usr/bin/env python3
"""索引時の仮想質問生成（Doc2Query--）— フィルタフェーズ。

事前登録: docs/PREREG_DOC2QUERY_2026-08-06.md（sha256 f4c519e2…）

🔴 これが Doc2Query-- の中核。一次調査
（docs/RESEARCH_INFERENCE_ABSTENTION_2026-07-28.md §A-5）が
「生成質問をそのまま全部入れると悪化する。フィルタ必須」と反証込みで記録している。

フィルタの定義（事前登録 §3 で確定。ここで変えない）:
  生成質問 q で検索し、**元チャンクが上位 k 件に入る質問だけ残す**。k=8（製品の topN と同じ）。

なぜこれで効くか: 「その質問で元チャンクを引けない」ということは、
その質問を索引に載せても引き当てには寄与せず、ノイズにしかならないため。
"""
import json
import subprocess
import sys
import time
import urllib.request

TOP_K = 8
SLUG = "emb-granite"
BASE = "http://localhost:3001"


def api_key() -> str:
    req = urllib.request.Request(
        BASE + "/api/system/generate-api-key",
        data=b'{"name":"d2qfilter"}',
        headers={"Content-Type": "application/json"}, method="POST")
    return json.load(urllib.request.urlopen(req, timeout=60))["apiKey"]["secret"]


def _nz(t: str) -> str:
    """照合用の正規化。空白を落として先頭120字で比較する。"""
    import re as _re
    t = _re.sub(r"^title:\s*none\s*\|\s*text:\s*", "", t or "")
    t = _re.sub(r"<document_metadata>.*?</document_metadata>", "", t, flags=_re.S)
    return _re.sub(r"\s+", "", t)[:120]


def search(key: str, q: str) -> list[str]:
    """質問で検索し、ヒットしたチャンクの**本文の正規化キー**を返す。

    🔴 vector-cache の id と vector-search が返す id は**別の空間**で、
    直接は突き合わせられない（2026-08-06 に実測して判明）。本文で照合する。
    """
    req = urllib.request.Request(
        f"{BASE}/api/v1/workspace/{SLUG}/vector-search",
        data=json.dumps({"query": q, "topN": TOP_K}).encode(),
        headers={"Content-Type": "application/json",
                 "Authorization": "Bearer " + key}, method="POST")
    try:
        r = json.load(urllib.request.urlopen(req, timeout=120))
    except Exception:
        return []
    return [_nz(x.get("text") or "") for x in (r.get("results") or [])]


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else "out/doc2query/questions.jsonl"
    dst = sys.argv[2] if len(sys.argv) > 2 else "out/doc2query/questions-filtered.jsonl"
    key = api_key()
    rows = [json.loads(l) for l in open(src, encoding="utf-8") if l.strip()]
    # 照合キー（本文の正規化）を vector-cache から引く
    import glob
    vc = glob.glob("runtime/anythingllm-storage/vector-cache/*.json")[0]
    keymap = {}
    for batch in json.load(open(vc, encoding="utf-8")):
        for it in batch:
            keymap[it["id"]] = _nz(it["metadata"].get("text") or "")
    for r in rows:
        r["key"] = keymap.get(r["id"], "")
    total = kept = 0
    t0 = time.time()
    with open(dst, "w", encoding="utf-8") as f:
        for i, r in enumerate(rows, 1):
            keep = []
            for q in r["questions"]:
                total += 1
                if r["key"] in search(key, q):
                    keep.append(q)
                    kept += 1
            # 索引側（lance/index.js の loadDoc2Query）は本文キーで引くので、
            # ここで最終形式（key + questions）にして出す。工程を分けると
            # 取り違えのもとになるため1本にまとめる。
            if keep and r["key"]:
                f.write(json.dumps({"key": r["key"], "questions": keep},
                                   ensure_ascii=False) + "\n")
            f.flush()
            if i % 100 == 0:
                el = time.time() - t0
                print(f"  {i}/{len(rows)}  残存 {kept}/{total} "
                      f"({100*kept/max(total,1):.0f}%)  経過 {el/60:.1f}分 "
                      f"残り推定 {el/i*(len(rows)-i)/60:.0f}分", flush=True)
    print(f"完了: {dst}", flush=True)
    print(f"  生成質問 {total} → 残存 {kept} ({100*kept/max(total,1):.1f}%)", flush=True)
    # 事前登録の中止条件 C3
    if total and kept / total < 0.05:
        print("  🔴 中止条件C3: 残存が5%未満。フィルタが厳しすぎる。定義を見直すこと",
              flush=True)


main()
