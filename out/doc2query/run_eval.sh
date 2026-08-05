#!/usr/bin/env bash
# 経路B（索引時の仮想質問生成）の評価。
# 事前登録: docs/PREREG_DOC2QUERY_2026-08-06.md
#
# 条件C（フィルタあり）のみ測定する。条件B（フィルタなし）は
# 時間の都合で省いた（事前登録 §10-1 に逸脱として記録済み）。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
OUT=out/doc2query; INJ_HOST="$PWD/$OUT/inject.jsonl"; INJ="/d2q/inject.jsonl"
SLUG=d2q-granite
C=$(docker ps -qf name=rag-ollama|head -1)
N=$(docker inspect "$C" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$v.IPAddress}}{{end}}')

[ -s "$INJ_HOST" ] || { echo "エラー: $INJ_HOST が無い（フィルタ未完）" >&2; exit 1; }
echo "注入ファイル: $(wc -l < "$INJ_HOST") チャンク分"

# 🔴 前条件のベクトルが再利用されると測定が無意味になる（2026-08-05 に実際に発生）
rm -rf runtime/anythingllm-storage/vector-cache/*
rm -rf "runtime/anythingllm-storage/lancedb/${SLUG}.lance" \
       "runtime/anythingllm-storage/lancedb/__oterag_fts__v2_${SLUG}.lance"

echo "=== コンテナを再作成（DOC2QUERY_FILE を渡す）==="
( cd runtime && EMB_MODEL=granite-embedding:278m D2Q="$INJ" \
    docker compose -f docker-compose.yml -f docker-compose.embedding-eval.yml \
    up -d --force-recreate anythingllm >/dev/null 2>&1 )
for i in $(seq 1 60); do curl -sf http://localhost:3001/api/ping >/dev/null 2>&1 && break; sleep 5; done
act=$(docker exec anythingllm printenv DOC2QUERY_FILE 2>/dev/null | tr -d '\r' || echo "")
[ -n "$act" ] || { echo "エラー: DOC2QUERY_FILE がコンテナに渡っていない" >&2; exit 1; }
echo "  DOC2QUERY_FILE=$act"

echo "=== 再 embed（仮想質問つき）==="
DOC='custom-documents/R07zenpen.pdf-5369f462-5cb5-42a7-9dee-c4cb7da65cdd.json'
python3 - "$SLUG" "$DOC" <<'PY'
import json,sys,urllib.request,time
B='http://localhost:3001'; slug,doc=sys.argv[1],sys.argv[2]
def api(p,d=None,m='GET',k=None):
    hd={'Content-Type':'application/json'}
    if k: hd['Authorization']='Bearer '+k
    r=urllib.request.Request(B+p,data=json.dumps(d).encode() if d else None,headers=hd,method=m)
    return json.load(urllib.request.urlopen(r,timeout=7200))
k=api('/api/system/generate-api-key',{'name':'d2q'},'POST')['apiKey']['secret']
try: api('/api/v1/workspace/new',{'name':slug},'POST',k)
except Exception: pass
t0=time.time(); api(f'/api/v1/workspace/{slug}/update-embeddings',{'adds':[doc]},'POST',k)
print(f'  再embed {time.time()-t0:.0f}秒')
PY

# 注入が本当に効いたかをログで確認する（効いていなければ測定は無意味）
if ! docker logs anythingllm 2>&1 | grep -q 'Doc2Query. loaded'; then
  echo "エラー: 注入が読み込まれていない（[Doc2Query] loaded が出ていない）" >&2; exit 1
fi
docker logs anythingllm 2>&1 | grep 'Doc2Query' | tail -1
if docker logs anythingllm 2>&1 | tail -80 | grep -q 'Using cached data'; then
  echo "エラー: 前条件のベクトルが再利用された。測定は無効" >&2; exit 1
fi

echo "=== 166問の生成 ==="
HAKUSHO_SLUG="$SLUG" uv run scripts/complex-eval.py --phase generate \
  --run d2q --chat-model granite4.1:8b --top-n 8 \
  --out "$OUT/gen-d2q.json" > "$OUT/gen-eval.log" 2>&1

echo "=== 判定（[X] は LLM 二次判定つき）==="
JUDGE_OLLAMA_URL="http://$N:11434" uv run scripts/complex-eval.py --phase judge \
  --in "$OUT/gen-d2q.json" --judge-model gemma4:12b --judge-url "http://$N:11434" \
  --out "$OUT/judged-d2q.json" > "$OUT/judge-eval.log" 2>&1
echo "完了: $(date '+%H:%M:%S')"
