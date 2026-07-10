# /// script
# requires-python = ">=3.10"
# dependencies = ["httpx>=0.27"]
# ///
"""precision-eval.py — LocalRAGの検索・回答精度を評価する。

rag-e2e-test.sh が「壊れていないか（smoke test）」を見るのに対し、
このスクリプトは「実務で使える精度か」を見る。具体的には:

  1. 単一の長文文書（test-hr-manual.txt, 20条・約1,700字）内で、
     冒頭・中盤・末尾に散らばった情報を正しく検索・回答できるか。
  2. 近接する類似数値（試用期間3ヶ月 vs 延長1ヶ月、時間外労働の
     45h/100h/80h/360h等）を意味的に区別できるか。
  3. 文書に無い情報（本マニュアルに定めがないと明記された出張旅費など）に
     対して正しく「不明」と答えられるか。
  4. 複数文書（test-policy.txt / test-expense.pdf / test-attendance.docx /
     test-hr-manual.txt）を同一ワークスペースに入れたとき、質問に対して
     "正しい文書" から出典を引けているか（文書間の誤帰属がないか）。

使い方:
  uv run scripts/precision-eval.py

環境変数:
  LOCALRAG_BASE_URL (既定 http://localhost:3001)

このスクリプト自体がAPIキーを発行・削除するため、事前のキー発行は不要。
"""

from __future__ import annotations

import os
import re
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

import httpx

BASE_URL = os.environ.get("LOCALRAG_BASE_URL", "http://localhost:3001")
FIXTURES_DIR = Path(__file__).resolve().parent.parent / "fixtures"
TIMEOUT = 180.0


@dataclass
class Case:
    question: str
    # 回答本文が満たすべき正規表現（いずれか1つでも合致すればOK）。空なら「不明応答」を期待。
    expect_any: list[str] = field(default_factory=list)
    # 出典として含まれるべきファイル名の部分文字列（Noneならチェックしない）
    expect_source_contains: str | None = None
    expect_unknown: bool = False
    note: str = ""


SINGLE_DOC_CASES = [
    Case("試用期間は何ヶ月ですか？", [r"3\s*(ヶ|か|カ)?月"], note="冒頭(第2条)"),
    Case("試用期間はどれだけ延長できますか？", [r"1\s*(ヶ|か|カ)?月"], note="第2条・近接数値の区別(3ヶ月 vs 1ヶ月)"),
    Case("所定労働時間は1日何時間ですか？", [r"7\s*時間\s*45\s*分"], note="第3条"),
    Case("時間外労働の複数月平均の上限は何時間ですか？", [r"80\s*時間"], note="第5条・45/100/80/360の中から正しい値を選べるか"),
    Case("時間外労働は1年で何時間まで認められますか？", [r"360\s*時間"], note="第5条・別の数値との区別"),
    Case("このマニュアルで年次有給休暇は何日から付与されると定められていますか？", [r"14\s*日"], note="第6条・他文書(22日)との混同がないか単独文書内で確認"),
    Case("有給休暇の請求権は何年で時効になりますか？", [r"2\s*年"], note="第7条"),
    Case("産後休業は出産日の翌日から何週間ですか？", [r"8\s*週間"], note="第8条・中盤"),
    Case("育児休業は保育所に入れない場合、最長で子が何歳になるまで延長できますか？", [r"2\s*歳"], note="第9条"),
    Case("介護休業は通算何日まで取得できますか？", [r"93\s*日"], note="第10条"),
    Case("賞与は年何回支給予定ですか？", [r"(年)?\s*2\s*回"], note="第12条・末尾寄り"),
    Case("退職金の支給に必要な勤続年数は何年ですか？", [r"3\s*年"], note="第13条"),
    Case("在宅勤務手当は月額いくらですか？", [r"3,?000\s*円"], note="第18条・末尾"),
    Case("本人の結婚の際の特別休暇は何日ですか？", [r"5\s*日"], note="第19条・最末尾"),
    Case("出張の日当はいくらですか？", [], expect_unknown=True, note="第17条で明示的に「本マニュアルには定めない」としている罠"),
    Case("会社の資本金はいくらですか？", [], expect_unknown=True, note="単純に文書に存在しない情報"),
]

MULTI_DOC_CASES = [
    Case(
        "国内出張の日当は1日あたりいくらですか？",
        [r"3,?400\s*円"],
        expect_source_contains="test-expense",
        note="複数文書中、正しいソース(PDF)から引けるか",
    ),
    Case(
        "フレックスタイム制のコアタイムは何時から何時までですか？",
        # 全角/半角スペース・表記ゆれ (10:20 / 10時20分 / 10 時 20 分) を許容 (rag-e2e-test.shと同基準)
        [r"10[\s　]*[:時][\s　]*20"],
        expect_source_contains="test-attendance",
        note="複数文書中、正しいソース(DOCX)から引けるか",
    ),
    Case(
        "試用期間は何ヶ月ですか？",
        [r"3\s*(ヶ|か|カ)?月"],
        expect_source_contains="test-hr-manual",
        note="試用期間の記載はtest-hr-manualのみ。他文書と混同しないか",
    ),
]


def api_key_new(client: httpx.Client, name: str) -> str:
    r = client.post(f"{BASE_URL}/api/system/generate-api-key", json={"name": name})
    r.raise_for_status()
    return r.json()["apiKey"]["secret"]


def api_key_delete_all(client: httpx.Client, headers: dict) -> None:
    r = client.get(f"{BASE_URL}/api/system/api-keys", headers=headers)
    for k in r.json().get("apiKeys", []):
        client.delete(f"{BASE_URL}/api/system/api-key/{k['id']}", headers=headers)


def new_workspace(client: httpx.Client, headers: dict, name: str) -> str:
    r = client.post(f"{BASE_URL}/api/v1/workspace/new", headers=headers, json={"name": name})
    r.raise_for_status()
    return r.json()["workspace"]["slug"]


def update_workspace(client: httpx.Client, headers: dict, slug: str, **settings) -> None:
    r = client.post(f"{BASE_URL}/api/v1/workspace/{slug}/update", headers=headers, json=settings)
    r.raise_for_status()


def upload(client: httpx.Client, headers: dict, slug: str, path: Path, mime: str) -> bool:
    with open(path, "rb") as f:
        r = client.post(
            f"{BASE_URL}/api/v1/document/upload",
            headers=headers,
            files={"file": (path.name, f, mime)},
            data={"addToWorkspaces": slug},
            timeout=TIMEOUT,
        )
    ok = r.status_code == 200 and r.json().get("success")
    if not ok:
        print(f"  !! upload failed for {path.name}: {r.text[:200]}")
    return ok


def ask(client: httpx.Client, headers: dict, slug: str, question: str) -> tuple[str, list[str]]:
    r = client.post(
        f"{BASE_URL}/api/v1/workspace/{slug}/chat",
        headers=headers,
        json={"message": question, "mode": "query"},
        timeout=TIMEOUT,
    )
    r.raise_for_status()
    d = r.json()
    answer = d.get("textResponse", "") or ""
    sources = [s.get("title", "") for s in d.get("sources", [])]
    return answer, sources


UNKNOWN_PATTERNS = re.compile(
    r"不明|見つかり|ありません|no relevant|don't have|情報がない|含まれて|記載されて|記載がない|わかりません|お答えできません|定めない|定めていない"
)


def evaluate(client: httpx.Client, headers: dict, slug: str, cases: list[Case]) -> tuple[int, int]:
    hits, total = 0, len(cases)
    for c in cases:
        answer, sources = ask(client, headers, slug, c.question)
        ok = True
        reason = []
        if c.expect_unknown:
            if not UNKNOWN_PATTERNS.search(answer):
                ok = False
                reason.append("不明応答が期待されたが具体的な回答を返した")
        else:
            if c.expect_any and not any(re.search(p, answer) for p in c.expect_any):
                ok = False
                reason.append(f"期待パターン{c.expect_any}に不一致")
            if c.expect_source_contains:
                if not any(c.expect_source_contains in s for s in sources):
                    ok = False
                    reason.append(f"出典に'{c.expect_source_contains}'を含む文書がない (実際: {sources})")
        mark = "OK" if ok else "NG"
        print(f"[{mark}] {c.question}  ({c.note})")
        if not ok:
            print(f"       -> {'; '.join(reason)}")
            print(f"       回答: {answer[-160:].replace(chr(10), ' ')}")
            print(f"       出典: {sources}")
        else:
            hits += 1
    return hits, total


def main() -> int:
    with httpx.Client() as client:
        try:
            client.get(f"{BASE_URL}/api/ping", timeout=10).raise_for_status()
        except Exception:
            print(f"エラー: {BASE_URL} に到達できません。")
            return 2

        key = api_key_new(client, "precision-eval")
        headers = {"Authorization": f"Bearer {key}"}

        try:
            print("=== 1. 単一文書内の精度（test-hr-manual.txt、冒頭〜末尾・近接数値の区別） ===")
            slug1 = new_workspace(client, headers, "precision-single-doc")
            upload(client, headers, slug1, FIXTURES_DIR / "test-hr-manual.txt", "text/plain")
            time.sleep(5)
            hits1, total1 = evaluate(client, headers, slug1, SINGLE_DOC_CASES)
            client.delete(f"{BASE_URL}/api/v1/workspace/{slug1}", headers=headers)

            print()
            print("=== 2. 複数文書混在時の出典判別精度（4文書を同一ワークスペースに投入、topN=8） ===")
            slug2 = new_workspace(client, headers, "precision-multi-doc")
            update_workspace(client, headers, slug2, topN=8)
            upload(client, headers, slug2, FIXTURES_DIR / "test-policy.txt", "text/plain")
            upload(client, headers, slug2, FIXTURES_DIR / "test-expense.pdf", "application/pdf")
            upload(
                client, headers, slug2, FIXTURES_DIR / "test-attendance.docx",
                "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            )
            upload(client, headers, slug2, FIXTURES_DIR / "test-hr-manual.txt", "text/plain")
            time.sleep(5)
            hits2, total2 = evaluate(client, headers, slug2, MULTI_DOC_CASES)
            client.delete(f"{BASE_URL}/api/v1/workspace/{slug2}", headers=headers)

            print()
            total_hits, total_all = hits1 + hits2, total1 + total2
            print(f"=== 結果: 単一文書 {hits1}/{total1}, 複数文書 {hits2}/{total2}, 合計 {total_hits}/{total_all} ===")
            return 0 if total_hits == total_all else 1
        finally:
            api_key_delete_all(client, headers)


if __name__ == "__main__":
    sys.exit(main())
