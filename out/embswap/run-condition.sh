#!/usr/bin/env bash
# 埋め込み条件を1つ立ち上げ、再埋め込み→検索評価まで通す。
#   使い方: run-condition.sh <slug> <model> [query_prefix] [chunk_prefix]
#
# 🔴 vector-cache を必ず消すこと。消さないと前条件のベクトルが再利用され、
#    「候補が対照と完全に同一」という無意味な結果が出る（2026-08-05 に実際に発生）。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
SLUG="$1"; MODEL="$2"; QP="${3:-}"; CP="${4:-}"
OUT=out/embswap/raw; mkdir -p "$OUT"
DOC='custom-documents/R07zenpen.pdf-5369f462-5cb5-42a7-9dee-c4cb7da65cdd.json'

echo "=== $SLUG ($MODEL) query='$QP' chunk='$CP' ==="

# 1. 前条件のベクトルとキャッシュを消す
rm -rf runtime/anythingllm-storage/vector-cache/*
rm -rf "runtime/anythingllm-storage/lancedb/${SLUG}.lance" \
       "runtime/anythingllm-storage/lancedb/__oterag_fts__v2_${SLUG}.lance"

# 2. その埋め込みモデルでコンテナを立て直す
( cd runtime && EMB_MODEL="$MODEL" EMB_QUERY_PREFIX="$QP" EMB_CHUNK_PREFIX="$CP" \
    docker compose -f docker-compose.yml -f docker-compose.embedding-eval.yml up -d --force-recreate anythingllm >/dev/null 2>&1 )
for i in $(seq 1 60); do
  curl -sf http://localhost:3001/api/ping >/dev/null 2>&1 && break
  sleep 5
done

# 3. 設定が実際に効いているか確認（効いていなければ止める）
ACT=$(docker exec anythingllm printenv EMBEDDING_MODEL_PREF | tr -d '\r')
[ "$ACT" = "$MODEL" ] || { echo "エラー: EMBEDDING_MODEL_PREF が $ACT（期待 $MODEL）" >&2; exit 1; }

python3 - "$SLUG" "$DOC" <<'PY'
import json,sys,urllib.request,time
B='http://localhost:3001'; slug,doc=sys.argv[1],sys.argv[2]
def api(p,d=None,m='GET',k=None):
    hd={'Content-Type':'application/json'}
    if k: hd['Authorization']='Bearer '+k
    r=urllib.request.Request(B+p,data=json.dumps(d).encode() if d else None,headers=hd,method=m)
    return json.load(urllib.request.urlopen(r,timeout=7200))
k=api('/api/system/generate-api-key',{'name':'embrun'},'POST')['apiKey']['secret']
try: api('/api/v1/workspace/new',{'name':slug},'POST',k)
except Exception: pass
t0=time.time(); api(f'/api/v1/workspace/{slug}/update-embeddings',{'adds':[doc]},'POST',k)
print(f'  再埋め込み {time.time()-t0:.0f}秒')
PY

# 4. キャッシュ再利用が起きていないことをログで確認（起きていたら測定は無効）
if docker logs anythingllm 2>&1 | tail -50 | grep -q 'Using cached data'; then
  echo "エラー: 前条件のベクトルが再利用された。測定は無効。" >&2; exit 1
fi

# 5. 検索評価
HAKUSHO_SLUG="$SLUG" uv run scripts/complex-eval.py --phase retrieval \
  --out "$OUT/retrieval-$SLUG.json" > "$OUT/retrieval-$SLUG.log" 2>&1
echo "  完了: $OUT/retrieval-$SLUG.json"
