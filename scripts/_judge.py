"""_judge.py — `[P]`（命題要素）判定用の LLM-as-judge クライアント（**開発機専用**）。

設計: `docs/COMPLEX_QA_EVAL_SET_DESIGN_2026-07-26.md` §6-2 Layer2 / §6-3 / §6-4
実装計画: `docs/QUALITY_ROADMAP_2026-07-26.md` §4 Phase A S08
作業記録: `docs/JUDGE_MODEL_CALIBRATION_2026-07-26.md`

============================================================================
🔴 配布禁止（最重要）
============================================================================
本モジュールが呼ぶ judge モデルは **評価専用**であり、**顧客配布物に一切含めない**。

- judge は **製品の Ollama（`runtime/docker-compose.yml` の `rag-ollama`）ではなく、
  開発機の別 Ollama**（既定 `http://127.0.0.1:11435` = 評価専用コンテナ）を叩く。
  製品のモデルストア `runtime/ollama-models/` に judge モデルを置いてはならない
  （配布パッケージはこのディレクトリを同梱するため、置いた瞬間に混入事故になる）。
- `docs/MODEL_CARDS.md` / `NOTICE` / `LICENSES/` / `windows-native/` / `scripts/export*.sh`
  には judge モデルを**絶対に追加しない**。
- 製品既定（`gemma4:12b` / `bge-m3` / `bge-reranker-v2-m3`）は本モジュールから一切変更しない。

============================================================================
設計上の約束
============================================================================
1. **Instance-Specific Rubric**: 汎用の「5点満点で評価して」は使わない。
   設問ごと・要素ごとの `claim` と `judge_reference`（原文の該当箇所）を
   その要素専用の採点基準としてプロンプトに埋める。
2. **出力は3値のみ**（OK / PARTIAL / NG）。総合点・5段階評価は出させない。
   既定では PARTIAL を「未達（False）」に倒す（保守側）。
3. **temperature=0・seed固定**。同一入力の再実行が一致することを実測で確認する。
4. **judge が落ちても評価全体は止まらない**。例外・タイムアウト・JSON崩れ・
   evidence 不整合はすべて `verdict=None`（未判定）にして先へ進む。
   `[N]`/`[E]`/`[X]` の決定的採点は judge の可否と完全に独立している。
"""

from __future__ import annotations

import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import httpx  # noqa: E402

from _eval_common import normalize  # noqa: E402

# 開発機の評価専用 Ollama。**製品コンテナ（rag-ollama）の既定ではない**。
JUDGE_URL = os.environ.get("JUDGE_OLLAMA_URL", "http://127.0.0.1:11435")
JUDGE_MODEL = os.environ.get("JUDGE_MODEL", "")
JUDGE_SEED = int(os.environ.get("JUDGE_SEED", "20260726"))
JUDGE_TIMEOUT = float(os.environ.get("JUDGE_TIMEOUT", "180"))

VERDICTS = ("OK", "PARTIAL", "NG")

# --------------------------------------------------------------------------
# プロンプト（Instance-Specific Rubric）
# --------------------------------------------------------------------------
# judge に渡すのは設計書 §6-2 の3点のみ:
#   (a) 判定対象の要素1つ  (b) 被評価回答の全文  (c) gold原文の抜粋
# 総合評価・比較・順位付けはさせない（verbosity/position bias が入る余地を作らない）。
PROMPT = """あなたは日本語文書の採点者です。以下の「採点基準」ただ1点について、
「回答」がその内容を述べているかどうかだけを判定してください。

文章の巧拙・長さ・網羅性・体裁は一切評価しません。採点基準に書かれた1点だけを見ます。
採点基準に書かれていないことが回答に含まれていても、それは減点も加点もしません。

# 設問
{question}

# 採点基準（この設問のこの1点のためだけの基準）
判定したい内容: {claim}
原典の根拠（正解の出所）: {reference}

# 回答（判定対象）
\"\"\"
{answer}
\"\"\"

# 判定
- OK      : 回答が「判定したい内容」を、言い換え・語順違いを含めて明確に述べている
- PARTIAL : 一部しか述べていない、条件付き・曖昧で断定できない
- NG      : 述べていない、または反する内容を述べている

evidence には、判定の根拠となった箇所を**回答から一字一句そのまま**抜き出して書いてください
（要約・言い換え・原典からの引用は禁止。NG のときは空文字）。

次のJSONだけを出力してください。前置き・説明・コードフェンスは書かないこと。
{{"verdict": "OK|PARTIAL|NG", "evidence": "回答からの引用"}}"""


# --- v2 -------------------------------------------------------------------
# v1 の実測（2026-07-26、qwen3:8b・79要素）で見つかった judge の系統的な癖を
# **明示ルールで塞いだ版**。追加したのは次の3点だけで、判定の枠組みは変えていない。
#   (1) 「記載がありません」等の**不記載表明のみの回答を OK にしてしまう**
#       （Q15/Q19 で実際に発生。unanswerable 系の評価が壊れる最悪の誤り）
#   (2) 数値・日付を**近い値で代用して OK にする**（「2025年3月末」で「3月24日」を OK）
#   (3) 「AとB」を求める基準に対し**片方だけで OK にする**（Q11 で発生）
# ⚠ これらのルールは擬似正解 79 要素の誤りを見て書いたため、
#   同じ79要素で測り直した κ には**過学習方向のバイアスがある**（本書 §5-3 に明記）。
PROMPT_V2 = PROMPT.replace(
    """# 判定
- OK      : 回答が「判定したい内容」を、言い換え・語順違いを含めて明確に述べている
- PARTIAL : 一部しか述べていない、条件付き・曖昧で断定できない
- NG      : 述べていない、または反する内容を述べている""",
    """# 判定
- OK      : 回答が「判定したい内容」を、言い換え・語順違いを含めて明確に述べている
- PARTIAL : 一部しか述べていない、条件付き・曖昧で断定できない
- NG      : 述べていない、または反する内容を述べている

# 判定で必ず守るルール
1. 回答が「記載がありません」「情報は含まれていません」「確認できませんでした」のように
   **不記載を述べているだけ**なら、判定したい内容を述べていないので必ず **NG** とする。
   その回答が正直で立派かどうかは、ここでは一切考慮しない。
2. 判定したい内容に**数値・金額・日付・年度**が含まれる場合、
   **回答に同じ値が明示されている**ときだけ OK とする。
   近い値・丸めた値・範囲での言い換え（例:「3月24日」に対する「3月末」）は OK にしない（PARTIAL）。
3. 判定したい内容が**2つ以上の項目の対比や列挙**（「AとB」「A vs B」）である場合、
   **すべて揃って初めて OK**。片方だけなら PARTIAL。
4. 回答が別の話題について正しいことを述べていても、
   判定したい内容を述べていなければ NG。関連していることは加点しない。""")

PROMPTS = {"v1": PROMPT, "v2": PROMPT_V2}


def build_prompt(question: str, claim: str, reference: str, answer: str,
                 version: str = "v1") -> str:
    return PROMPTS[version].format(
        question=question, claim=claim,
        reference=reference or "（原典の抜粋なし。設問と判定内容のみで判断すること）",
        answer=answer)


# --------------------------------------------------------------------------
# Ollama /api/generate 直叩き（AnythingLLM は経由しない＝ロードマップ S08 の指定）
# --------------------------------------------------------------------------

def _extract_json(raw: str) -> dict | None:
    s = re.sub(r"<think>.*?</think>", "", raw, flags=re.S).strip()
    s = re.sub(r"^```(?:json)?|```$", "", s.strip(), flags=re.M).strip()
    try:
        return json.loads(s)
    except Exception:
        pass
    m = re.search(r"\{.*\}", s, flags=re.S)
    if m:
        try:
            return json.loads(m.group(0))
        except Exception:
            return None
    return None


def generate(client: httpx.Client, model: str, prompt: str,
             url: str = "", seed: int = JUDGE_SEED) -> dict:
    """Ollama `/api/generate` を1回叩く。失敗しても例外を投げず dict を返す。"""
    base = url or JUDGE_URL
    body = {
        "model": model,
        "prompt": prompt,
        "stream": False,
        "format": "json",       # JSON 強制（ゆるいパースに頼らない）
        "think": False,         # 思考モデル（qwen3系）の <think> を止める
        "options": {
            "temperature": 0,
            "seed": seed,
            "top_p": 1.0,
            "top_k": 1,
            "num_predict": 300,
            "num_ctx": 8192,
        },
    }
    try:
        r = client.post(f"{base}/api/generate", json=body, timeout=JUDGE_TIMEOUT)
        r.raise_for_status()
        return {"ok": True, "text": r.json().get("response", "") or ""}
    except Exception as e:                                    # noqa: BLE001
        # think 非対応の古い Ollama 等はここに落ちる。1度だけ think 抜きで再試行。
        if "think" in body:
            body.pop("think")
            try:
                r = client.post(f"{base}/api/generate", json=body, timeout=JUDGE_TIMEOUT)
                r.raise_for_status()
                return {"ok": True, "text": r.json().get("response", "") or ""}
            except Exception as e2:                           # noqa: BLE001
                return {"ok": False, "error": f"{type(e2).__name__}: {e2}"}
        return {"ok": False, "error": f"{type(e).__name__}: {e}"}


def unload(client: httpx.Client, model: str, url: str = "") -> bool:
    """VRAM からモデルを降ろす（keep_alive=0）。失敗は無視して False。"""
    try:
        r = client.post(f"{(url or JUDGE_URL)}/api/generate",
                        json={"model": model, "prompt": "", "keep_alive": 0},
                        timeout=60)
        return r.status_code == 200
    except Exception:                                          # noqa: BLE001
        return False


def available(client: httpx.Client, url: str = "") -> list[str]:
    try:
        r = client.get(f"{(url or JUDGE_URL)}/api/tags", timeout=20)
        r.raise_for_status()
        return [m["name"] for m in r.json().get("models", [])]
    except Exception:                                          # noqa: BLE001
        return []


# --------------------------------------------------------------------------
# 要素1つの判定
# --------------------------------------------------------------------------

def judge_element_llm(client: httpx.Client, model: str, question: str, answer: str,
                      claim: str, reference: str, *, url: str = "",
                      partial_is_hit: bool = False, seed: int = JUDGE_SEED,
                      prompt_version: str = "v1") -> dict:
    """1要素を judge にかける。**例外を外へ出さない**（judge の故障で評価を止めない）。

    戻り値:
      verdict      True / False / None(未判定)
      verdict3     "OK"/"PARTIAL"/"NG"/None
      evidence     回答からの引用（検証済みのもののみ）
      status       "ok" | "evidence_missing" | "bad_json" | "bad_verdict" | "error"
    """
    res = generate(client, model,
                   build_prompt(question, claim, reference, answer, prompt_version),
                   url=url, seed=seed)
    if not res["ok"]:
        return {"verdict": None, "verdict3": None, "evidence": None,
                "status": "error", "detail": res.get("error"), "raw": None}

    raw = res["text"]
    d = _extract_json(raw)
    if not isinstance(d, dict):
        return {"verdict": None, "verdict3": None, "evidence": None,
                "status": "bad_json", "detail": None, "raw": raw[:400]}

    v = str(d.get("verdict", "")).strip().upper()
    if v not in VERDICTS:
        return {"verdict": None, "verdict3": None, "evidence": None,
                "status": "bad_verdict", "detail": v, "raw": raw[:400]}

    ev = str(d.get("evidence", "") or "")
    # judge 自身のハルシネーション検出（設計書 §6-2）:
    # 回答本文に実在しない evidence を返した判定は**無効**にして人手キューに回す。
    if v in ("OK", "PARTIAL"):
        nev, nans = normalize(ev), normalize(answer)
        if not nev or nev not in nans:
            return {"verdict": None, "verdict3": v, "evidence": ev,
                    "status": "evidence_missing", "detail": None, "raw": None}

    hit = (v == "OK") or (partial_is_hit and v == "PARTIAL")
    return {"verdict": bool(hit), "verdict3": v, "evidence": ev or None,
            "status": "ok", "detail": None, "raw": None}


# --------------------------------------------------------------------------
# Cohen's κ
# --------------------------------------------------------------------------

def cohen_kappa(a: list[bool], b: list[bool]) -> dict:
    """2値ラベル2系列の Cohen's κ と混同行列。n=0 のときは κ=None。"""
    n = len(a)
    if n == 0 or len(b) != n:
        return {"n": n, "kappa": None, "po": None, "pe": None,
                "tt": 0, "tf": 0, "ft": 0, "ff": 0, "accuracy": None}
    tt = sum(1 for x, y in zip(a, b) if x and y)
    tf = sum(1 for x, y in zip(a, b) if x and not y)
    ft = sum(1 for x, y in zip(a, b) if not x and y)
    ff = sum(1 for x, y in zip(a, b) if not x and not y)
    po = (tt + ff) / n
    pa1, pb1 = (tt + tf) / n, (tt + ft) / n
    pe = pa1 * pb1 + (1 - pa1) * (1 - pb1)
    kappa = None if pe == 1.0 else (po - pe) / (1 - pe)
    return {"n": n, "kappa": kappa, "po": po, "pe": pe,
            "tt": tt, "tf": tf, "ft": ft, "ff": ff, "accuracy": po}


def kappa_ci(a: list[bool], b: list[bool], iters: int = 2000,
             seed: int = 20260726) -> tuple[float | None, float | None]:
    """ブートストラップによる κ の95%CI（要素単位リサンプル）。"""
    import random
    n = len(a)
    if n == 0:
        return (None, None)
    rnd = random.Random(seed)
    pts = []
    for _ in range(iters):
        idx = [rnd.randrange(n) for _ in range(n)]
        k = cohen_kappa([a[i] for i in idx], [b[i] for i in idx])["kappa"]
        if k is not None:
            pts.append(k)
    if not pts:
        return (None, None)
    pts.sort()
    return (pts[int(0.025 * len(pts))], pts[min(len(pts) - 1, int(0.975 * len(pts)))])
