#!/usr/bin/env python3
"""OTE-RAG の TTFT 実測。製品の stream-chat 経路（SSE）でクライアント側 TTFT を測り、
コンテナログの [TTFT_FIRST]/[TTFT_DONE] と突き合わせて段別内訳を得る。

使い方:
  python3 ttft_measure.py <slug> <out.json> [n] [topN]
"""
import json, os, sys, time, uuid, subprocess, urllib.request

BASE = os.environ.get("LOCALRAG_BASE_URL", "http://localhost:3001")
QA = "/home/ishihara1447/projects/fukugyo/repos/localRAG/fixtures/complex/hakusho-complex-qa.json"


def api_key():
    req = urllib.request.Request(
        f"{BASE}/api/system/generate-api-key",
        data=json.dumps({"name": "ttft-" + uuid.uuid4().hex[:6]}).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    return json.load(urllib.request.urlopen(req))["apiKey"]["secret"]


def pick(n):
    cases = json.load(open(QA, encoding="utf-8"))["cases"]
    # カテゴリを跨いで等間隔に取る（決定的）
    step = max(1, len(cases) // n)
    return [cases[i] for i in range(0, len(cases), step)][:n]


def stream_ask(key, slug, question, session, timeout=600):
    """SSE を読み、最初の非空 textResponse が届くまでの時間(TTFT)と総時間を返す。"""
    req = urllib.request.Request(
        f"{BASE}/api/v1/workspace/{slug}/stream-chat",
        data=json.dumps(
            {"message": question, "mode": "query", "sessionId": session}
        ).encode(),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {key}",
            "Accept": "text/event-stream",
        },
        method="POST",
    )
    t0 = time.time()
    ttft = None
    text = []
    with urllib.request.urlopen(req, timeout=timeout) as r:
        buf = b""
        for raw in r:
            buf += raw
            while b"\n\n" in buf:
                block, buf = buf.split(b"\n\n", 1)
                for line in block.decode("utf-8", "replace").split("\n"):
                    if not line.startswith("data: "):
                        continue
                    try:
                        ev = json.loads(line[6:])
                    except Exception:
                        continue
                    tr = ev.get("textResponse") or ""
                    if tr and ttft is None:
                        ttft = time.time() - t0
                    if tr:
                        text.append(tr)
    return {
        "client_ttft_s": None if ttft is None else round(ttft, 3),
        "client_total_s": round(time.time() - t0, 3),
        "answer_chars": len("".join(text)),
        "answer_head": "".join(text)[:120],
    }


def container_logs(since):
    out = subprocess.run(
        ["docker", "logs", "anythingllm", "--since", since],
        capture_output=True,
        text=True,
    )
    rows = {"first": [], "done": []}
    for line in (out.stdout + out.stderr).splitlines():
        for tag, k in (("[TTFT_FIRST] ", "first"), ("[TTFT_DONE] ", "done")):
            if tag in line:
                try:
                    rows[k].append(json.loads(line.split(tag, 1)[1]))
                except Exception:
                    pass
    return rows


def main():
    slug = sys.argv[1]
    out_path = sys.argv[2]
    n = int(sys.argv[3]) if len(sys.argv) > 3 else 24
    topn = sys.argv[4] if len(sys.argv) > 4 else None

    key = api_key()
    if topn:
        req = urllib.request.Request(
            f"{BASE}/api/v1/workspace/{slug}/update",
            data=json.dumps({"topN": int(topn), "openAiTemp": 0}).encode(),
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {key}",
            },
            method="POST",
        )
        urllib.request.urlopen(req).read()
        print(f"(topN={topn}, temperature=0)")

    run = uuid.uuid4().hex[:8]
    cases = pick(n)
    # ウォームアップ1回（モデルロード・FTSインデックスopenを計測から外す）
    print("warmup...")
    stream_ask(key, slug, "統合作戦司令部はいつ新設されましたか。", f"warm-{run}")

    results = []
    for i, c in enumerate(cases, 1):
        since = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(time.time() - 2))
        sid = f"ttft-{run}-{i:02d}"
        t = stream_ask(key, slug, c["question"], sid)
        logs = container_logs(since)
        srv_first = logs["first"][-1] if logs["first"] else {}
        srv_done = logs["done"][-1] if logs["done"] else {}
        row = {
            "no": i,
            "id": c["id"],
            "category": c["category"],
            "question": c["question"],
            "session": sid,
            **t,
            "server_first": srv_first,
            "server_done": srv_done,
        }
        results.append(row)
        print(
            f"[{i:02d}] {c['id']} TTFT={t['client_ttft_s']}s total={t['client_total_s']}s "
            f"srv_first={srv_first.get('s7_first_token_ms')}ms "
            f"pe={srv_done.get('o_prompt_eval_ms')}ms/{srv_done.get('o_prompt_eval_count')}tok"
        )
    json.dump(
        {"slug": slug, "run": run, "topN": topn, "n": len(results), "cases": results},
        open(out_path, "w", encoding="utf-8"),
        ensure_ascii=False,
        indent=1,
    )
    print("wrote", out_path)


if __name__ == "__main__":
    main()
