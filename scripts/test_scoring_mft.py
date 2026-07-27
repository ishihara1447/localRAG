# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""test_scoring_mft.py — 採点器の Minimum Functionality Test（MFT）回帰スイート。

    uv run scripts/test_scoring_mft.py          # 全件実行
    python3 scripts/test_scoring_mft.py         # 同上（標準ライブラリのみ）
    uv run scripts/test_scoring_mft.py --strict # 既知の未修正欠陥も FAIL 扱いにする
    uv run scripts/test_scoring_mft.py -v       # PASS した項目も1行ずつ表示

============================================================================
なぜこのファイルがあるか
============================================================================
採点器（評価スクリプトの正誤判定ロジック）の欠陥が **5例連続で発生し、うち4例は
「評価が甘い方向」＝システムを実際より良く見せる方向**だった。

これは leniency bias として実証されている既知現象である。LLM 判定者は
**TPR > 96% に対し TNR < 25%**、つまり「正しい答えを正しいと言う」のは得意だが
「**誤りを誤りと言えない**」（arXiv:2510.11822 / CALM の Fallacy-Oversight）。
文字列一致ベースの決定的採点器も、部分一致・裸のパターンという形で同じ方向に倒れる。

先行研究の標準解は **CheckList（ACL 2020）の Minimum Functionality Test**、
すなわち **既知の失敗例を常設の回帰テストにする** ことである。
本ファイルは `docs/RESEARCH_EVAL_INDEPENDENCE_2026-07-27.md` §9 手順1 の実装であり、
過去に実際に起きた採点事故 6 件をすべて実データで固定する。

**このスイートの主目的は「甘い方向の誤りを検出する負例」を厚く持つことである。**
正例（表記ゆれが壊れていないこと）は、負例対策の副作用で採点が過度に厳しくなる
——Kaushik et al. ACL 2021 が警告する方向——のを防ぐために置いてある。

============================================================================
固定している事故（すべて実データ）
============================================================================
| # | 事故 | 根拠ドキュメント | 本ファイルの群 |
|---|------|------------------|----------------|
| 1-2 | PDFの字間空白で `持ち込ま せず` が `持ち込ませず` と不一致 | JP_PDF_SPACING_FIX_2026-07-14 / RAG_EVAL_INTERNAL_AUDIT_2026-07-16 §1-1,§1-2 | A |
| 3 | `70000円` が `約270000円` の内部に一致して YES 誤判定 | EVAL_HARNESS_FIXES_2026-07-26 修正4 / JUDGE_MODEL_CALIBRATION_2026-07-26 §4-3 | B |
| 4 | 裸の `含まれて`/`記載されて` が肯定文にも一致し、ハルシネーションを「不明応答＝正解」と誤判定 | RAG_EVAL_INTERNAL_AUDIT_2026-07-16 §1-3 / EVAL_HARNESS_FIXES_2026-07-26 修正3 | C |
| 5 | `予備自衛官手当` が `即応予備自衛官手当` の内部に一致し正誤を区別できない | EXCLUSION_FIELD_AND_MOJIBAKE_2026-07-27 増分1 / A1_C1X_C2X_RESULTS_2026-07-27 | D |
| 6 | `hakusho-eval` が `sessionId` を振らず履歴が交絡（検索結果が同一でも回答が23〜24/30の設問で変わった） | EVAL_HARNESS_FIXES_2026-07-26 タスク1 | F |
| — | 日本語の表記ゆれ（兆・億・和暦・全半角・カンマ）が壊れていないこと | _eval_common.py / COMPLEX_QA_EVAL_SET_DESIGN §8-4 | E |

============================================================================
既知の未修正欠陥（KNOWN）の扱い
============================================================================
`known_defect=` を付けたテストは「現時点で FAIL することが分かっている実欠陥」である。
FAIL しても終了コードは 0 のまま（ただし最後に大きく警告を出す）。**逆に PASS したら
終了コード 1 で落とす**——欠陥が直ったのにマークが残っているのは、次の誰かが
「これは既知だから気にしなくてよい」と誤読する原因になるためである（pytest の
xfail(strict=True) と同じ設計）。リリース判定では `--strict` で KNOWN も FAIL にすること。

**KNOWN を増やしてよいのは「実測で確認した実欠陥」だけである。**
落ちるテストを黙らせるために使ってはならない。

============================================================================
実装上の注意
============================================================================
- **既存スクリプトは一切変更しない。** 本ファイルは読み取り専用の検証器である。
- **テストフレームワークを導入しない。** 標準ライブラリのみ（`ast` / `re` / `json`）。
- 被検証スクリプト（`hakusho-eval.py` / `ambiguous-eval.py`）は
  **モジュール末尾で `main()` を素で呼んでいる**ため、素朴に import すると
  評価が走り出す。そこで `_load_decls()` が AST から
  「import・代入・関数/クラス定義・docstring」だけを残して実行する
  ＝ **副作用ゼロで定数と関数だけを取り出す**。
- `httpx` は採点ロジックに一切関与しないので、未インストールならスタブを差す
  （`uv run` の隔離環境でも依存を増やさずに動かすため）。
"""

from __future__ import annotations

import argparse
import ast
import json
import os
import re
import sys
import types

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
FIXTURE = os.path.join(ROOT, "fixtures", "complex", "hakusho-complex-qa.json")

sys.path.insert(0, HERE)

# 採点ロジックは httpx を使わない。無ければスタブ（依存を増やさないため）。
try:  # pragma: no cover
    import httpx  # noqa: F401
except ImportError:  # pragma: no cover
    sys.modules["httpx"] = types.ModuleType("httpx")


# ==========================================================================
# 被検証モジュールの副作用なしロード
# ==========================================================================

_DECL = (ast.Import, ast.ImportFrom, ast.Assign, ast.AnnAssign,
         ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)


def _load_decls(modname: str, path: str) -> types.ModuleType:
    """スクリプトから宣言だけを取り出して実行する（`main()` 等は実行しない）。

    `hakusho-eval.py` / `ambiguous-eval.py` は `if __name__` ガード無しで
    `main()` を呼ぶため、通常の import では **評価が実行されてしまう**。
    トップレベルの `Expr`（＝素の関数呼び出し）と `If`（＝`__main__` ガード）を
    落とすことで、定数・正規表現・純関数だけを安全に取得する。
    """
    tree = ast.parse(_read(path), path)
    tree.body = [n for n in tree.body
                 if isinstance(n, _DECL)
                 or (isinstance(n, ast.Expr) and isinstance(n.value, ast.Constant))]
    m = types.ModuleType(modname)
    m.__file__ = path
    sys.modules[modname] = m          # dataclass が cls.__module__ を引くので先に登録
    exec(compile(tree, path, "exec"), m.__dict__)
    return m


def _read(path: str) -> str:
    with open(path, encoding="utf-8") as f:
        return f.read()


def _p(name: str) -> str:
    return os.path.join(HERE, name)


EC = _load_decls("_ec_under_test", _p("_eval_common.py"))
CE = _load_decls("_complex_eval_under_test", _p("complex-eval.py"))
HK = _load_decls("_hakusho_under_test", _p("hakusho-eval.py"))
AM = _load_decls("_ambiguous_under_test", _p("ambiguous-eval.py"))
SC = _load_decls("_scale_under_test", _p("scale-eval.py"))
PR = _load_decls("_precision_under_test", _p("precision-eval.py"))

# 「不明応答＝正解」を判定する正規表現。4本それぞれが自前に持っている（コピペ運用）。
# 事故4 は「1本で直したのに他に取り残しがあった」形で再発したので **全本を等しく検査する**。
UNKNOWN_RES = {
    "hakusho-eval.py": HK.UNKNOWN,
    "ambiguous-eval.py": AM.UNKNOWN,
    "scale-eval.py": SC.UNKNOWN_PATTERNS,
    "precision-eval.py": PR.UNKNOWN_PATTERNS,
}

with open(FIXTURE, encoding="utf-8") as f:
    _CASES = {c["id"]: c for c in json.load(f)["cases"]}


def el(case_id: str, el_id: str) -> dict:
    """評価セットの実要素を1つ取り出す（テストに実データを使うため）。"""
    for e in _CASES[case_id]["elements"]:
        if e["id"] == el_id:
            return e
    raise KeyError(f"{case_id}/{el_id} が {FIXTURE} に無い")


def verdict(answer: str, element: dict) -> bool | None:
    return CE.judge_element(answer, element)["verdict"]


# ==========================================================================
# 極小テストランナー
# ==========================================================================

class Case:
    __slots__ = ("fn", "group", "accident", "title", "known")

    def __init__(self, fn, group, accident, title, known):
        self.fn, self.group, self.accident, self.title, self.known = \
            fn, group, accident, title, known


TESTS: list[Case] = []


def mft(group: str, accident: str, title: str, known_defect: str | None = None):
    """テスト登録デコレータ。

    group      … A〜F（事故の分類。冒頭の表と対応）
    accident   … どの事故に対応するか（1行で。必須）
    title      … 何を確かめるか
    known_defect … 実測済みの未修正欠陥。FAILしても落とさないが、PASSしたら落とす
    """
    def deco(fn):
        TESTS.append(Case(fn, group, accident, title, known_defect))
        return fn
    return deco


# ==========================================================================
# 群A: PDF由来の字間空白（事故1・2）
#   `docs/JP_PDF_SPACING_FIX_2026-07-14.md`：pdfjs が均等割り付けされた日本語の
#   字間に空白を挿入する。採点側がこれを吸収し損ね「持ち込ま せず」を誤NGにした。
#   さらに `RAG_EVAL_INTERNAL_AUDIT_2026-07-16.md` §1-1 によれば、同じ理由で
#   翌日「約3万2,000円」も誤NGになり、**2回連続で手動補正**が行われた。
# ==========================================================================

@mft("A", "事故1: 「持ち込ま せず」が「持ち込ませず」と不一致（誤NG）",
     "正例: 空白正規化後は一致する（squash_ws 層）")
def a01_squash_ws_basic():
    assert EC.squash_ws("持ち込ま せず") == EC.squash_ws("持ち込ませず") == "持ち込ませず"
    assert EC.squash_ws("持ち込ま　せず") == "持ち込ませず"      # 全角スペース U+3000
    assert EC.squash_ws("持ち込ま\nせず") == "持ち込ませず"       # 改行


@mft("A", "事故1: 同上（hakusho-eval / ambiguous-eval の kw 判定経路そのもの）",
     "正例: 実際の grade() が非核三原則の kw 全含有を通す")
def a02_grade_kw_path():
    spec = ("kw", ["持たず", "作らず", "持ち込ませず"])
    for label, ans in [
        ("字間空白", "非核三原則とは「持たず、作らず、持ち込ま せず」です。"),
        ("全角空白", "非核三原則とは「持たず、作らず、持ち込ま　せず」です。"),
        ("改行", "非核三原則とは「持たず、作らず、持ち込ま\nせず」です。"),
        ("空白なし", "非核三原則とは「持たず、作らず、持ち込ませず」です。"),
    ]:
        assert HK.grade(ans, spec) is True, f"hakusho-eval が誤NG: {label}"
        assert AM.grade(ans, spec) is True, f"ambiguous-eval が誤NG: {label}"


@mft("A", "事故2: 「約3万2,000円」を表記ゆれとして受理できず手動補正した（監査§1-1）",
     "正例: Layer0 正規化が万単位＋カンマの表記ゆれを吸収する")
def a03_manyen_comma():
    for a, b in [("約3万2,000円", "32,000円"), ("3万2,000円", "32000円"),
                 ("約6万8,000円", "68,000円")]:
        assert EC.normalize(a).endswith(EC.normalize(b)), f"{a!r} が {b!r} を含まない"
    assert EC.contains("支給額は約3万2,000円です", "32,000円")


@mft("A", "事故1・2の過剰修正防止（Kaushik et al. ACL 2021: 敵対的修正の副作用）",
     "負例: 空白を消しても意味の違うものは一致してはならない")
def a04_squash_ws_not_too_lenient():
    # 「持ち込ませず」と「持ち込ませる」は空白を消しても別物
    assert not EC.contains("核兵器を持ち込ませる方針です。", "持ち込ませず")
    assert HK.grade("核兵器を持ち込ませる方針です。", ("kw", ["持ち込ませず"])) is False
    # 空白除去は語をまたいだ偶発一致を作りうる。それが起きていないこと
    assert not EC.contains("2030年度に運用終了", "2026年度")


# ==========================================================================
# 群B: 数値の桁境界（事故3）
#   `70000円` が `約270000円` の内部に、`17100` が `約1710000円` の内部に
#   桁を跨いで一致し、**S06 の決定的採点で偽陽性を2件**出していた。
#   （EVAL_HARNESS_FIXES_2026-07-26 修正4 / JUDGE_MODEL_CALIBRATION §4-3）
#   これは典型的な「甘い方向」の誤り＝存在しない正解を数え上げる。
# ==========================================================================

@mft("B", "事故3: `70000円` が `約270000円` の内部に一致して YES 誤判定",
     "負例: 桁の途中で始まる一致を採ってはならない")
def b01_digit_boundary_left():
    q06 = "1任期あたりの支給額が約27万円から約68万円に増額されます。"
    assert not EC.contains(q06, "7万円"), "270000円 の桁の途中に 70000円 が当たった"
    assert not EC.contains(q06, "70,000円")
    assert not EC.contains(q06, "70000円")


@mft("B", "事故3の同型（`17100` が `約1710000円` の内部に一致）",
     "負例: 桁の途中で終わる一致を採ってはならない")
def b02_digit_boundary_right():
    q11 = "1任期あたりの支給額は約171万円から約274万円になります。"
    assert not EC.contains(q11, "17,100"), "1710000 の桁の途中に 17100 が当たった"
    assert not EC.contains(q11, "17100")
    # カンマ・小数点をまたぐ桁の続きも同様に不一致
    assert not EC.contains("11,422円", "1,422")
    assert not EC.contains("金額は1.422です", "1.4")


@mft("B", "事故3の修正が、正当な一致まで潰していないこと",
     "正例: 桁境界が立っていれば従来どおり一致する")
def b03_digit_boundary_positive():
    assert EC.contains("訓練招集手当は日額17,100円です", "17,100")
    assert EC.contains("訓練招集手当は日額17,100円です", "17100")
    assert EC.contains("1任期あたり約68万円になります", "68万円")
    # ★白書の図表行。空白で区切られた別々の数値は正規化で連結しても一致させる
    table = "合計1,468 2,311 2,122 1,707 1,422"
    for n in ("1,422", "1,707", "1,468"):
        assert EC.contains(table, n), f"図表行の {n} を取りこぼした"
    assert not EC.contains(table, "23112"), "連結した数値の桁の途中に当たった"
    # PDF字間空白で数字が割れていても拾う（群Aと群Bの相互作用）
    assert EC.contains("歳出額は8兆47 48億円です", "84748億円")


@mft("B", "事故3が実際に起きた要素そのもの（Q06 e3 / Q11 e2）",
     "負例: complex-eval の judge_element 経路で偽陽性が再発しないこと")
def b04_judge_element_regression():
    # Q06 e3 の alias は ["7万円", "70,000円", "7万円を支給"]。
    # 回答は「約27万円から約68万円」としか言っておらず、勤続報奨金7万円には触れていない。
    assert verdict("1任期あたりの支給額が約27万円から約68万円に増額されます。",
                   el("Q06", "e3")) is False
    # Q11 e2 の alias は ["17,100", "17100"]。回答は「約171万円」しか言っていない。
    assert verdict("1任期あたりの支給額は約171万円から約274万円になります。",
                   el("Q11", "e2")) is False


@mft("B", "事故3の修正の副作用チェック",
     "正例: judge_element が正当な言及を取りこぼしていないこと")
def b05_judge_element_positive():
    assert verdict("予備自衛官にも勤続報奨金7万円が新設されます。", el("Q06", "e3")) is True
    assert verdict("訓練招集手当は日額17,100円です。", el("Q11", "e2")) is True


# ==========================================================================
# 群C: 「不明応答」判定の裸パターン（事故4）— 最も leniency bias に直結
#   内部監査 §1-3:
#     否定語を伴わない裸の `含まれて` `記載されて` `該当する` は
#     「〜が記載されています」のような **肯定文にもマッチする**。
#     (d) 不明応答カテゴリでこれが起きると、**ハルシネーションを
#      「不明応答＝正解」と数えてしまう**。
#   このカテゴリは「ハルシネーションほぼゼロ」という製品の安全性主張の
#   唯一の根拠なので、ここが甘いことは他のどの誤りより重い。
# ==========================================================================

# 肯定的に内容を答えている＝(d) では **不正解** でなければならない文（実ログ由来を含む）
_AFFIRMATIVE = [
    # RAG_EVAL_INTERNAL_AUDIT §1-3 が実ログ（scratchpad/hakusho-chunk1000.log:3）から引いた文
    "2025年度の防衛関係費に関する情報は、以下の通り記載されています。",
    # EVAL_HARNESS_FIXES_2026-07-26 修正3 の検証ケース
    "出張日当は3,400円と記載されています",
    "その数値は資料に含まれている",
    # 監査が挙げたもう1語 `該当する`
    "この条件に該当する規定は第3条です。",
    # ハルシネーションの典型形（(d) 設問に対し堂々と作り話をする）
    "資本金は1億2,000万円と記載されています。詳細は第2章に含まれています。",
]

# 本当に「わからない」と言っている＝(d) では **正解** でなければならない文
_REFUSALS = [
    "資本金の情報は文書に含まれていません",
    "白書には記載がありません",
    "その情報は記載されていません",
    "わかりません",
    "該当する記述は見つかりませんでした",
    "提供された文脈からは不明です",
]


@mft("C", "事故4: 裸の `含まれて`/`記載されて`/`該当する` が肯定文に一致し、"
          "ハルシネーションを「不明応答＝正解」と誤判定",
     "負例: 肯定文を不明応答と判定してはならない（4スクリプト全数）")
def c01_unknown_no_false_positive():
    bad = []
    for name, rx in UNKNOWN_RES.items():
        for s in _AFFIRMATIVE:
            m = rx.search(s)
            if m:
                bad.append(f"{name}: <<{m.group(0)}>> が肯定文に一致 → {s}")
    assert not bad, "肯定文を不明応答と誤判定した（甘い方向の誤り）:\n  " + "\n  ".join(bad)


@mft("C", "事故4の修正が拒否応答まで潰していないこと",
     "正例: 本物の不明応答は従来どおり検出される（4スクリプト全数）")
def c02_unknown_true_positive():
    miss = []
    for name, rx in UNKNOWN_RES.items():
        for s in _REFUSALS:
            if not rx.search(s):
                miss.append(f"{name}: 検出できず → {s}")
    assert not miss, "本物の不明応答を取りこぼした:\n  " + "\n  ".join(miss)


@mft("C", "事故4: hakusho-eval の (d) 判定経路そのもの（grade(spec=None)）",
     "負例＋正例: grade() が肯定文を正解にしないこと")
def c03_grade_unknown_path():
    assert HK.grade("資本金は1億2,000万円と記載されています。", None) is False, \
        "ハルシネーションを (d) の正解と数えた"
    assert HK.grade("その情報は白書に記載がありません。", None) is True


@mft("C", "事故4と同型（裸パターン）— 新規発見 2026-07-27",
     "負例: 裸の `見つかり` が肯定文『見つかりました』に一致してはならない",
     known_defect="4本すべてに `見つかり` が裸で残っている。"
                  "`該当する規定が見つかりました。第3条です。` を不明応答と誤判定する。"
                  "**甘い方向**の誤りで事故4と同じ病理。"
                  "修正するなら `見つからな|見つかりませんでした|見つかっていな` の形。")
def c04_bare_mitsukari():
    bad = []
    for name, rx in UNKNOWN_RES.items():
        for s in ["該当する規定が見つかりました。第3条です。",
                  "文書内に該当箇所が見つかりましたので引用します。"]:
            m = rx.search(s)
            if m:
                bad.append(f"{name}: <<{m.group(0)}>> → {s}")
    assert not bad, "\n  " + "\n  ".join(bad)


@mft("C", "事故4と同型（裸パターン）— 新規発見 2026-07-27",
     "負例: 裸の `お答えでき` が『お答えできます』に一致してはならない",
     known_defect="hakusho-eval / ambiguous-eval / precision-eval が `お答えでき` を"
                  "裸で持つ（scale-eval のみ `お答えできません` と正しく書けている）。"
                  "**甘い方向**の誤り。scale-eval の書き方に揃えれば直る。")
def c05_bare_okotae():
    bad = []
    for name, rx in UNKNOWN_RES.items():
        s = "ご質問にはお答えできます。定年は60歳です。"
        m = rx.search(s)
        if m:
            bad.append(f"{name}: <<{m.group(0)}>> → {s}")
    assert not bad, "\n  " + "\n  ".join(bad)


@mft("C", "事故4の裏返し（厳しい方向の取りこぼし）— 新規発見 2026-07-27",
     "正例: `存在しません` 型の拒否を全スクリプトが検出できること",
     known_defect="scale-eval.py の UNKNOWN_PATTERNS だけ `存在しません` を持たない。"
                  "**厳しい方向**（システムを実際より悪く見せる）なので緊急度は低いが、"
                  "4本のコピペが同期していない証拠であり、"
                  "本来は `_eval_common.py` に一本化すべき。")
def c06_unknown_pattern_drift():
    miss = [name for name, rx in UNKNOWN_RES.items()
            if not rx.search("その情報は本文書に存在しません")]
    assert not miss, f"`存在しません` を検出できないスクリプト: {miss}"


# ==========================================================================
# 群D: 日本語の語包含と排他語（事故5）
#   日本語には語境界の空白が無いため `即応予備自衛官手当` ⊃ `予備自衛官手当` を
#   部分一致で区別できない。Q11 の [X] 正規表現 `予備自衛官手当.{0,10}18,?500` は
#   **正しい表記** `即応予備自衛官手当（月額18,500円）` にも発火し、
#   正答をハルシネーションと誤判定していた（EXCLUSION_FIELD_AND_MOJIBAKE 増分1）。
#   対策は fixture 側の `match.not_preceded_by`（宣言的な否定後読み）。
# ==========================================================================

@mft("D", "事故5: `予備自衛官手当` が `即応予備自衛官手当` の内部に一致し正誤を区別できない",
     "負例: 排他語ありの Q11 x1 が、正しい表記に発火してはならない")
def d01_exclusion_blocks_correct_form():
    assert verdict("即応予備自衛官手当（月額18,500円）が支給されます。", el("Q11", "x1")) is False
    # 正規化が効くので途中に空白・改行が入っても同じ
    assert verdict("即応 予備自衛官手当（月額18,500円）", el("Q11", "x1")) is False
    assert verdict("即応\n予備自衛官手当（月額18,500円）", el("Q11", "x1")) is False


@mft("D", "事故5の修正が、本来の検出まで潰していないこと",
     "正例: 誤った表記には従来どおり発火する")
def d02_exclusion_keeps_detection():
    # 略記（＝予備自衛官の手当として 18,500 を出す誤り）は検出されねばならない
    assert verdict("予備自衛官手当（月額18,500円）が支給されます。", el("Q11", "x1")) is True
    # 同じ [X] の別選択肢（即応予備自衛官に 12,300 を当てる誤り）を巻き添えにしない
    assert verdict("即応予備自衛官手当（月額12,300円）です。", el("Q11", "x1")) is True
    # 正しい表記と誤った表記が両方あれば、誤った側で発火する（後続の出現を見に行く）
    assert verdict("即応予備自衛官手当は18,500円。予備自衛官手当も18,500円です。",
                   el("Q11", "x1")) is True


@mft("D", "事故5: 排他語の機構そのもの（[N]/[E] でも動くこと）",
     "負例＋正例: not_preceded_by が alias 一致にも効く")
def d03_exclusion_mechanism_on_alias():
    element = {"type": "N", "id": "synthetic",
               "match": {"value": "予備自衛官手当",
                         "alias": ["予備自衛官手当"],
                         "not_preceded_by": ["即応"]}}
    assert verdict("即応予備自衛官手当は月額18,500円です。", element) is False
    assert verdict("予備自衛官手当は月額12,300円です。", element) is True
    # 排他語を書かなければ従来どおり（＝排他語は述語を狭めるだけ）
    plain = {"type": "N", "id": "synthetic2",
             "match": {"value": "予備自衛官手当", "alias": ["予備自衛官手当"]}}
    assert verdict("即応予備自衛官手当は月額18,500円です。", plain) is True


@mft("D", "事故5の同型が Q06 x1 に残存（申し送り: EXCLUSION_FIELD_AND_MOJIBAKE §1-6）",
     "負例: Q06 x1 も正しい表記に発火してはならない",
     known_defect="Q06 x1 の regex `予備自衛官手当.{0,12}18,?500|…` は Q11 x1 と同型だが "
                  "`not_preceded_by` が無く、正しい表記 `即応予備自衛官手当は月額18,500円` に "
                  "発火する（実測 verdict=True）。**甘い方向ではなく厳しい方向**（正答を "
                  "ハルシネーション扱い）だが、[X] の信頼性を損なう点は同じ。"
                  "🔴 申し送り文書は『Q10』と書いているが、実際の fixture では **Q06** である "
                  "（Q10 x1 は中国の脅威表現に関する別の regex）。"
                  "調査の結論どおり局所修正を積まず、[X] の judge 移行とまとめて直すこと。")
def d04_q06_same_pathology():
    v = verdict("即応予備自衛官手当は月額18,500円です。", el("Q06", "x1"))
    assert v is False, (
        "Q06 x1 が正しい表記 `即応予備自衛官手当は月額18,500円です。` に発火した "
        f"(verdict={v})。`予備自衛官手当` が `即応予備自衛官手当` の内部に一致している。")


# d05 が現時点で許容する「排他語の無い包含リスク regex」。
# **d04 と同じ1件だけ**。ここに追記してよいのは、その設問を [X] の judge 移行で
# 直すと決めたときだけであり、落ちるテストを黙らせるために足してはならない。
KNOWN_INCLUSION_OFFENDERS = {"Q06/x1"}


@mft("D", "事故5の申し送り自体の正しさを検証する（メタテスト）",
     "静的: `予備自衛官手当…18,500` 型の包含リスク regex が、既知の1件から増えていないこと")
def d05_exclusion_coverage_scan():
    """同じ病理を持つ [X] を fixture 全体から機械的に洗い出す。

    **どの設問が該当するかを人手の記憶に頼らない**ためのスキャンである。
    実際、申し送り（EXCLUSION_FIELD_AND_MOJIBAKE §1-6）は「Q10 にも同じ病理がある」
    と書いていたが、fixture 上の該当は **Q06** であり Q10 ではなかった
    （Q10 x1 は中国の脅威表現に関する別の regex）。人間の記憶は当てにならない。
    """
    # 「短い語が長い語に包含される」既知ペア。増えたらここに足す。
    inclusions = [("予備自衛官手当", "即応予備自衛官手当"), ("予備自衛官", "即応予備自衛官")]
    offenders = set()
    for cid, case in _CASES.items():
        for e in case["elements"]:
            if e["type"] != "X":
                continue
            m = e.get("match") or {}
            rx = m.get("regex", "")
            if m.get("not_preceded_by"):
                continue
            for short, long in inclusions:
                # 短い語が出るが、その出現がすべて長い語の一部として書かれている場合は安全
                if short in rx and re.sub(re.escape(long), "", rx).find(short) >= 0:
                    offenders.add(f"{cid}/{e['id']}")
                    break
    new = sorted(offenders - KNOWN_INCLUSION_OFFENDERS)
    fixed = sorted(KNOWN_INCLUSION_OFFENDERS - offenders)
    assert not new, ("排他語の無い包含リスク regex が新たに増えた（事故5の再発）: "
                     + ", ".join(new))
    assert not fixed, (f"{', '.join(fixed)} が直っている。"
                       "KNOWN_INCLUSION_OFFENDERS と d04 の known_defect を外すこと")


# ==========================================================================
# 群E: 日本語の表記ゆれが壊れていないこと（正例のみ）
#   群B・群Dの「厳しくする」修正が、Layer0 正規化の本来の役割を削っていないかの監視。
#   ここが FAIL したら「甘さ対策で厳しくしすぎた」＝ Kaushik et al. の警告どおりの副作用。
# ==========================================================================

@mft("E", "表記ゆれ（兆・億の展開）が壊れていないこと", "正例: 漢数単位の等価性")
def e01_myriad():
    a, b, c = (EC.normalize("8兆4,748億円"), EC.normalize("84,748億円"),
               EC.normalize("8兆4748億円"))
    assert a == b == c, (a, b, c)
    assert EC.normalize("9.9兆円") == EC.normalize("99,000億円")
    assert EC.normalize("11兆円程度") == EC.normalize("110,000億円程度")
    assert EC.normalize("1万2,300円") == EC.normalize("12,300円") == "12300円"


@mft("E", "表記ゆれ（和暦→西暦）が壊れていないこと", "正例: 令和・平成・元年")
def e02_wareki():
    assert EC.normalize("令和7年3月24日") == EC.normalize("2025年3月24日")
    assert EC.normalize("令和元年") == "2019年"
    assert EC.normalize("平成30年") == "2018年"
    assert EC.normalize("令和7年 3月 24日") == "2025年3月24日"   # 字間空白との併用


@mft("E", "表記ゆれ（全角半角・カンマ）が壊れていないこと", "正例: 全半角統一と3桁カンマ")
def e03_fullwidth_comma():
    assert EC.to_halfwidth("１．４％") == "1.4%"
    assert "第Ⅰ部" in EC.to_halfwidth("第Ⅰ部")               # ローマ数字は保持する
    assert EC.normalize("１任期あたり約６８万円") == "1任期あたり約680000円"
    assert EC.normalize("1,2") == "1,2"                       # 3桁でないカンマは残す
    assert EC.contains("回答は8兆4,748億円です。", "84748億円")
    assert EC.contains_any("約68万円になります", ["約70万円", "68万円"])


@mft("E", "正規化の冪等性（二重適用で壊れない）", "正例: normalize(normalize(x)) == normalize(x)")
def e04_idempotent():
    for s in ["8兆4,748億円", "令和7年", "１．４％", "1,234,567円",
              "約3万2,000円", "持ち込ま せず", "合計1,468 2,311 1,422"]:
        assert EC.normalize(EC.normalize(s)) == EC.normalize(s), s
    # normalize_marked は番兵を除けば normalize と一致する（構成上の不変条件）
    for s in ["8兆4,748億円", "令和7年 3月 24日", "合計1,468 2,311", ""]:
        assert EC.normalize_marked(s).replace("\x00", "") == EC.normalize(s), s


# ==========================================================================
# 群F: sessionId の交絡（事故6）— 静的検証
#   `hakusho-eval.py` が `sessionId` を送っていなかったため、30問すべてが
#   既定セッションに積み上がり、**直前20件の質疑が毎回コンテキストに入っていた**。
#   結果、検索結果が6run同一なのに 23〜24/30 の設問で回答本文が変わり、
#   「28〜29/30の揺れ」を GPU 非決定性だと誤って説明していた
#   （EVAL_HARNESS_FIXES_2026-07-26 タスク1。sessionId 付与後は 90回答バイト一致）。
#
#   これは採点器の欠陥ではなく **測定条件の欠陥** だが、
#   「システムを実際より良くも悪くも見せうる交絡」という点で同じ回帰対象である。
#   実行にはサーバが要るので、**ソースを AST で静的に検証する**。
# ==========================================================================

CHAT_SCRIPTS = ["hakusho-eval.py", "ambiguous-eval.py", "scale-eval.py",
                "precision-eval.py", "complex-eval.py"]


def _static_text(node) -> str:
    """Constant / JoinedStr から静的に読める部分の文字列を返す。"""
    if isinstance(node, ast.Constant):
        return node.value if isinstance(node.value, str) else ""
    if isinstance(node, ast.JoinedStr):
        return "".join(v.value for v in node.values
                       if isinstance(v, ast.Constant) and isinstance(v.value, str))
    return ""


def _enclosing_funcs(tree: ast.AST) -> dict[ast.AST, ast.FunctionDef]:
    """各ノード → それを含む最も内側の FunctionDef。"""
    owner: dict[ast.AST, ast.FunctionDef] = {}

    def walk(node, fn):
        for child in ast.iter_child_nodes(node):
            f = child if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)) else fn
            if f is not None:
                owner[child] = f
            walk(child, f)
    walk(tree, None)
    return owner


def _loop_vars(fn: ast.AST) -> set[str]:
    """関数内の for 文が束縛する名前（＝設問ループの変数）。"""
    names = set()
    for n in ast.walk(fn):
        if isinstance(n, (ast.For, ast.AsyncFor)):
            for t in ast.walk(n.target):
                if isinstance(t, ast.Name):
                    names.add(t.id)
    return names


def _varies_per_question(node, tree, owner, depth=0) -> bool:
    """`sessionId` の値が **設問ごとに変わる** と静的に言えるか。

    判定: f-string であり、かつ整形部が **その関数の for ループ変数** を参照している。
    値が変数なら (a) 同関数内の代入、(b) 引数として渡された呼び出し元、を辿る（最大3段）。
    """
    if depth > 3 or node is None:
        return False
    if isinstance(node, ast.JoinedStr):
        fn = owner.get(node)
        loops = _loop_vars(fn) if fn is not None else set()
        for v in node.values:
            if not isinstance(v, ast.FormattedValue):
                continue
            for sub in ast.walk(v):
                if isinstance(sub, ast.Name) and sub.id in loops:
                    return True
        return False
    if isinstance(node, ast.Constant):
        return False            # 固定文字列 ＝ 全問が同一セッション（事故6と同じ交絡）
    if not isinstance(node, ast.Name):
        return False

    name = node.id
    fn = owner.get(node)

    # (a) 同じ関数の中で代入されているか
    if fn is not None:
        for n in ast.walk(fn):
            if isinstance(n, ast.Assign) and any(
                    isinstance(t, ast.Name) and t.id == name for t in n.targets):
                if _varies_per_question(n.value, tree, owner, depth + 1):
                    return True

    # (b) 関数の引数なら、呼び出し元が渡している式を見る
    if fn is not None and isinstance(fn, (ast.FunctionDef, ast.AsyncFunctionDef)):
        params = [a.arg for a in fn.args.args]
        if name in params:
            pos = params.index(name)
            for n in ast.walk(tree):
                if not isinstance(n, ast.Call):
                    continue
                callee = (n.func.id if isinstance(n.func, ast.Name)
                          else n.func.attr if isinstance(n.func, ast.Attribute) else None)
                if callee != fn.name:
                    continue
                arg = None
                if len(n.args) > pos:
                    arg = n.args[pos]
                for kw in n.keywords:
                    if kw.arg == name:
                        arg = kw.value
                if arg is not None and _varies_per_question(arg, tree, owner, depth + 1):
                    return True
    return False


def audit_session_id(source: str, filename: str) -> list[str]:
    """chat API を叩く箇所が設問ごとに一意な sessionId を渡しているかを静的に検査する。

    返り値は問題点の一覧（空なら OK）。
    """
    tree = ast.parse(source, filename)
    owner = _enclosing_funcs(tree)
    problems: list[str] = []
    found_chat = 0

    for node in ast.walk(tree):
        if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                and node.func.attr == "post" and node.args):
            continue
        if "/chat" not in _static_text(node.args[0]):
            continue
        found_chat += 1
        where = f"{filename}:{node.lineno}"

        payload = next((kw.value for kw in node.keywords if kw.arg == "json"), None)
        if payload is None:
            problems.append(f"{where}: chat POST に json ボディが無い")
            continue

        value = None
        if isinstance(payload, ast.Dict):
            for k, v in zip(payload.keys, payload.values):
                if isinstance(k, ast.Constant) and k.value == "sessionId":
                    value = v
        elif isinstance(payload, ast.Name):
            # `body = {...}` / `body["sessionId"] = session` 形式（precision-eval.py）
            fn = owner.get(node)
            for n in ast.walk(fn) if fn is not None else []:
                if isinstance(n, ast.Assign):
                    for t in n.targets:
                        if (isinstance(t, ast.Subscript)
                                and isinstance(t.value, ast.Name) and t.value.id == payload.id
                                and isinstance(t.slice, ast.Constant)
                                and t.slice.value == "sessionId"):
                            value = n.value
                    if (any(isinstance(t, ast.Name) and t.id == payload.id for t in n.targets)
                            and isinstance(n.value, ast.Dict)):
                        for k, v in zip(n.value.keys, n.value.values):
                            if isinstance(k, ast.Constant) and k.value == "sessionId":
                                value = v
        else:
            problems.append(f"{where}: json ボディの形を静的に追えない（要目視）")
            continue

        if value is None:
            problems.append(f"{where}: chat リクエストに sessionId が無い"
                            "（事故6: 全設問が同一セッションに積まれ履歴が交絡する）")
        elif not _varies_per_question(value, tree, owner):
            problems.append(f"{where}: sessionId が設問ごとに変わると静的に確認できない"
                            "（固定値、またはループ変数を含まない）")

    if found_chat == 0:
        problems.append(f"{filename}: chat API を叩く箇所が見つからない"
                        "（検査器が壊れている可能性。URL の書き方が変わっていないか確認）")
    return problems


@mft("F", "事故6: hakusho-eval が sessionId を振らず履歴が交絡（回答が23〜24/30の設問で変化）",
     "静的: 全評価スクリプトが設問ごとに一意な sessionId を渡していること")
def f01_session_id_present():
    bad = []
    for name in CHAT_SCRIPTS:
        bad += audit_session_id(_read(_p(name)), name)
    assert not bad, "sessionId の交絡リスク:\n  " + "\n  ".join(bad)


@mft("F", "事故6の検査器自身が機能していること（メタテスト）",
     "負例: sessionId を落としたソースを検査器が確実に落とすこと")
def f02_session_auditor_self_check():
    """**検査器が「何も検出しない」まま緑になる事故**を防ぐ。

    leniency bias 対策の要点は「誤りを誤りと言えること」なので、
    検査器自身に対しても negative control を置く。
    """
    src = _read(_p("hakusho-eval.py"))

    mutated = src.replace('"sessionId":session', '')
    assert mutated != src, "変異の当て先が変わった。検査器のメタテストを更新すること"
    assert audit_session_id(mutated, "<mutant: sessionId 削除>"), \
        "sessionId を消したのに検査器が通した"

    mutated2 = src.replace('sid=f"hakusho-{run}-{i:02d}"', 'sid="hakusho-fixed"')
    assert mutated2 != src, "変異の当て先が変わった。検査器のメタテストを更新すること"
    assert audit_session_id(mutated2, "<mutant: 固定 sessionId>"), \
        "全問同一の固定 sessionId なのに検査器が通した"


# ==========================================================================
# 実行
# ==========================================================================

BANNER = "=" * 78


def main() -> int:
    ap = argparse.ArgumentParser(
        description="採点器のMFT回帰テスト（既知の採点事故を常設の回帰にする）")
    ap.add_argument("--strict", action="store_true",
                    help="既知の未修正欠陥(KNOWN)も FAIL 扱いにする（リリース判定用）")
    ap.add_argument("-v", "--verbose", action="store_true", help="PASS も1行ずつ表示")
    ap.add_argument("-k", metavar="SUBSTR", default="",
                    help="テスト名/事故名に SUBSTR を含むものだけ実行")
    args = ap.parse_args()

    cases = [c for c in TESTS
             if args.k in c.fn.__name__ or args.k in c.accident or args.k in c.title]

    passed, failed, known, xpassed = [], [], [], []
    for c in cases:
        try:
            c.fn()
            err = None
        except AssertionError as e:
            err = str(e) or "(メッセージなし)"
        except Exception as e:                                   # noqa: BLE001
            err = f"{type(e).__name__}: {e}"

        tag = f"[{c.group}] {c.fn.__name__}"
        if err is None:
            if c.known:
                xpassed.append((c, tag))
                print(f"XPASS {tag}\n      {c.title}\n"
                      f"      既知欠陥が直っている。known_defect マークを外すこと。")
            else:
                passed.append((c, tag))
                if args.verbose:
                    print(f"PASS  {tag}  {c.title}")
        else:
            if c.known and not args.strict:
                known.append((c, tag, err))
                print(f"KNOWN {tag}\n      {c.title}\n      → {err.strip()[:700]}")
            else:
                failed.append((c, tag, err))
                print(f"FAIL  {tag}\n      事故: {c.accident}\n      確認: {c.title}\n"
                      f"      → {err.strip()[:900]}")

    print("\n" + BANNER)
    print(f"MFT 採点器回帰テスト: {len(passed)} passed / {len(failed)} failed / "
          f"{len(known)} known-defect / {len(xpassed)} xpass  （全 {len(cases)} 件）")
    print(BANNER)

    if known:
        print("\n🔴 既知の未修正欠陥（KNOWN）— 採点結果を解釈する前に必ず読むこと")
        for c, tag, _ in known:
            print(f"\n  {tag}")
            print(f"    事故: {c.accident}")
            for line in _wrap(c.known, 72):
                print(f"    {line}")
        print("\n  これらは `--strict` で FAIL になる。リリース判定では --strict を使うこと。")

    if xpassed:
        print("\n🔴 XPASS: 既知欠陥が直っているのに known_defect マークが残っている。"
              "\n  マークを外さないと、次の担当者が実在しない欠陥を前提に判断する。")

    if failed:
        print("\n🔴 回帰を検出した。過去に直したはずの採点事故が再発している。"
              "\n  **片方の条件だけ直して比較してはならない。**"
              "\n  採点器を直したら全条件を再実行すること"
              "（docs/EVAL_PROTOCOL_2026-07-27.md §2）。")

    return 1 if (failed or xpassed) else 0


def _wrap(text: str, width: int) -> list[str]:
    out, line = [], ""
    for token in re.split(r"(?<=[。、）\s])", text):
        if len(line) + len(token) > width and line:
            out.append(line)
            line = ""
        line += token
    if line:
        out.append(line)
    return out


if __name__ == "__main__":
    sys.exit(main())
