#!/usr/bin/env bash
# rag-e2e-test.sh — RAG パイプラインの End-to-End 検証。
#
# fixtures/test-policy.txt をアップロード → embedding → 出典付き回答 →
# 文書外質問で「不明」応答 → 外部LLM provider拒否 → Swagger docs無効、
# までを自動確認する。
#
# 使い方:
#   LOCALRAG_API_KEY=<APIキー> bash rag-e2e-test.sh
#
# API キー発行: ブラウザ http://localhost:3001 → Settings → API Keys
#
# 前提: LocalRAG が起動済み (bash install.sh / start.sh 完了後)。
#
# 注意: WORKSPACE_DELETION_PROTECTION=1 が有効な環境では、テスト後の
#       後処理(ワークスペース削除)が失敗し、テスト用ワークスペースが
#       残り続ける。これは仕様(顧客ワークスペースの誤削除防止)による
#       ものであり、不要になったテスト用ワークスペースはUIから手動で
#       削除すること。

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_URL="http://localhost:3001"
API_KEY="${LOCALRAG_API_KEY:-}"
WS_NAME="localrag-smoketest"
TIMEOUT=180

# fixture の場所（パッケージ内 fixtures/ またはリポジトリ直下 fixtures/）
FIXTURE=""
for cand in "$SCRIPT_DIR/fixtures/test-policy.txt" \
            "$SCRIPT_DIR/../fixtures/test-policy.txt"; do
  [[ -f "$cand" ]] && { FIXTURE="$cand"; break; }
done

PASS=0; FAIL=0
pass() { echo "  [PASS] $*"; ((PASS++)) || true; }
fail() { echo "  [FAIL] $*"; ((FAIL++)) || true; }

echo "=== LocalRAG RAG E2E テスト ==="

# --- 前提チェック ---
if [[ -z "$API_KEY" ]]; then
  echo "エラー: LOCALRAG_API_KEY が未設定です。"
  echo "  実行例: LOCALRAG_API_KEY=xxxx bash rag-e2e-test.sh"
  echo "  API キー発行: http://localhost:3001 → Settings → API Keys"
  exit 2
fi
if [[ -z "$FIXTURE" ]]; then
  echo "エラー: fixtures/test-policy.txt が見つかりません。"
  exit 2
fi
if ! curl -sf --max-time 10 "$BASE_URL/api/ping" | grep -q '"online":true'; then
  echo "エラー: $BASE_URL に到達できません。サービスが起動していません。"
  exit 2
fi

AUTH=(-H "Authorization: Bearer $API_KEY")

# クリーンアップ用トラップ（テスト用ワークスペースを削除）
WS_SLUG=""
cleanup() {
  if [[ -n "$WS_SLUG" ]]; then
    echo "[後処理] テスト用ワークスペース ($WS_SLUG) を削除中..."
    curl -s --max-time 30 -X DELETE "${AUTH[@]}" \
      "$BASE_URL/api/v1/workspace/$WS_SLUG" >/dev/null 2>&1 \
      || echo "  (削除に失敗。WORKSPACE_DELETION_PROTECTION 有効時は手動削除してください)"
  fi
}
trap cleanup EXIT

# --- 1. ワークスペース作成 ---
echo "[1/6] テスト用ワークスペースを作成中..."
WS_RESP=$(curl -s --max-time 30 -X POST "${AUTH[@]}" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"$WS_NAME\"}" \
  "$BASE_URL/api/v1/workspace/new" 2>/dev/null || echo "")
WS_SLUG=$(echo "$WS_RESP" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print((d.get('workspace') or {}).get('slug',''))" 2>/dev/null || echo "")
if [[ -n "$WS_SLUG" ]]; then
  pass "ワークスペース作成: slug=$WS_SLUG"
else
  fail "ワークスペース作成に失敗: $WS_RESP"
  exit 1
fi

# --- 2. 文書アップロード + embedding ---
echo "[2/6] fixture をアップロード・embedding 中..."
UP_RESP=$(curl -s --max-time "$TIMEOUT" -X POST "${AUTH[@]}" \
  -F "file=@$FIXTURE;type=text/plain" \
  -F "addToWorkspaces=$WS_SLUG" \
  "$BASE_URL/api/v1/document/upload" 2>/dev/null || echo "")
if echo "$UP_RESP" | grep -q '"success":true'; then
  pass "文書アップロード・embedding 完了"
else
  fail "文書アップロードに失敗: $(echo "$UP_RESP" | head -c 200)"
  exit 1
fi
sleep 3  # embedding 反映待ち

# --- 3. 文書内質問（出典付き回答） ---
echo "[3/6] 文書内質問（有給休暇は何日か）..."
Q1=$(curl -s --max-time "$TIMEOUT" -X POST "${AUTH[@]}" \
  -H "Content-Type: application/json" \
  -d '{"message":"有給休暇は年間何日付与されますか？","mode":"query"}' \
  "$BASE_URL/api/v1/workspace/$WS_SLUG/chat" 2>/dev/null || echo "")
A1=$(echo "$Q1" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d.get('textResponse',''))" 2>/dev/null || echo "")
SRC1=$(echo "$Q1" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(len(d.get('sources',[])))" 2>/dev/null || echo "0")
echo "      回答: $(echo "$A1" | head -c 120)"
if echo "$A1" | grep -q "22"; then
  pass "文書内の固有値「22」を含む回答"
else
  fail "回答に「22」が含まれない（ハルシネーションまたは検索失敗の可能性）"
fi
if [[ "$SRC1" -gt 0 ]]; then
  pass "出典 (sources) が $SRC1 件付与されている"
else
  fail "出典が付与されていない"
fi

# --- 4. 文書外質問（不明応答） ---
echo "[4/6] 文書外質問（文書に無い情報）..."
Q2=$(curl -s --max-time "$TIMEOUT" -X POST "${AUTH[@]}" \
  -H "Content-Type: application/json" \
  -d '{"message":"本社の所在地の郵便番号を教えてください。","mode":"query"}' \
  "$BASE_URL/api/v1/workspace/$WS_SLUG/chat" 2>/dev/null || echo "")
A2=$(echo "$Q2" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d.get('textResponse',''))" 2>/dev/null || echo "")
SRC2=$(echo "$Q2" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(len(d.get('sources',[])))" 2>/dev/null || echo "0")
echo "      回答: $(echo "$A2" | head -c 120)"
# query モードでは文書外質問は出典ゼロ または 明示的な不明応答になるべき
if [[ "$SRC2" -eq 0 ]] || echo "$A2" | grep -qiE "不明|見つかり|ありません|no relevant|don't have|情報がない|含まれて|記載されて|記載がない|わかりません|お答えできません"; then
  pass "文書外質問に対して出典なし／不明応答"
else
  fail "文書外質問に出典付きで回答した（ハルシネーションの疑い）"
fi

# --- 5. 外部LLM providerがAPI側で拒否されること ---
echo "[5/6] 外部LLM provider(openai)拒否の確認..."
PROV_RESP=$(curl -s --max-time 30 -X POST "${AUTH[@]}" \
  -H "Content-Type: application/json" \
  -d '{"LLMProvider":"openai","OpenAiKey":"sk-e2e-test-dummy","OpenAiModelPref":"gpt-4o"}' \
  "$BASE_URL/api/system/update-env" 2>/dev/null || echo "")
if echo "$PROV_RESP" | grep -qiE "not a permitted|not allowed|not supported"; then
  pass "外部provider(openai)はAPI側で拒否される"
else
  fail "外部provider(openai)が拒否されなかった: $(echo "$PROV_RESP" | head -c 200)"
fi

# --- 6. Swagger docs が無効であること ---
echo "[6/6] Swagger docs 無効の確認..."
DOCS_BODY=$(curl -s --max-time 10 "$BASE_URL/api/docs" 2>/dev/null || echo "")
if echo "$DOCS_BODY" | grep -qi "swagger\|Developer API Documentation"; then
  fail "Swagger docs が有効になっている（DISABLE_SWAGGER_DOCS を確認）"
else
  pass "Swagger docs は無効（/api/docs に Swagger UI が出ていない）"
fi

# --- 結果 ---
echo ""
echo "=== RAG E2E テスト結果: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]] && { echo "✓ RAG パイプラインは正常に動作しています。"; exit 0; }
echo "✗ 失敗があります。docker compose logs anythingllm を確認してください。"
exit 1
