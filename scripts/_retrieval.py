"""retrieval 観測ハーネス（品質ロードマップ Phase A / S03）。

LLM を一切呼ばずに「検索が gold に到達できているか」を測るための共通層。
run 間のブレが無い決定的な測定軸であり、Phase C〜E の改修効果を最も安く判定できる。

提供するもの
------------
1. `vector_search()` … `POST /api/v1/workspace/{slug}/vector-search` に
   `{query, topN:k, scoreThreshold:0}` を投げ、`results[]` を返す。
   `scoreThreshold=0` は「閾値による切り捨て」と「ランキング性能」を分離して見るため。
2. gold 判定の2方式（設計書 §5-2 / §5-4）
   - **(a) ページ方式**: 取得チャンクの出所ページが `gold ± PAGE_TOLERANCE` に入るか
   - **(b) アンカー方式**: gold ページ本文から採ったアンカー文字列が取得チャンク本文に含まれるか
   両方を実装してあるので、`pageNumber` が使えない環境でも動く。

★ 実装上の重要な事実（2026-07-26 実測）
--------------------------------------
`vector-search` エンドポイント（`anything-llm/server/endpoints/api/workspace/index.js`）は
レスポンスの `metadata` を**ホワイトリストで作り直しており `pageNumber` を落とす**。
（`url/title/author/description/docSource/chunkSource/published/wordCount/tokenCount` のみ）
一方 chat API の `sources[]` には `pageNumber` が入る。
`anything-llm/` を変更しない制約下でページ方式を成立させるため、本モジュールは

  **取得チャンク本文を、投入済みドキュメントJSONのページ索引に照合して出所ページを復元する**

方式を採る（`PageIndex`）。collector が `pageContent` に挿入する改ページマーカー
`\f<n>\f` からページ本文を復元し、チャンクを文単位に割ってページに投票させる。
文抽出クッション（`LANCE_SENTENCE_CUSHION=true`）がチャンク本文を
非連続な文の集合に置き換えるため、**チャンク全体の一致ではなく文単位の多数決**にしてある。
`metadata.pageNumber` が将来返るようになれば、そちらを優先して使う。

ページ番号の系
--------------
- ドキュメント内の物理ページ（`\f<n>\f` の n）= 設計書の「pypdfページ」
- 評価セットの gold は**白書の印字ページ（フッタのノンブル）**で持つ
- 変換は `印字 + PAGE_OFFSET(=10)`。実測で確認済み（実装ログ §0-1）
- チャンク内多数決の性質上 ±1 ずれうるため `PAGE_TOLERANCE=1` を許容する（設計書 §3-3）
"""

from __future__ import annotations

import bisect
import glob
import json
import os
import re

from _eval_common import normalize

BASE_URL = os.environ.get("LOCALRAG_BASE_URL", "http://localhost:3001")
TIMEOUT = 180.0

# 白書の印字ページ → ドキュメント内物理ページ の差分（実測で確定）
PAGE_OFFSET = int(os.environ.get("PAGE_OFFSET", "10"))
# チャンク内多数決によるページのずれ許容（設計書 §3-3 / §5-2）
PAGE_TOLERANCE = int(os.environ.get("PAGE_TOLERANCE", "1"))
# 投入済みドキュメントJSONの探索先（ページ索引の材料）
STORAGE_DOCS = os.environ.get(
    "LOCALRAG_STORAGE_DOCS",
    os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                 "runtime", "anythingllm-storage", "documents"),
)

_META = re.compile(r"<document_metadata>[\s\S]*?</document_metadata>")
_PAGEMARK = re.compile(r"\x0c(\d+)\x0c")
_SENT = re.compile(r"(?<=[。！？])")


# --------------------------------------------------------------------------
# API
# --------------------------------------------------------------------------

def new_api_key(client, name="retrieval-eval") -> str:
    r = client.post(f"{BASE_URL}/api/system/generate-api-key", json={"name": name})
    r.raise_for_status()
    return r.json()["apiKey"]["secret"]


def delete_api_keys(client, headers) -> int:
    """発行済みAPIキーを全削除する（評価実行の後始末）。"""
    r = client.get(f"{BASE_URL}/api/system/api-keys", headers=headers)
    n = 0
    for k in r.json().get("apiKeys", []):
        client.delete(f"{BASE_URL}/api/system/api-key/{k['id']}", headers=headers)
        n += 1
    return n


def vector_search(client, headers, slug: str, query: str, k: int) -> list[dict]:
    """LLM非経由の検索。`{query, topN:k, scoreThreshold:0}` を投げて results を返す。

    戻り値の各要素: `{"rank":int, "text":str, "score":float|None, "page":int|None}`
    `page` は metadata.pageNumber があればそれ、無ければ PageIndex による復元値。
    """
    r = client.post(
        f"{BASE_URL}/api/v1/workspace/{slug}/vector-search",
        headers=headers,
        json={"query": query, "topN": k, "scoreThreshold": 0},
        timeout=TIMEOUT,
    )
    r.raise_for_status()
    out = []
    for i, x in enumerate(r.json().get("results", []), 1):
        md = x.get("metadata") or {}
        out.append({
            "rank": i,
            "text": x.get("text", "") or "",
            "score": x.get("score"),
            "page": md.get("pageNumber"),   # 現行forkでは常に None（上のdocstring参照）
        })
    return out


# --------------------------------------------------------------------------
# ページ索引（チャンク本文 → 出所ページの復元）
# --------------------------------------------------------------------------

class PageIndex:
    """投入済みドキュメントJSONから物理ページ本文を復元し、任意の本文断片の
    出所ページを引けるようにする。決定的でLLM非依存。"""

    def __init__(self, doc_json_path: str):
        self.path = doc_json_path
        raw = json.load(open(doc_json_path, encoding="utf-8"))["pageContent"]
        parts = _PAGEMARK.split(raw)
        pages = {1: parts[0]}
        for i in range(1, len(parts), 2):
            pages[int(parts[i])] = parts[i + 1]
        self.pages = pages
        self._starts: list[int] = []
        self._page_of_start: list[int] = []
        buf, pos = [], 0
        for p in sorted(pages):
            n = normalize(pages[p])
            self._starts.append(pos)
            self._page_of_start.append(p)
            buf.append(n)
            pos += len(n)
        self.full = "".join(buf)

    @classmethod
    def autodetect(cls, storage_docs: str = STORAGE_DOCS) -> "PageIndex":
        """`storage/documents/**/**.json` から改ページマーカーを持つ最大の文書を拾う。"""
        best, best_marks = None, -1
        for f in glob.glob(os.path.join(storage_docs, "**", "*.json"), recursive=True):
            try:
                pc = json.load(open(f, encoding="utf-8")).get("pageContent", "")
            except Exception:
                continue
            m = len(_PAGEMARK.findall(pc))
            if m > best_marks:
                best, best_marks = f, m
        if best is None or best_marks <= 0:
            raise FileNotFoundError(
                f"改ページマーカー付きの文書JSONが {storage_docs} に見つかりません。"
                " 白書PDFが現行イメージで投入済みか確認すること。")
        return cls(best)

    def _page_at(self, idx: int) -> int:
        return self._page_of_start[bisect.bisect_right(self._starts, idx) - 1]

    def locate(self, text: str) -> tuple[int | None, dict[int, int]]:
        """チャンク本文の出所ページを推定する。

        クッションで非連続な文集合になっていても効くよう、文単位に割って
        「一致した文字数」で多数決する。戻り値は (推定ページ, 投票内訳)。
        """
        body = _META.sub(" ", text or "")
        votes: dict[int, int] = {}
        for s in _SENT.split(body):
            n = normalize(s)
            if len(n) < 12:          # 短すぎる断片は偶然一致するので使わない
                continue
            i = self.full.find(n)
            if i >= 0:
                p = self._page_at(i)
                votes[p] = votes.get(p, 0) + len(n)
        if not votes:
            n = normalize(body)
            if len(n) >= 12:
                i = self.full.find(n)
                if i >= 0:
                    return self._page_at(i), {self._page_at(i): len(n)}
            return None, {}
        return max(votes, key=votes.get), votes

    def count(self, needle: str) -> int:
        """正規化後の全文出現回数（unanswerable の非存在立証の再検証用）。"""
        return self.full.count(normalize(needle))

    def pages_containing(self, needle: str) -> list[int]:
        n = normalize(needle)
        return [p for p in sorted(self.pages) if n in normalize(self.pages[p])]


# --------------------------------------------------------------------------
# gold 判定
# --------------------------------------------------------------------------

def to_physical(printed_page: int) -> int:
    """白書の印字ページ → ドキュメント内物理ページ。"""
    return printed_page + PAGE_OFFSET


def annotate(results: list[dict], index: PageIndex | None) -> list[dict]:
    """results の各要素に出所ページ（`page`）を埋める。既に入っていれば尊重する。"""
    for r in results:
        if r.get("page") is None and index is not None:
            r["page"], r["page_votes"] = index.locate(r["text"])
    return results


def page_hits(results: list[dict], gold_printed_pages) -> dict:
    """ページ方式の判定。gold は**印字ページ**で渡す。

    戻り値: {"covered": [印字ページ...], "first_rank": int|None, "ranks": {印字ページ: rank}}
    """
    ranks: dict[int, int] = {}
    for g in gold_printed_pages:
        target = to_physical(int(g))
        for r in results:
            p = r.get("page")
            if p is not None and abs(int(p) - target) <= PAGE_TOLERANCE:
                ranks.setdefault(int(g), r["rank"])
                break
    first = min(ranks.values()) if ranks else None
    return {"covered": sorted(ranks), "first_rank": first, "ranks": ranks}


def anchor_hits(results: list[dict], anchors) -> dict:
    """アンカー方式の判定。`metadata.pageNumber` の実装状況に依存しない。

    戻り値: {"covered": [anchor...], "first_rank": int|None, "ranks": {anchor: rank}}
    """
    norm = [(a, normalize(a)) for a in anchors]
    texts = [(r["rank"], normalize(r["text"])) for r in results]
    ranks: dict[str, int] = {}
    for a, na in norm:
        if not na:
            continue
        for rank, t in texts:
            if na in t:
                ranks.setdefault(a, rank)
                break
    first = min(ranks.values()) if ranks else None
    return {"covered": sorted(ranks), "first_rank": first, "ranks": ranks}


# --------------------------------------------------------------------------
# 指標（設計書 §5-3）
# --------------------------------------------------------------------------

def dcg(rels: list[float]) -> float:
    import math
    return sum(rel / math.log2(i + 2) for i, rel in enumerate(rels))


def ndcg_at_k(results: list[dict], gold_weighted: dict[int, int], k: int) -> float:
    """weight(2=必須/1=補助) を relevance とした nDCG@k。gold は印字ページ。

    取得順に relevance を並べ、理想順序（weight降順）と比較する。
    同じ gold ページを複数チャンクが指した場合、2つ目以降の relevance は 0 とする
    （同一ページの重複取得を利得として数えない）。
    """
    seen: set[int] = set()
    rels: list[float] = []
    for r in results[:k]:
        p = r.get("page")
        rel = 0.0
        if p is not None:
            for g, w in gold_weighted.items():
                if abs(int(p) - to_physical(int(g))) <= PAGE_TOLERANCE and g not in seen:
                    rel = float(w)
                    seen.add(g)
                    break
        rels.append(rel)
    ideal = sorted((float(w) for w in gold_weighted.values()), reverse=True)[:k]
    idcg = dcg(ideal)
    return (dcg(rels) / idcg) if idcg > 0 else 0.0
