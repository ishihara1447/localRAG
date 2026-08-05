#!/usr/bin/env python3
"""索引時の仮想質問生成（Doc2Query--）— 生成フェーズ。

事前登録: docs/PREREG_DOC2QUERY_2026-08-06.md（sha256 7d5db2ce…）

各チャンクについて「そのチャンクが答えになる質問」を3件生成する。
生成だけで、フィルタは別スクリプト（filter_questions.py）で行う。

🔴 一次調査（RESEARCH_INFERENCE_ABSTENTION_2026-07-28.md §A-5）の反証:
   「生成質問をそのまま全部入れると悪化する。フィルタ必須」
   したがって本スクリプトの出力をそのまま索引に載せてはならない。
"""
import json
import glob
import re
import sys
import time
import urllib.request

MODEL = "granite4.1:8b"
N_Q = 3


def ollama_url() -> str:
    import subprocess
    cid = subprocess.check_output(
        ["docker", "ps", "-qf", "name=rag-ollama"], text=True).strip().split("\n")[0]
    ip = subprocess.check_output(
        ["docker", "inspect", cid, "--format",
         "{{range $k,$v := .NetworkSettings.Networks}}{{$v.IPAddress}}{{end}}"],
        text=True).strip()
    return f"http://{ip}:11434"


def load_chunks():
    """vector-cache から実際に索引されたチャンク本文を取り出す。

    文書JSONから再分割するのではなく**実際のチャンク**を使う。
    分割条件（chunk_size / overlap / ページマーカー処理）を
    再現しようとすると、ずれた瞬間に実験が無意味になるため。
    """
    f = glob.glob("runtime/anythingllm-storage/vector-cache/*.json")[0]
    d = json.load(open(f, encoding="utf-8"))
    out = []
    for batch in d:
        for item in batch:
            t = item["metadata"].get("text") or ""
            # 埋め込み時に付いた接頭辞と AnythingLLM のメタヘッダを除く
            t = re.sub(r"^title:\s*none\s*\|\s*text:\s*", "", t)
            t = re.sub(r"<document_metadata>.*?</document_metadata>", "", t, flags=re.S)
            t = t.strip()
            if len(t) >= 50:          # 極端に短い断片は質問を作れない
                out.append({"id": item["id"], "text": t})
    return out


PROMPT = """次の文章を読み、その文章が答えになるような日本語の質問を{n}個作ってください。

条件:
- 文章に実際に書かれている内容だけから質問を作ること
- 質問だけを1行に1つ、番号や記号を付けずに出力すること
- 文章に無いことを問う質問は作らないこと

文章:
{text}
"""


def gen(url: str, text: str) -> list[str]:
    body = json.dumps({
        "model": MODEL,
        "prompt": PROMPT.format(n=N_Q, text=text[:1800]),
        "stream": False,
        "options": {"temperature": 0, "num_ctx": 4096},
    }).encode()
    req = urllib.request.Request(url + "/api/generate", data=body,
                                 headers={"Content-Type": "application/json"},
                                 method="POST")
    try:
        r = json.load(urllib.request.urlopen(req, timeout=180))
    except Exception as e:
        return []
    lines = [re.sub(r"^[\s\d\.\-・*]+", "", l).strip()
             for l in (r.get("response") or "").split("\n")]
    return [l for l in lines if l.endswith("？") or l.endswith("?") or l.endswith("か。")][:N_Q]


def main():
    out_path = sys.argv[1] if len(sys.argv) > 1 else "out/doc2query/questions.jsonl"
    url = ollama_url()
    chunks = load_chunks()
    print(f"チャンク {len(chunks)} 件。{MODEL} で各 {N_Q} 問を生成します。", flush=True)
    t0 = time.time()
    with open(out_path, "w", encoding="utf-8") as f:
        for i, c in enumerate(chunks, 1):
            qs = gen(url, c["text"])
            f.write(json.dumps({"id": c["id"], "questions": qs}, ensure_ascii=False) + "\n")
            f.flush()
            if i % 50 == 0:
                el = time.time() - t0
                print(f"  {i}/{len(chunks)}  経過 {el/60:.1f}分  "
                      f"残り推定 {el/i*(len(chunks)-i)/60:.0f}分", flush=True)
    print(f"完了: {out_path}  所要 {(time.time()-t0)/60:.1f}分", flush=True)


main()
