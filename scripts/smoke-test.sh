#!/usr/bin/env bash
# smoke-test.sh — インストール後の動作確認スクリプト。
#
# 使い方:
#   bash smoke-test.sh
#
# テスト内容:
#   1. AnythingLLM API の疎通確認 (/api/ping)
#   2. Ollama の応答確認 (/api/tags) ※内部ネットワーク経由
#   3. ワークスペース一覧取得（認証トークン確認）
#   4. 簡単な LLM 推論テスト（日本語の挨拶）
#   5. GPU 使用状況確認
#
# 前提条件:
#   - LocalRAG が起動済み（bash install.sh 完了後）
#   - API_KEY を環境変数またはこのファイル内で設定

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/smoke-test.log"
BASE_URL="http://localhost:3001"
TIMEOUT=30   # 各 API コール最大 30 秒

# API キーは環境変数で上書き可能。未設定時は install.sh 後に発行されたキーを使う。
# 発行方法: AnythingLLM 管理画面 → API Keys
API_KEY="${LOCALRAG_API_KEY:-}"

PASS=0
FAIL=0
SKIP=0

log() {
  local level="$1"; shift
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
  echo "$msg"
  echo "$msg" >> "$LOG_FILE"
}

pass() { log INFO "  [PASS] $*"; ((PASS++)) || true; }
fail() { log ERROR "  [FAIL] $*"; ((FAIL++)) || true; }
skip() { log INFO "  [SKIP] $*"; ((SKIP++)) || true; }

exec > >(tee -a "$LOG_FILE") 2>&1

log INFO "=== LocalRAG スモークテスト ==="
log INFO "対象: $BASE_URL"
echo ""

# ---------------------------------------------------------------------------
# テスト 1: AnythingLLM 起動確認
# ---------------------------------------------------------------------------
log INFO "[1/5] AnythingLLM API 疎通確認..."
PING_RESP=$(curl -sf --max-time "$TIMEOUT" "$BASE_URL/api/ping" 2>/dev/null || echo "")
if echo "$PING_RESP" | grep -q '"online":true'; then
  pass "GET /api/ping → online:true"
else
  fail "GET /api/ping が失敗しました。サービスが起動していない可能性があります。"
  fail "確認コマンド: docker compose logs anythingllm"
fi

# ---------------------------------------------------------------------------
# テスト 2: Ollama サービス確認（コンテナ内から ping）
# ---------------------------------------------------------------------------
log INFO "[2/5] Ollama サービス確認（Docker コンテナ内部）..."
OLLAMA_CHECK=$(docker exec anythingllm \
  wget -qO- --timeout=10 http://ollama:11434/api/tags 2>/dev/null || echo "")
if echo "$OLLAMA_CHECK" | grep -q '"models"'; then
  MODEL_COUNT=$(echo "$OLLAMA_CHECK" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(len(d.get('models',[])))" 2>/dev/null || echo "?")
  pass "Ollama API 応答確認（モデル数: $MODEL_COUNT）"
else
  fail "Ollama API に到達できません。"
  fail "確認コマンド: docker compose logs ollama"
fi

# ---------------------------------------------------------------------------
# テスト 3: 認証 API（API キーが設定されている場合のみ）
# ---------------------------------------------------------------------------
log INFO "[3/5] 認証 API 確認..."
if [[ -z "$API_KEY" ]]; then
  skip "LOCALRAG_API_KEY が未設定のためスキップ。"
  skip "API キー発行: ブラウザで http://localhost:3001 → Settings → API Keys"
else
  AUTH_RESP=$(curl -sf --max-time "$TIMEOUT" \
    -H "Authorization: Bearer $API_KEY" \
    "$BASE_URL/api/v1/workspaces" 2>/dev/null || echo "")
  if echo "$AUTH_RESP" | grep -q '"workspaces"'; then
    WS_COUNT=$(echo "$AUTH_RESP" | python3 -c \
      "import sys,json; d=json.load(sys.stdin); print(len(d.get('workspaces',[])))" 2>/dev/null || echo "?")
    pass "GET /api/v1/workspaces → ワークスペース数: $WS_COUNT"
  else
    fail "GET /api/v1/workspaces が失敗 (API キーが無効か期限切れの可能性)"
  fi
fi

# ---------------------------------------------------------------------------
# テスト 4: LLM 推論テスト（API キーとワークスペースが必要）
# ---------------------------------------------------------------------------
log INFO "[4/5] LLM 推論テスト..."
if [[ -z "$API_KEY" ]]; then
  skip "LOCALRAG_API_KEY が未設定のためスキップ。"
else
  # デフォルトワークスペースを取得
  DEFAULT_WS=$(curl -sf --max-time "$TIMEOUT" \
    -H "Authorization: Bearer $API_KEY" \
    "$BASE_URL/api/v1/workspaces" 2>/dev/null \
    | python3 -c \
      "import sys,json; ws=json.load(sys.stdin).get('workspaces',[]); print(ws[0]['slug'] if ws else '')" \
      2>/dev/null || echo "")

  if [[ -z "$DEFAULT_WS" ]]; then
    skip "ワークスペースが存在しないためスキップ。ブラウザでワークスペースを作成してください。"
  else
    log INFO "      ワークスペース: $DEFAULT_WS"
    log INFO "      テストプロンプト送信中（最大 60 秒）..."
    LLM_RESP=$(curl -sf --max-time 120 \
      -H "Authorization: Bearer $API_KEY" \
      -H "Content-Type: application/json" \
      -d '{"message":"こんにちは。あなたは正常に動作していますか？「はい」か「いいえ」だけで答えてください。","mode":"chat"}' \
      "$BASE_URL/api/v1/workspace/$DEFAULT_WS/chat" 2>/dev/null || echo "")

    if echo "$LLM_RESP" | grep -qi '"textResponse"'; then
      RESPONSE_TEXT=$(echo "$LLM_RESP" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d.get('textResponse','')[:100])" 2>/dev/null || echo "")
      pass "LLM 推論成功: 「$RESPONSE_TEXT」"
    else
      fail "LLM 推論が失敗しました（タイムアウトまたはエラー）"
      fail "確認: docker compose logs anythingllm | grep -i error"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# テスト 5: GPU 使用状況
# ---------------------------------------------------------------------------
log INFO "[5/5] GPU 使用状況確認..."
if docker exec rag-ollama nvidia-smi &>/dev/null 2>&1; then
  GPU_INFO=$(docker exec rag-ollama nvidia-smi \
    --query-gpu=name,memory.used,memory.total,utilization.gpu \
    --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "")
  if [[ -n "$GPU_INFO" ]]; then
    pass "GPU 検出: $GPU_INFO (Name, MemUsed MB, MemTotal MB, Util%)"
  else
    pass "GPU コンテナアクセス成功（詳細情報取得不可）"
  fi
else
  skip "GPU コンテナ内で nvidia-smi が使用不可（CPU モードで動作中）"
fi

# ---------------------------------------------------------------------------
# 結果サマリー
# ---------------------------------------------------------------------------
echo ""
log INFO "=== スモークテスト 結果 ==="
log INFO "  PASS: $PASS  FAIL: $FAIL  SKIP: $SKIP"
if [[ $FAIL -eq 0 ]]; then
  log INFO "  ✓ すべてのテストが通過しました。"
  exit 0
else
  log ERROR "  $FAIL 件のテストが失敗しました。上記のログを確認してください。"
  exit 1
fi
