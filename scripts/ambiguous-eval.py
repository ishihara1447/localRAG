# /// script
# requires-python = ">=3.10"
# dependencies = ["httpx>=0.27"]
# ///
"""防衛白書 曖昧質問 耐性評価（15問ペア: 明確版 vs 曖昧版）。

2026-07-18: 実ユーザーは年度・正式名称・限定条件を省いて曖昧に聞くため、
hakusho-eval.py の30問から15問を選び、正解キーワード（採点基準）は同一のまま
質問文だけを「実ユーザー風の曖昧な聞き方」に書き換えて精度実態を測る。

曖昧化タイプ（ambiguity_type）:
  omission       … 年度・限定条件の省略（「2025年度の防衛関係費(歳出額)は」→「防衛費っていくら？」）
  pronoun        … 指示語・通称（「統合作戦司令部」→「あの新しくできた司令部」）
  colloquial     … 口語・断片（「反撃能力とはどのような能力ですか」→「反撃能力って？」）
  underspecified … 過少指定（複数該当がありうる聞き方）
  typo           … 誤字・表記ゆれ

作法は hakusho-eval.py を踏襲: APIキー自動発行 → temperature=0 固定 →
/api/v1/workspace/{slug}/chat に {"message":q,"mode":"query"} → <think>除去 →
キーワード/正規表現採点（採点spec は hakusho-eval.py と同一）。
追加: sessionId を1問ごとに変えてチャット履歴の相互汚染を遮断する
（明確版の直後に曖昧版を聞くと履歴が文脈補完してしまう交絡の排除）。

環境変数: HAKUSHO_SLUG(必須), LOCALRAG_BASE_URL, AMB_OUT(結果JSON出力先)。
実行例:
  HAKUSHO_SLUG=<slug> AMB_OUT=/tmp/amb.json \
    ~/.local/bin/uv run --with httpx python3 scripts/ambiguous-eval.py
"""
import os, re, sys, json, time, uuid, httpx

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# S02: 正規化は scripts/_eval_common.py に集約（挙動は従来と同一）
from _eval_common import strip_think, squash_ws, is_unknown

BASE = os.environ.get("LOCALRAG_BASE_URL", "http://localhost:3001")
SLUG = os.environ.get("HAKUSHO_SLUG", "hakusho-eval")
OUT = os.environ.get("AMB_OUT", "")
TIMEOUT = 300.0

# 不明応答検出（hakusho-eval.py と同一。失敗モード「拒否」の判定にも使う）
# 2026-08-05: 棄権判定は _eval_common.is_unknown に一本化（欠陥2件の修正込み）。

# (orig_id, cat, clear_q, ambiguous_q, ambiguity_type, spec)
#   orig_id: hakusho-eval.py の CASES リスト内 1始まり番号
#   spec:    str=regex / ("kw",[...])=全キーワード含有（hakusho-eval.py と同一値）
CASES = [
    (1, "a",
     "防衛省・自衛隊に統合作戦司令部が新設されたのはいつですか。",
     "あの新しくできた司令部っていつ発足したんだっけ？",
     "pronoun", r"2025\s*年\s*3\s*月\s*24\s*日|令和7年3月24日"),
    (2, "a",
     "統合作戦司令部はどこに設置されましたか。",
     "統合作戦司令部ってどこ？",
     "colloquial", r"市ヶ谷"),
    (3, "a",
     "「自由で開かれたインド太平洋（FOIP）」は、いつ、誰が提唱した考え方ですか。",
     "インド太平洋のやつって、誰がいつ言い出したの？",
     "pronoun", r"(?=.*2016)(?=.*安倍)"),
    (4, "a",
     "国家安全保障戦略・国家防衛戦略・防衛力整備計画のいわゆる「三文書」が閣議で決定されたのはいつですか。",
     "三文書っていつ決まった？",
     "colloquial", r"(令和4年|2022\s*年)\s*12\s*月\s*16\s*日"),
    (6, "a",
     "2024年9月23日に日本領空を侵犯したロシア軍機に対し、航空自衛隊が初めて使用した警告手段は何ですか。",
     "ロシアの飛行機が入ってきたとき、初めて使った警告って何？",
     "omission", r"フレア"),
    (7, "a",
     "護衛艦「かが」が初めて艦上着艦に成功した戦闘機の機種は何ですか。",
     "かがに初めて降りた戦闘機って何？",
     "colloquial", r"F[-\s]?35\s*B"),
    (8, "a",
     "米国製のトマホークは何年度から取得を開始する予定ですか。",
     "トマホークっていつから買うの？",
     "colloquial", r"2025\s*年度"),
    (9, "b",
     "2025年度防衛関係費の歳出額（防衛力整備計画対象経費）はいくらですか。",
     "防衛費っていくら？",
     "omission", r"8\s*兆\s*4,?748\s*億|84,?748\s*億"),
    (11, "b",
     "中国が公表している2025年度の国防予算は、わが国の防衛関係費の約何倍に達していますか。",
     "中国の国防費って日本の何倍くらい？",
     "omission", r"約?\s*4\.4\s*倍"),
    (12, "b",
     "SIPRIによると、日本のGDPに占める防衛関係費の割合は何％となっていますか。",
     "防衛費ってGDPの何％？",
     "underspecified", r"1\.4\s*[%％]"),
    (14, "b",
     "現在運用中のXバンド防衛通信衛星「きらめき2号」は、何年度に運用を終了する予定ですか。",
     "きらめき2合っていつまで使えるの？",  # 号→合 の誤字
     "typo", r"2030\s*年度"),
    (15, "c",
     "「専守防衛」とはどのような姿勢のことですか。",
     "専守防衛って？",
     "colloquial", ("kw", ["武力攻撃を受けた", "必要最小限", "受動的"])),
    (16, "c",
     "「非核三原則」とは何ですか。",
     "非核三原速って何だっけ？",  # 則→速 の誤字
     "typo", ("kw", ["持たず", "作らず", "持ち込ませず"])),
    (17, "c",
     "白書のいう「反撃能力」とはどのような能力ですか。",
     "反撃能力って？",
     "colloquial", ("kw", ["三要件", "相手の領域", "スタンド", "必要最小限"])),
    (30, "e",
     "陸・海・空自の主要部隊を平常時からひとまとめに指揮するトップの役職名は何ですか。",
     "部隊をまとめて指揮するトップって何て役職？",
     "underspecified", r"統合作戦司令官"),
]


def newkey(c):
    return c.post(f"{BASE}/api/system/generate-api-key",
                  json={"name": "amb-eval"}).json()["apiKey"]["secret"]


def ask(c, h, q, session):
    r = c.post(f"{BASE}/api/v1/workspace/{SLUG}/chat", headers=h,
               json={"message": q, "mode": "query", "sessionId": session},
               timeout=TIMEOUT)
    r.raise_for_status()
    d = r.json()
    return strip_think(d.get("textResponse", "") or "")


def grade(ans, spec):
    if isinstance(spec, tuple):
        a = squash_ws(ans)  # PDF由来の字間空白を吸収（hakusho-eval同様）
        return all(squash_ws(k) in a for k in spec[1])
    return bool(re.search(spec, ans))


def failure_mode(ans, spec):
    """曖昧版が不正解だったときの失敗モード自動分類（レポートで目視確認前提の一次分類）。
    refusal=拒否(不明系応答) / partial=部分回答(kw specの一部のみ含有) / wrong=誤答"""
    if is_unknown(ans):
        return "refusal"
    if isinstance(spec, tuple):
        a = squash_ws(ans)
        hit = sum(1 for k in spec[1] if squash_ws(k) in a)
        if 0 < hit < len(spec[1]):
            return f"partial({hit}/{len(spec[1])})"
    return "wrong"


def main():
    results = []
    with httpx.Client() as c:
        h = {"Authorization": f"Bearer {newkey(c)}"}
        c.post(f"{BASE}/api/v1/workspace/{SLUG}/update", headers=h,
               json={"openAiTemp": 0})
        print("(temperature=0, mode=query, sessionId per question)")
        run = uuid.uuid4().hex[:8]
        for oid, cat, clear_q, amb_q, atype, spec in CASES:
            row = {"orig_id": oid, "cat": cat, "ambiguity_type": atype,
                   "clear_q": clear_q, "amb_q": amb_q}
            for variant, q in (("clear", clear_q), ("amb", amb_q)):
                t0 = time.time()
                ans = ask(c, h, q, f"amb-eval-{run}-{oid}-{variant}")
                ok = grade(ans, spec)
                row[variant] = {"ok": ok, "answer": ans,
                                "sec": round(time.time() - t0, 1)}
                tag = "OK" if ok else "NG"
                print(f"[{tag}] Q{oid:02d} {variant:5s} ({atype}) {q[:30]}…"
                      f" ({row[variant]['sec']}s)")
            if not row["amb"]["ok"]:
                row["amb"]["failure_mode"] = failure_mode(row["amb"]["answer"], spec)
                print(f"      amb失敗モード={row['amb']['failure_mode']}"
                      f" → {row['amb']['answer'][:150]}")
            results.append(row)

    # ---- 集計 ----
    print("\n=== 対比表（明確版 vs 曖昧版） ===")
    print(f"{'Q':>3} {'type':<14} {'clear':<5} {'amb':<5} diff")
    co = ao = 0
    for r in results:
        cok, aok = r["clear"]["ok"], r["amb"]["ok"]
        co += cok; ao += aok
        diff = "=" if cok == aok else ("↓ 劣化" if cok else "↑ 逆転")
        print(f"Q{r['orig_id']:02d} {r['ambiguity_type']:<14}"
              f" {'OK' if cok else 'NG':<5} {'OK' if aok else 'NG':<5} {diff}")
    print(f"合計: 明確版 {co}/{len(results)} / 曖昧版 {ao}/{len(results)}")

    print("\n=== ambiguity_type 別正答率（曖昧版） ===")
    by = {}
    for r in results:
        t = r["ambiguity_type"]
        by.setdefault(t, [0, 0])
        by[t][1] += 1
        by[t][0] += r["amb"]["ok"]
    for t, (o, n) in sorted(by.items()):
        print(f"  {t:<14}: {o}/{n}")

    print("\n=== 曖昧版の失敗モード内訳 ===")
    fm = {}
    for r in results:
        if not r["amb"]["ok"]:
            m = r["amb"].get("failure_mode", "?").split("(")[0]
            fm.setdefault(m, []).append(r["orig_id"])
    for m, ids in sorted(fm.items()):
        print(f"  {m}: {len(ids)}件 (Q{', Q'.join(map(str, ids))})")

    if OUT:
        with open(OUT, "w", encoding="utf-8") as f:
            json.dump(results, f, ensure_ascii=False, indent=1)
        print(f"\n(結果JSON → {OUT})")


main()
