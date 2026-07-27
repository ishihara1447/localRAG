"""評価スクリプト共通の正規化処理（品質ロードマップ Phase A / S02）。

なぜ必要か
----------
採点用の文字列比較のバグ（PDF由来の字間空白を吸収し忘れる等）が過去2回発生し、
「生スコアを見て手動補正する」運用が常態化した（`docs/RAG_EVAL_INTERNAL_AUDIT_2026-07-16.md` §1-1/§1-2）。
正規化を1箇所に集約しないと、新設する complex-eval で3度目を踏む。
本モジュールは hakusho-eval / ambiguous-eval / scale-eval / complex-eval の4本で共用する。

**互換性の約束（重要）**
`strip_think()` と `squash_ws()` は、既存3スクリプトが持っていた実装と
**文字単位で同一の挙動**である。既存のベースライン（防衛白書28〜29/30 等）を
動かさないため、既存3スクリプトはこの2つだけを使う。
`normalize()` 以下の強い正規化（全半角・数値表記ゆれ・和暦）は complex-eval 用の
Layer 0 であり、**既存3スクリプトの採点には適用しない**
（`COMPLEX_QA_EVAL_SET_DESIGN_2026-07-26.md` §8-4「本セットの実装が安定するまで既存3本には手を入れない」）。

**2026-07-26 の修正: 数値一致に桁境界チェックを入れた**
`normalize()` は空白を全除去するため、`約270000円` の内部に `70000円` が、
`約1710000円` の内部に `17100` が部分一致し、決定的採点で偽陽性を2件出していた
（`docs/JUDGE_MODEL_CALIBRATION_2026-07-26.md` §4-3）。
`contains()` / `contains_marked()` / `find_bounded()` は
**needle の端が数字のとき、その隣が同じ数値の桁の続きなら一致と見なさない**。
一方で「空白で区切られていた別々の数値が正規化で連結する」ケース
（白書の図表行 `合計1,468 2,311 … 1,422`）は従来どおり一致させる必要があるため、
除去した空白の跡を番兵として保持する `normalize_marked()` を導入した。
**`normalize()` の返り値そのものは変わっていない**（実データ全件で旧実装と一致を確認）。

依存なし（標準ライブラリのみ）。`python3 scripts/_eval_common.py` で自己テストが走る。
"""

from __future__ import annotations

import re

# --------------------------------------------------------------------------
# 既存3スクリプト互換の最小正規化（挙動を変えてはならない）
# --------------------------------------------------------------------------

_THINK = re.compile(r"<think>.*?</think>", re.DOTALL)
_WS = re.compile(r"\s+")


def strip_think(text: str) -> str:
    """推論モデルの <think>...</think> ブロックを判定対象から除去する。

    既存3スクリプトの実装と同一（`re.sub(..., flags=re.DOTALL).strip()`）。
    """
    return _THINK.sub("", text or "").strip()


def squash_ws(text: str) -> str:
    """空白（半角・全角・改行）を全除去する。

    既存の `re.sub(r"\\s+", "", ans)` と同一。Python3 の `\\s` は Unicode 空白を
    含むため全角スペース U+3000 もここで消える。PDF由来の字間空白
    （「持ち込ま せず」等）を吸収するのが目的。
    """
    return _WS.sub("", text or "")


# --------------------------------------------------------------------------
# Layer 0: complex-eval 用の強い正規化
# --------------------------------------------------------------------------

# 全角ASCII（U+FF01–U+FF5E）→ 半角。Ⅰ/Ⅱ/Ⅲ（U+2160–）は変換しない
# （「第Ⅰ部」を「第I部」に潰すと白書の表記と乖離するため。異表記は alias で扱う）。
_FULLWIDTH = {c: c - 0xFEE0 for c in range(0xFF01, 0xFF5F)}
_FULLWIDTH.update({
    ord("％"): ord("%"),
    ord("　"): ord(" "),
    ord("〜"): ord("~"),
    ord("－"): ord("-"),
    ord("―"): ord("-"),
    ord("−"): ord("-"),
    ord("ー"): ord("ー"),  # 長音は保持（変換しない）
})

# 和暦→西暦。白書に出るのは令和・平成が中心。元年も扱う。
_ERA_BASE = {"令和": 2018, "平成": 1988, "昭和": 1925}
_ERA = re.compile(r"(令和|平成|昭和)\s*(\d+|元)\s*年")

_UNIT = {"兆": 10 ** 12, "億": 10 ** 8, "万": 10 ** 4}
# 「8兆4,748億」「9.9兆」「1万2,300」のような漢数単位つき数値表現
_MYRIAD = re.compile(r"(?:\d+(?:\.\d+)?[兆億万])+\d*")
_COMMA_NUM = re.compile(r"(?<=\d),(?=\d{3}(?!\d))")

# --- 桁境界の判定に使う内部マーカー（2026-07-26 追加）------------------------
# `squash_ws` で消える空白の「跡」を残すための番兵。**正規化の最終出力からは必ず
# 取り除く**ので、`normalize()` の返り値は従来と1文字も変わらない（§下の _selftest
# と docs/EVAL_HARNESS_FIXES_2026-07-26.md の実測比較で確認済み）。
_SEP = "\x00"
_DIGITS = "0123456789"
# 数値の途中に現れうる区切り（小数点・3桁区切りでなく残ったカンマ）
_NUM_CONT = ".,"

# 番兵をまたいでも漢数単位を展開できるようにした版。
# 数字の内部にも空白が入りうる（PDFの字間空白「84 748億」）ため、桁の間にも番兵を許す。
_D_M = r"\d(?:\x00*\d)*"
_NUM_M = rf"{_D_M}(?:\x00*\.\x00*{_D_M})?"
_MYRIAD_MARKED = re.compile(rf"(?:{_NUM_M}\x00*[兆億万]\x00*)+(?:{_D_M})?")


def to_halfwidth(text: str) -> str:
    """全角ASCII・％を半角化する（Ⅰ/Ⅱ等のローマ数字は保持）。"""
    return (text or "").translate(_FULLWIDTH)


def wareki_to_seireki(text: str) -> str:
    """`令和7年` → `2025年` のように和暦を西暦へ揃える。"""
    def rep(m: re.Match) -> str:
        era, num = m.group(1), m.group(2)
        n = 1 if num == "元" else int(num)
        return f"{_ERA_BASE[era] + n}年"
    return _ERA.sub(rep, text or "")


def strip_number_commas(text: str) -> str:
    """`84,748` → `84748`。3桁区切りのカンマだけを消す。"""
    return _COMMA_NUM.sub("", text or "")


def expand_myriad(text: str) -> str:
    """漢数単位つき数値を素の整数へ展開する。

    `8兆4748億` / `84748億` / `9.9兆` を同一の整数表現に落とすためのもの。
    表記ゆれ（`8兆4,748億円` ≡ `84,748億円`）を substring 一致で扱えるようにする。
    小数が残る場合（例: `1.05兆` ではなく `1.5万`）も整数にできる限り展開する。
    """
    return _MYRIAD.sub(_myriad_rep, text or "")


def _myriad_rep(m: re.Match) -> str:
    s = m.group(0).replace(_SEP, "")  # 番兵は数値の外にも内にも入りうるので先に落とす
    total = 0.0
    for num, unit in re.findall(r"(\d+(?:\.\d+)?)([兆億万])?", s):
        if not num:
            continue
        total += float(num) * (_UNIT[unit] if unit else 1)
    return str(int(total)) if total == int(total) else str(total)


def normalize_marked(text: str) -> str:
    """`normalize()` と同じ変換を、**空白の跡を番兵 `\\x00` として残したまま**行う。

    なぜ必要か（2026-07-26 の修正）
    ------------------------------
    `normalize()` は空白を全除去するため、**別々の数値が桁として連結する**。
    白書の図表行 `合計1,468 2,311 2,122 1,707 1,422` は `14682311212217071422` になり、
    ここで `1,422` を素の部分一致で探すと当たる（これは意図した挙動で、既存の回帰テスト）。
    一方で `約270000円` の中の `70000円`、`約1710000円` の中の `17100` のように
    **1つの数値の桁の途中**に当たってしまうのは誤判定である
    （実際に S06 の決定的採点で2件の偽陽性を出していた。
    docs/JUDGE_MODEL_CALIBRATION_2026-07-26.md §4-3）。

    両者を区別できる情報は「そこに空白があったか」だけなので、空白を消さずに
    番兵へ置き換えた文字列を保持する。`find_bounded()` がこれを見て桁境界を判定する。
    番兵を除けば `normalize()` と完全に同一の文字列になる（`normalize()` 自身が
    この関数から番兵を落として作られている）。
    """
    t = (text or "").replace(_SEP, "")  # 入力に番兵が紛れ込んでいたら落とす（実データでは0件）
    t = strip_think(t)
    t = to_halfwidth(t)
    t = wareki_to_seireki(t)
    t = strip_number_commas(t)
    t = _WS.sub(_SEP, t)          # ← squash_ws の代わり。空白は「消す」のでなく「印にする」
    t = _MYRIAD_MARKED.sub(_myriad_rep, t)
    return t


def normalize(text: str) -> str:
    """complex-eval の Layer 0 正規化。

    順序: <think>除去 → 全半角統一 → 和暦→西暦 → 数値カンマ除去
          → 空白全除去 → 漢数単位の展開

    **カンマ除去は空白除去より先に行わなければならない**。
    先に空白を消すと、白書の図表のように数値が並ぶ行
    （`合計1,468 2,311 2,122 1,707 1,422`）で桁が連結してしまい、
    3桁区切りカンマの判定（`,` の直後がちょうど3桁）が成立しなくなる。
    実際に図表Ⅳ-3-4-2（印字452）で `1,422` が一致しない不具合として観測した。

    この関数を通した文字列どうしを比較する限り、
    `8兆4,748億円` ≡ `84,748億円` ≡ `8兆4748億円` は同一になる。

    実装は `normalize_marked()` から番兵を落とすだけ。**返り値は 2026-07-26 の
    桁境界修正の前後で1文字も変わらない**（両実装を実データ全件に当てて確認済み）。
    """
    return normalize_marked(text).replace(_SEP, "")


# --------------------------------------------------------------------------
# 桁境界つきの部分一致（2026-07-26 追加）
# --------------------------------------------------------------------------

def _clean_and_map(marked: str) -> tuple[str, list[int]]:
    """番兵入り文字列 → (番兵を除いた文字列, 各文字の元インデックス)。"""
    chars: list[str] = []
    idx: list[int] = []
    for i, ch in enumerate(marked):
        if ch != _SEP:
            chars.append(ch)
            idx.append(i)
    return "".join(chars), idx


def _continues_left(marked: str, s: int) -> bool:
    """`marked[s]` の直前が、同じ数値の桁の続きか。"""
    i = s - 1
    if i < 0:
        return False
    ch = marked[i]
    if ch == _SEP:      # 空白で切れていた ＝ 別の数値
        return False
    if ch in _DIGITS:
        return True
    if ch in _NUM_CONT:  # `.` や（3桁区切りでなく残った）`,` の手前が数字なら同じ数値
        return i - 1 >= 0 and marked[i - 1] in _DIGITS
    return False


def _continues_right(marked: str, e: int) -> bool:
    """`marked[e-1]` の直後が、同じ数値の桁の続きか。"""
    if e >= len(marked):
        return False
    ch = marked[e]
    if ch == _SEP:
        return False
    if ch in _DIGITS:
        return True
    if ch in _NUM_CONT:
        return e + 1 < len(marked) and marked[e + 1] in _DIGITS
    return False


def iter_bounded(marked_haystack: str, needle_normalized: str):
    """番兵入り haystack 中の needle の出現位置を、**桁境界つきで**先頭から順に返す。

    採らない条件（needle 側が数字で終始する端についてのみ判定する）:

    - needle が数字で始まり、その直前が（空白を挟まずに）数字・`数字.`・`数字,` である
    - needle が数字で終わり、その直後が（空白を挟まずに）数字・`.数字`・`,数字` である

    例:
      `約270000円` に対する `70000円`  → 直前が `2` なので不一致（桁の途中）
      `約1710000円` に対する `17100`   → 直後が `0` なので不一致（桁の途中）
      `1,707 1,422` に対する `1,422`   → 直前は空白（番兵）なので**一致**（別の数値）

    yield するのは番兵を除いた文字列上のインデックス。
    2026-07-27 追加: 排他語（`match.not_part_of`）の判定で「1つ目の一致が排他語の内側
    だったとき、2つ目以降の一致を見に行く」必要が出たため、`find_bounded()` の
    ループ本体をここに切り出した。`find_bounded()` は本関数の最初の1件を返すだけであり、
    **戻り値は切り出し前と1件も変わらない**。
    """
    if not needle_normalized:
        return
    clean, idx = _clean_and_map(marked_haystack)
    n = len(needle_normalized)
    i = clean.find(needle_normalized)
    while i >= 0:
        s, e = idx[i], idx[i + n - 1] + 1
        left_bad = needle_normalized[0] in _DIGITS and _continues_left(marked_haystack, s)
        right_bad = needle_normalized[-1] in _DIGITS and _continues_right(marked_haystack, e)
        if not (left_bad or right_bad):
            yield i
        i = clean.find(needle_normalized, i + 1)


def find_bounded(marked_haystack: str, needle_normalized: str) -> int:
    """番兵入り haystack から needle を探す。**桁境界を跨いだ一致は採らない**。

    詳細は `iter_bounded()`。戻り値は番兵を除いた文字列上のインデックス
    （見つからなければ -1）。
    """
    return next(iter_bounded(marked_haystack, needle_normalized), -1)


def contains_marked(marked_haystack: str, needle: str) -> bool:
    """`normalize_marked()` 済みの haystack に対する桁境界つき部分一致。

    同じ回答に多数の alias を当てるときは、haystack の正規化を1回で済ませるために
    こちらを使う（`contains()` は毎回正規化し直す）。
    """
    return find_bounded(marked_haystack, normalize(needle)) >= 0


def contains(haystack: str, needle: str) -> bool:
    """正規化したうえでの部分一致。要素判定 [N]/[E] の基本操作。

    2026-07-26: 単純な `in` から**桁境界つき**に変更した（`find_bounded()` 参照）。
    数字以外の端しか持たない needle の挙動は従来と同一である。
    """
    return contains_marked(normalize_marked(haystack), needle)


def contains_any(haystack: str, needles) -> bool:
    marked = normalize_marked(haystack)
    return any(contains_marked(marked, n) for n in needles if n)


# --------------------------------------------------------------------------
# 自己テスト
# --------------------------------------------------------------------------

def _selftest() -> None:
    # 既存互換
    assert strip_think("<think>a\nb</think> 答え") == "答え"
    assert squash_ws("持ち込ま せず　です") == "持ち込ませずです"

    # 全半角・％
    assert to_halfwidth("１．４％") == "1.4%"
    assert "第Ⅰ部" in to_halfwidth("第Ⅰ部")          # ローマ数字は保持

    # 和暦
    assert wareki_to_seireki("令和7年3月24日") == "2025年3月24日"
    assert wareki_to_seireki("令和元年") == "2019年"
    assert wareki_to_seireki("平成30年") == "2018年"

    # 数値表記ゆれ（ロードマップS02の明示要件）
    a, b, c = normalize("8兆4,748億円"), normalize("84,748億円"), normalize("8兆4748億円")
    assert a == b == c, (a, b, c)
    assert normalize("9.9兆円") == normalize("99,000億円")
    assert normalize("1万2,300円") == normalize("12,300円") == "12300円"
    assert normalize("11兆円程度") == normalize("110,000億円程度")
    assert normalize("１任期あたり約６８万円") == "1任期あたり約680000円"

    # 年は単位が付かないので壊れない
    assert normalize("2025年3月24日") == "2025年3月24日"
    assert normalize("令和7年 3月 24日") == "2025年3月24日"
    # 3桁区切りでないカンマは残す（「1,2」など誤展開しない）
    assert normalize("1,2") == "1,2"
    # 回帰: 図表行のように数値が空白区切りで並んでも桁が壊れない
    # （印字452 図表Ⅳ-3-4-2「合計1,468 2,311 2,122 1,707 1,422」）
    table = "合計1,468 2,311 2,122 1,707 1,422"
    assert contains(table, "1,422") and contains(table, "1,707")
    assert normalize(table) == "合計14682311212217071422"

    assert contains("回答は8兆4,748億円です。", "84748億円")
    assert contains_any("約68万円になります", ["約70万円", "68万円"])
    assert not contains("2030年度に運用終了", "2026年度")

    # 冪等性
    for s in ["8兆4,748億円", "令和7年", "１．４％", "1,234,567円"]:
        assert normalize(normalize(s)) == normalize(s), s

    # ---- 桁境界チェック（2026-07-26） --------------------------------------
    # S06 で実際に偽陽性を出していた2件（JUDGE_MODEL_CALIBRATION §4-3）
    q06 = "1任期あたりの支給額が約27万円から約68万円に増額されます。"
    assert not contains(q06, "7万円"), "270000円 の桁の途中に 70000円 が当たってはならない"
    assert not contains(q06, "70,000円")
    assert contains(q06, "68万円")     # 同じ回答内の正当な一致は残る
    q11 = "1任期あたりの支給額は約171万円から約274万円になります。"
    assert not contains(q11, "17,100"), "1710000 の桁の途中に 17100 が当たってはならない"
    assert not contains(q11, "17100")
    # 正当に書かれていれば当たる
    assert contains("訓練招集手当は日額17,100円です", "17,100")
    assert contains("訓練招集手当は日額17,100円です", "17100")
    # 桁の途中（カンマ・小数点をまたぐ場合も含む）
    assert not contains("11,422円", "1,422")
    assert not contains("金額は1.422です", "422")
    assert not contains("金額は1.422です", "1.4")   # 直後が `2` なので桁の続き
    # ★空白で区切られていた別々の数値は、正規化で連結しても一致させる（既存の回帰）
    table = "合計1,468 2,311 2,122 1,707 1,422"
    assert contains(table, "1,422") and contains(table, "1,707") and contains(table, "1,468")
    assert not contains(table, "23112")  # 連結した数値の桁の途中で終わる一致は採らない
    # PDFの字間空白で数字が割れていても拾う（番兵は桁の内側にも入りうる）
    assert contains("歳出額は8兆47 48億円です", "84748億円")
    # 数字以外で終始する needle は従来どおり（境界判定なし）
    assert contains("第Ⅴ部まで5部構成です", "5部")
    assert contains("非交戦権について", "交戦権")

    # normalize_marked は番兵を除けば normalize と一致する（構成上の不変条件）
    for s in [q06, q11, table, "8兆4,748億円", "令和7年 3月 24日", "1万2,300円", ""]:
        assert normalize_marked(s).replace(_SEP, "") == normalize(s), s

    print("_eval_common selftest: OK")


if __name__ == "__main__":
    _selftest()
