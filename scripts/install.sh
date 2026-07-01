#!/usr/bin/env bash
# install.sh — オフライン環境で実行。LocalRAG をインストールして起動する。
#
# 使い方:
#   bash install.sh
#
# 必要条件:
#   - Docker Engine + Docker Compose v2（インターネット接続不要）
#   - NVIDIA ドライバ + nvidia-container-toolkit（GPU 推論用）
#   - このスクリプトと同じディレクトリに以下が存在すること（欠落時はインストール失敗）:
#       images/rag-images.tar.gz        Docker イメージアーカイブ
#       ollama-models/                  Ollama モデルファイル群
#       docker-compose.yml              Compose 設定
#       versions.lock                   バージョン固定ファイル
#       checksums/images.sha256         イメージ tar のチェックサム（必須）
#       checksums/ollama-models.sha256  モデルファイルのチェックサム（必須）
#       checksums/package.sha256        パッケージ全体のチェックサム（必須）

set -euo pipefail

# ---------------------------------------------------------------------------
# 定数・設定
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/install.log"
REQUIRED_FREE_GB=5          # anythingllm-storage 用に最低 5GB
HEALTHCHECK_RETRIES=36      # 36 × 5s = 最大 3 分待機
HEALTHCHECK_INTERVAL=5

EXIT_SUCCESS=0
EXIT_PREREQ_FAILED=1
EXIT_RUNTIME_ERROR=2
EXIT_ALREADY_INSTALLED=3    # 再実行時の情報表示用

# ---------------------------------------------------------------------------
# ログ関数（ファイルと stdout に同時出力）
# ---------------------------------------------------------------------------
log() {
  local level="$1"; shift
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
  echo "$msg"
  echo "$msg" >> "$LOG_FILE"
}

# ---------------------------------------------------------------------------
# クリーンアップ（EXIT トラップ。失敗時のみ警告を表示）
# ---------------------------------------------------------------------------
cleanup() {
  local exit_code=$?
  if [[ $exit_code -ne 0 && $exit_code -ne $EXIT_ALREADY_INSTALLED ]]; then
    log ERROR "インストールが失敗しました (exit $exit_code)。"
    log ERROR "詳細ログ: $LOG_FILE"
    log ERROR "部分的に起動したサービスを停止します..."
    cd "$SCRIPT_DIR" && docker compose down 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ログ開始
exec > >(tee -a "$LOG_FILE") 2>&1

log INFO "=== LocalRAG インストーラー 開始 ==="
log INFO "インストール先: $SCRIPT_DIR"
[[ -f "$SCRIPT_DIR/versions.lock" ]] && {
  log INFO "--- バージョン情報 ---"
  grep -v '^#' "$SCRIPT_DIR/versions.lock" | grep -v '^$' | while read -r line; do
    log INFO "  $line"
  done
  log INFO "---------------------"
}

# ---------------------------------------------------------------------------
# 前提条件チェック（全チェックを実行してから失敗させる）
# ---------------------------------------------------------------------------
log INFO "[チェック] 前提条件を確認中..."
PREFLIGHT_OK=true

# Docker インストール確認
if ! command -v docker &>/dev/null; then
  log ERROR "  [NG] Docker がインストールされていません。"
  log ERROR "       オフライン用インストーラーを IT 担当者に依頼してください。"
  PREFLIGHT_OK=false
else
  DOCKER_VER=$(docker --version | awk '{print $3}' | tr -d ',')
  log INFO "  [OK] Docker $DOCKER_VER"
fi

# Docker デーモン稼働確認
if command -v docker &>/dev/null && ! docker info &>/dev/null 2>&1; then
  log ERROR "  [NG] Docker デーモンが起動していません。"
  log ERROR "       'sudo systemctl start docker' を実行してください。"
  PREFLIGHT_OK=false
fi

# Docker Compose v2 確認
if ! docker compose version &>/dev/null 2>&1; then
  log ERROR "  [NG] Docker Compose v2 がインストールされていません。"
  PREFLIGHT_OK=false
else
  COMPOSE_VER=$(docker compose version --short 2>/dev/null || echo "unknown")
  log INFO "  [OK] Docker Compose $COMPOSE_VER"
fi

# ユーザーが docker グループに所属しているか（root 以外の場合）
if [[ $EUID -ne 0 ]]; then
  if ! groups | grep -qw docker; then
    log ERROR "  [NG] 現在のユーザーが docker グループに属していません。"
    log ERROR "       'sudo usermod -aG docker \$USER' 後、再ログインしてください。"
    PREFLIGHT_OK=false
  else
    log INFO "  [OK] docker グループ所属"
  fi
fi

# ディスク空き容量チェック
AVAIL_KB=$(df -k "$SCRIPT_DIR" | awk 'NR==2 {print $4}')
REQUIRED_KB=$((REQUIRED_FREE_GB * 1024 * 1024))
if [[ "$AVAIL_KB" -lt "$REQUIRED_KB" ]]; then
  log ERROR "  [NG] ディスク空き容量不足。必要: ${REQUIRED_FREE_GB}GB、現在: $((AVAIL_KB / 1024 / 1024))GB"
  PREFLIGHT_OK=false
else
  log INFO "  [OK] ディスク空き: $((AVAIL_KB / 1024 / 1024))GB"
fi

# ポート 3001 が使用中でないか確認
if command -v ss &>/dev/null; then
  if ss -tlnp 2>/dev/null | grep -q ':3001 '; then
    log ERROR "  [NG] ポート 3001 が既に使用されています。"
    log ERROR "       競合するプロセスを停止するか、docker-compose.yml でポートを変更してください。"
    PREFLIGHT_OK=false
  else
    log INFO "  [OK] ポート 3001 は空き"
  fi
elif command -v netstat &>/dev/null; then
  if netstat -tlnp 2>/dev/null | grep -q ':3001 '; then
    log ERROR "  [NG] ポート 3001 が既に使用されています。"
    PREFLIGHT_OK=false
  else
    log INFO "  [OK] ポート 3001 は空き"
  fi
fi

# NVIDIA Container Runtime 確認（警告のみ、致命的ではない）
if ! docker info --format '{{.Runtimes}}' 2>/dev/null | grep -q nvidia; then
  log INFO "  [警告] NVIDIA Container Runtime が検出されませんでした。"
  log INFO "         GPU なしでも起動できますが推論速度が非常に遅くなります。"
  GPU_AVAILABLE=false
else
  log INFO "  [OK] NVIDIA Container Runtime"
  GPU_AVAILABLE=true
fi

# 必須ファイル確認
if [[ ! -f "$SCRIPT_DIR/images/rag-images.tar.gz" ]]; then
  log ERROR "  [NG] images/rag-images.tar.gz が見つかりません。"
  PREFLIGHT_OK=false
else
  log INFO "  [OK] images/rag-images.tar.gz ($(du -sh "$SCRIPT_DIR/images/rag-images.tar.gz" | cut -f1))"
fi

if [[ ! -d "$SCRIPT_DIR/ollama-models" ]]; then
  log ERROR "  [NG] ollama-models/ ディレクトリが見つかりません。"
  PREFLIGHT_OK=false
else
  log INFO "  [OK] ollama-models/ ($(du -sh "$SCRIPT_DIR/ollama-models" | cut -f1))"
fi

if [[ ! -f "$SCRIPT_DIR/docker-compose.yml" ]]; then
  log ERROR "  [NG] docker-compose.yml が見つかりません。"
  PREFLIGHT_OK=false
else
  log INFO "  [OK] docker-compose.yml"
fi

for req in checksums/images.sha256 checksums/ollama-models.sha256 checksums/package.sha256; do
  if [[ ! -f "$SCRIPT_DIR/$req" ]]; then
    log ERROR "  [NG] $req が見つかりません（真正性検証に必須）。"
    PREFLIGHT_OK=false
  else
    log INFO "  [OK] $req"
  fi
done

[[ "$PREFLIGHT_OK" == false ]] && exit $EXIT_PREREQ_FAILED

# ---------------------------------------------------------------------------
# 冪等性チェック: 既にサービスが起動中なら再起動を促して終了
# ---------------------------------------------------------------------------
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^anythingllm$'; then
  log INFO ""
  log INFO "LocalRAG は既に起動中です。"
  log INFO "  ブラウザ: http://localhost:3001"
  log INFO "  再起動する場合: docker compose restart"
  log INFO "  停止する場合:   bash uninstall.sh (データを残す場合は --keep-data)"
  exit $EXIT_ALREADY_INSTALLED
fi

# ---------------------------------------------------------------------------
# 1. SHA-256 チェックサム検証（イメージ + モデル manifest）
# ---------------------------------------------------------------------------
log INFO ""
log INFO "[1/4] チェックサムを検証中..."

# sha256 -c のラッパー (sha256sum / shasum 両対応)
sha256_check() { if command -v sha256sum &>/dev/null; then sha256sum -c "$1"; else shasum -a 256 -c "$1"; fi; }

if ! command -v sha256sum &>/dev/null && ! command -v shasum &>/dev/null; then
  log ERROR "  [NG] sha256sum / shasum が見つかりません。チェックサム検証を実行できません。"
  exit $EXIT_PREREQ_FAILED
fi

# checksums/*.sha256 の存在は上記 preflight で必須確認済み (欠落時は既に exit 済み)。
log INFO "      イメージ tar を検証中..."
( cd "$SCRIPT_DIR/images" && sha256_check "$SCRIPT_DIR/checksums/images.sha256" >/dev/null ) || {
  log ERROR "イメージのチェックサム不一致。ファイル破損の可能性があります。再転送してください。"
  exit $EXIT_RUNTIME_ERROR
}

MODEL_N=$(wc -l < "$SCRIPT_DIR/checksums/ollama-models.sha256")
log INFO "      モデルファイル ($MODEL_N 件) を検証中..."
( cd "$SCRIPT_DIR" && sha256_check "checksums/ollama-models.sha256" >/dev/null ) || {
  log ERROR "モデルのチェックサム不一致。ファイル破損の可能性があります。再転送してください。"
  exit $EXIT_RUNTIME_ERROR
}

log INFO "      パッケージ全体を検証中..."
( cd "$SCRIPT_DIR" && sha256_check "checksums/package.sha256" >/dev/null ) || {
  log ERROR "パッケージのチェックサム不一致。ファイル破損の可能性があります。再転送してください。"
  exit $EXIT_RUNTIME_ERROR
}

log INFO "      チェックサム検証 OK"

# ---------------------------------------------------------------------------
# 2. Docker イメージのロード
# ---------------------------------------------------------------------------
log INFO ""
log INFO "[2/4] Docker イメージを読み込み中（数分かかります）..."
docker load < "$SCRIPT_DIR/images/rag-images.tar.gz" | while read -r line; do log INFO "      $line"; done
log INFO "      イメージ読み込み完了"

# ---------------------------------------------------------------------------
# 3. データディレクトリの作成
# ---------------------------------------------------------------------------
log INFO ""
log INFO "[3/4] データディレクトリを準備中..."
mkdir -p "$SCRIPT_DIR/anythingllm-storage"
log INFO "      anythingllm-storage/ を作成しました"
log INFO "      ollama-models/ サイズ: $(du -sh "$SCRIPT_DIR/ollama-models" | cut -f1)"

# ---------------------------------------------------------------------------
# 4. サービス起動
# ---------------------------------------------------------------------------
log INFO ""
log INFO "[4/4] サービスを起動中..."
cd "$SCRIPT_DIR"
docker compose up -d
log INFO "      Compose 起動コマンド送信完了"

# ヘルスチェックループ
log INFO ""
log INFO "AnythingLLM の起動を待機中（最大 $((HEALTHCHECK_RETRIES * HEALTHCHECK_INTERVAL / 60)) 分）..."
for i in $(seq 1 $HEALTHCHECK_RETRIES); do
  if curl -sf http://localhost:3001/api/ping >/dev/null 2>&1; then
    log INFO ""
    log INFO "=== インストール完了 ==="
    log INFO ""
    log INFO "ブラウザで以下の URL にアクセスしてください:"
    log INFO "  http://localhost:3001"
    log INFO ""
    log INFO "動作確認:"
    log INFO "  bash smoke-test.sh"
    log INFO ""
    log INFO "操作コマンド:"
    log INFO "  停止:   docker compose down"
    log INFO "  再起動: docker compose up -d"
    log INFO "  ログ:   docker compose logs -f"
    log INFO "  削除:   bash uninstall.sh"
    log INFO ""
    log INFO "GPU 状態: $( [[ "$GPU_AVAILABLE" == true ]] && echo "有効" || echo "無効（CPU のみ）" )"
    exit $EXIT_SUCCESS
  fi
  printf "."
  sleep $HEALTHCHECK_INTERVAL
done

log ERROR ""
log ERROR "起動タイムアウト（$((HEALTHCHECK_RETRIES * HEALTHCHECK_INTERVAL / 60)) 分）"
log ERROR "ログを確認してください:"
log ERROR "  docker compose logs anythingllm"
log ERROR "  docker compose logs ollama"
exit $EXIT_RUNTIME_ERROR
