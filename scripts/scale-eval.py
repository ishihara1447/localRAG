# /// script
# requires-python = ">=3.10"
# dependencies = ["httpx>=0.27"]
# ///
"""scale-eval.py — LocalRAGの「実運用規模」での検索・回答精度を評価する。

precision-eval.py が小型文書4つでの基礎精度を見るのに対し、このスクリプトは
士業事務所の実運用（数十の規程・契約書を1ワークスペースに投入）を模した
負荷条件で精度を測る。fixtures/scale/ の互いに紛らわしい社内規程10本
（就業規則・賃金・退職金・育児介護・出張旅費・慶弔見舞金・個人情報・
文書管理・安全衛生・ハラスメント防止）をすべて同一ワークスペースに入れ、
30問を4カテゴリで評価する:

  (a) 単一規程内の事実 10問 — 各規程1問ずつ。正しい出典ファイルまで検証。
  (b) 紛らわしい数値の判別 10問 — 「申請は◯日前まで」「◯◯円」「施行日」など、
      複数規程に類似の数値が存在する質問。他規程の数値に引っ張られないか。
  (c) どの規程にも無い情報 5問 — 不明応答を期待（ハルシネーション検出）。
  (d) 言い換え・同義語質問 5問 — 文書の語彙を使わずに聞く（例:「ホテル代」→「宿泊料」）。

使い方:
  uv run scripts/scale-eval.py            # ワークスペース既定のtopNのまま
  uv run scripts/scale-eval.py --top-n 12 # topNを変えて比較実行

環境変数:
  LOCALRAG_BASE_URL (既定 http://localhost:3001)

このスクリプト自体がAPIキーを発行・削除するため、事前のキー発行は不要。
回答に <think>...</think> ブロックが含まれる場合は判定前に除去する。
"""

from __future__ import annotations

import argparse
import os
import re
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

import httpx

BASE_URL = os.environ.get("LOCALRAG_BASE_URL", "http://localhost:3001")
SCALE_DIR = Path(__file__).resolve().parent.parent / "fixtures" / "scale"
TIMEOUT = 180.0

FIXTURE_FILES = [
    "reg-01-shugyo-kisoku.txt",
    "reg-02-chingin.txt",
    "reg-03-taishokukin.txt",
    "reg-04-ikuji-kaigo.txt",
    "reg-05-shutcho-ryohi.txt",
    "reg-06-keicho-mimaikin.txt",
    "reg-07-kojin-joho.txt",
    "reg-08-bunsho-kanri.txt",
    "reg-09-anzen-eisei.txt",
    "reg-10-harassment.txt",
]

CATEGORY_LABELS = {
    "a": "a) 単一規程内の事実",
    "b": "b) 紛らわしい数値の判別",
    "c": "c) 規程に無い情報（不明応答）",
    "d": "d) 言い換え・同義語質問",
}


@dataclass
class Case:
    category: str  # "a" / "b" / "c" / "d"
    question: str
    # 回答本文が満たすべき正規表現（いずれか1つでも合致すればOK）。
    expect_any: list[str] = field(default_factory=list)
    # 出典として含まれるべきファイル名の部分文字列（Noneならチェックしない）
    expect_source_contains: str | None = None
    expect_unknown: bool = False
    note: str = ""


# 正規表現は全角/半角スペース・表記ゆれ（ヶ/か/カ月、カンマ有無、％/%等）を許容する。
CASES = [
    # ===== (a) 単一規程内の事実 10問（各規程1問、出典ファイルまで検証） =====
    Case("a", "従業員の定年は何歳ですか？",
         [r"65[\s　]*歳"],
         expect_source_contains="reg-01", note="就業規則 第11条: 満65歳"),
    Case("a", "時間外労働が1ヶ月60時間を超えた部分の割増賃金率は何パーセントですか？",
         [r"50[\s　]*(％|%|パーセント)|5[\s　]*割"],
         expect_source_contains="reg-02", note="賃金規程 第5条: 50%（25/35/50の判別）"),
    Case("a", "自己都合で退職した場合、退職金は算定額の何パーセントになりますか？",
         [r"70[\s　]*(％|%|パーセント)|7[\s　]*割"],
         expect_source_contains="reg-03", note="退職金規程 第5条: 70%"),
    Case("a", "小学校就学前の子が1人の場合、子の看護休暇は年に何日まで取得できますか？",
         [r"5[\s　]*日"],
         expect_source_contains="reg-04", note="育児・介護休業規程 第6条: 5日（2人以上は10日）"),
    Case("a", "海外出張の日当は1日いくらですか？",
         [r"4,?500[\s　]*円"],
         expect_source_contains="reg-05", note="出張旅費規程 第7条: 4,500円（国内2,500円との判別）"),
    Case("a", "結婚祝金はいくら支給されますか？",
         [r"30,?000[\s　]*円|3[\s　]*万[\s　]*円"],
         expect_source_contains="reg-06", note="慶弔見舞金規程 第3条: 30,000円"),
    Case("a", "個人情報保護管理者にはどの役職の者が就きますか？",
         [r"管理部長"],
         expect_source_contains="reg-07", note="個人情報管理規程 第3条: 管理部長（文書管理責任者=総務部長との判別）"),
    Case("a", "決算書類や経理帳簿の保存年限は何年ですか？",
         [r"10[\s　]*年"],
         expect_source_contains="reg-08", note="文書管理規程 第4条: 10年（永久/10/5/3年の判別）"),
    Case("a", "安全衛生委員会はどのくらいの頻度で開催されますか？",
         [r"毎月|月[\s　]*に?[\s　]*1[\s　]*回"],
         expect_source_contains="reg-09", note="安全衛生管理規程 第3条: 毎月1回"),
    Case("a", "ハラスメントの調査委員会は何名以上の委員で構成されますか？",
         [r"3[\s　]*名|3[\s　]*人"],
         expect_source_contains="reg-10", note="ハラスメント防止規程 第6条: 委員長を含む3名以上"),

    # ===== (b) 紛らわしい数値の判別 10問（他規程の類似数値に引っ張られないか） =====
    Case("b", "出張の申請は出発日の何日前までに行う必要がありますか？",
         [r"3[\s　]*営業日|3[\s　]*日"],
         expect_source_contains="reg-05",
         note="出張旅費 第3条: 3営業日前（文書持出5営業日前・育休1ヶ月前との判別）"),
    Case("b", "慶弔見舞金の申請は、事由発生日から何日以内にしなければなりませんか？",
         [r"14[\s　]*日|2[\s　]*週間"],
         expect_source_contains="reg-06",
         note="慶弔見舞金 第8条: 14日以内（出張精算7日以内・退職願30日前との判別）"),
    Case("b", "育児休業の申出は、休業開始予定日のどれくらい前までに行いますか？",
         [r"1[\s　]*(ヶ|か|カ|ケ|箇)?[\s　]*月"],
         expect_source_contains="reg-04",
         note="育児・介護休業 第3条: 1ヶ月前（介護休業2週間前との判別）"),
    Case("b", "介護休業の申出は、休業開始予定日のどれくらい前までに行いますか？",
         [r"2[\s　]*週間"],
         expect_source_contains="reg-04",
         note="育児・介護休業 第5条: 2週間前（育休1ヶ月前との判別）"),
    Case("b", "文書を社外に持ち出すときは、何日前までに申請が必要ですか？",
         [r"5[\s　]*営業日|5[\s　]*日"],
         expect_source_contains="reg-08",
         note="文書管理 第6条: 5営業日前（出張申請3営業日前との判別）"),
    Case("b", "国内出張の日当は1日いくらですか？",
         [r"2,?500[\s　]*円"],
         expect_source_contains="reg-05",
         note="出張旅費 第5条: 2,500円（海外4,500円・見舞金10,000円との判別）"),
    Case("b", "文書管理規程はいつから施行されていますか？",
         [r"2022[\s　]*年[\s　]*4[\s　]*月|2022[-/.]0?4"],
         expect_source_contains="reg-08",
         note="文書管理 附則: 2022年4月1日（10規程それぞれ異なる施行日の判別）"),
    Case("b", "自己都合で退職するときは、退職予定日の何日前までに退職願を提出しますか？",
         [r"30[\s　]*日"],
         expect_source_contains="reg-01",
         note="就業規則 第10条: 30日前（慶弔14日以内・口座変更10日前との判別）"),
    Case("b", "個人情報の漏えいを発見した場合、何時間以内に報告しなければなりませんか？",
         [r"24[\s　]*時間"],
         expect_source_contains="reg-07",
         note="個人情報 第9条: 24時間以内（開示対応2週間との判別）"),
    Case("b", "ハラスメントの相談を受け付けてから、何営業日以内に調査を開始しますか？",
         [r"10[\s　]*営業日|10[\s　]*日"],
         expect_source_contains="reg-10",
         note="ハラスメント 第5条: 10営業日以内（賃金の口座変更10日前との判別）"),

    # ===== (c) どの規程にも無い情報 5問（不明応答を期待） =====
    Case("c", "社用車を利用するときの手続きはどう定められていますか？",
         [], expect_unknown=True, note="社用車の定めはどの規程にも無い"),
    Case("c", "副業・兼業を行う場合の許可基準を教えてください。",
         [], expect_unknown=True, note="副業・兼業の定めはどの規程にも無い"),
    Case("c", "転勤するときの赴任旅費はいくら支給されますか？",
         [], expect_unknown=True,
         note="出張旅費規程 第10条が明示的に「本規程には定めない」とする罠"),
    Case("c", "ストックオプションの付与条件はどうなっていますか？",
         [], expect_unknown=True, note="株式報酬の定めはどの規程にも無い"),
    Case("c", "社員食堂の利用料金はいくらですか？",
         [], expect_unknown=True, note="社員食堂の定めはどの規程にも無い"),

    # ===== (d) 言い換え・同義語質問 5問（文書の語彙を使わずに聞く） =====
    Case("d", "配偶者に先立たれた場合、会社からいくら支給されますか？",
         [r"50,?000[\s　]*円|5[\s　]*万[\s　]*円"],
         expect_source_contains="reg-06",
         note="慶弔見舞金 第5条: 死亡弔慰金（配偶者）50,000円。「先立たれた」は文書に無い語彙"),
    Case("d", "給料は毎月何日に振り込まれますか？",
         [r"28[\s　]*日"],
         expect_source_contains="reg-02",
         note="賃金規程 第3条: 当月28日支払。「振り込まれる」は支払日の言い換え"),
    Case("d", "泊まりがけの国内出張で、ホテル代はいくらまで出ますか？",
         [r"9,?000[\s　]*円"],
         expect_source_contains="reg-05",
         note="出張旅費 第6条: 宿泊料上限9,000円。「ホテル代」は文書に無い語彙"),
    Case("d", "上司からしつこい嫌がらせを受けています。どこに相談すればよいですか？",
         [r"人事部|社外|外部|相談窓口"],
         expect_source_contains="reg-10",
         note="ハラスメント 第4条: 相談窓口は人事部および社外専門機関"),
    Case("d", "会社が持っている自分のデータを見せてほしい場合、どのくらいの期間で対応してもらえますか？",
         [r"2[\s　]*週間|14[\s　]*日"],
         expect_source_contains="reg-07",
         note="個人情報 第10条: 開示請求に受付から2週間以内に対応。「自分のデータ」は開示請求の言い換え"),
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


def strip_think(text: str) -> str:
    """推論モデルの <think>...</think> ブロックを判定対象から除去する。"""
    return re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL).strip()


UNKNOWN_PATTERNS = re.compile(
    r"不明|見つかり|ありません|no relevant|don't have|情報がない|含まれて|記載されて"
    r"|記載がない|わかりません|お答えできません|定めない|定めていない|定められていない|別に定める"
)


def evaluate(client: httpx.Client, headers: dict, slug: str, cases: list[Case]) -> dict[str, tuple[int, int]]:
    results: dict[str, tuple[int, int]] = {k: (0, 0) for k in CATEGORY_LABELS}
    for c in cases:
        raw_answer, sources = ask(client, headers, slug, c.question)
        answer = strip_think(raw_answer)
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
        print(f"[{mark}] ({c.category}) {c.question}  ({c.note})")
        if not ok:
            print(f"       -> {'; '.join(reason)}")
            print(f"       回答: {answer[-200:].replace(chr(10), ' ')}")
            print(f"       出典: {sources}")
        hits, total = results[c.category]
        results[c.category] = (hits + (1 if ok else 0), total + 1)
    return results


def main() -> int:
    parser = argparse.ArgumentParser(description="LocalRAG 実運用規模の精度評価（規程10本・30問）")
    parser.add_argument(
        "--top-n", type=int, default=None, metavar="N",
        help="ワークスペースのtopN（検索で参照するチャンク数）。省略時はワークスペースの既定値のまま。",
    )
    parser.add_argument(
        "--chat-model", type=str, default=None, metavar="MODEL",
        help="ワークスペースのchatModel（LLM比較用。例: qwen3:8b）。省略時は環境既定のまま。",
    )
    parser.add_argument(
        "--system-prompt-file", type=str, default=None, metavar="PATH",
        help="ワークスペースのopenAiPrompt（システムプロンプト）をこのファイル内容で上書きする。プロンプト調整の比較用。省略時は既定プロンプト。",
    )
    args = parser.parse_args()

    system_prompt = None
    if args.system_prompt_file is not None:
        p = Path(args.system_prompt_file)
        if not p.exists():
            print(f"エラー: system-prompt-file が見つかりません: {p}")
            return 2
        system_prompt = p.read_text(encoding="utf-8")

    missing = [f for f in FIXTURE_FILES if not (SCALE_DIR / f).exists()]
    if missing:
        print(f"エラー: fixtureが見つかりません: {missing}")
        print("fixtures/scale/ に規程10本の .txt が必要です。")
        return 2

    with httpx.Client() as client:
        try:
            client.get(f"{BASE_URL}/api/ping", timeout=10).raise_for_status()
        except Exception:
            print(f"エラー: {BASE_URL} に到達できません。")
            return 2

        key = api_key_new(client, "scale-eval")
        headers = {"Authorization": f"Bearer {key}"}

        try:
            topn_desc = f"topN={args.top_n}" if args.top_n is not None else "topN=ワークスペース既定値"
            model_desc = f", chatModel={args.chat_model}" if args.chat_model else ""
            print(f"=== 実運用規模評価: 規程10本を同一ワークスペースに投入（{topn_desc}{model_desc}） ===")
            slug = new_workspace(client, headers, "scale-eval")
            if args.top_n is not None:
                update_workspace(client, headers, slug, topN=args.top_n)
            if args.chat_model is not None:
                update_workspace(client, headers, slug, chatProvider="ollama", chatModel=args.chat_model)
            if system_prompt is not None:
                update_workspace(client, headers, slug, openAiPrompt=system_prompt)
            for name in FIXTURE_FILES:
                upload(client, headers, slug, SCALE_DIR / name, "text/plain")
            time.sleep(10)

            results = evaluate(client, headers, slug, CASES)
            client.delete(f"{BASE_URL}/api/v1/workspace/{slug}", headers=headers)

            print()
            print("=== カテゴリ別内訳 ===")
            total_hits, total_all = 0, 0
            for cat, label in CATEGORY_LABELS.items():
                hits, total = results[cat]
                total_hits += hits
                total_all += total
                print(f"  {label}: {hits}/{total}")
            print(f"=== 合計: {total_hits}/{total_all}（{topn_desc}） ===")
            return 0 if total_hits == total_all else 1
        finally:
            api_key_delete_all(client, headers)


if __name__ == "__main__":
    sys.exit(main())
