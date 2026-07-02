#!/usr/bin/env bash
# export.sh — オンライン環境で実行。再現可能・検証可能なオフライン配布パッケージを作成する。
#
# 使い方:
#   bash scripts/export.sh [オプション]
#
# オプション:
#   --version VER       パッケージバージョン (既定: git describe または日付)
#   --output DIR        出力先ディレクトリ (既定: dist/localrag-<version>)
#   --llm-model M       LLM モデル (既定: llama3.1:8b)
#   --embed-model M     Embedding モデル (既定: mxbai-embed-large:latest)
#   --anythingllm-image IMG  AnythingLLM イメージ (既定: localrag-anythingllm:1.0.0)
#   --help              ヘルプ表示
#
# 必要条件:
#   - Docker & Docker Compose、インターネット接続
#
# 出力物:
#   <出力先>/
#     install.sh / uninstall.sh / smoke-test.sh / rag-e2e-test.sh / start.sh / stop.sh / backup.sh / restore.sh
#     *.ps1                               Windows/WSL2 用 PowerShell ランチャー
#                                         (localrag-wsl-launcher.ps1 + install/uninstall/start/stop/backup/restore.ps1)
#     README.md / INSTALL_GUIDE.md / …    顧客向けドキュメント (docs/customer/ から, 存在すれば)
#     docker-compose.yml
#     versions.lock                       バージョン・digest・git commit
#     checksums/
#       images.sha256                     イメージ tar の SHA-256
#       ollama-models.sha256              モデル全ファイルの SHA-256 manifest
#       package.sha256                     パッケージ全体の SHA-256 manifest
#     images/rag-images.tar.gz            Docker イメージ
#     ollama-models/                      Ollama モデルファイル群
#     fixtures/                           smoke-test 用テスト文書 (存在すれば)
#     LICENSES/ NOTICE                    法務情報 (存在すれば)

set -euo pipefail

# ---------------------------------------------------------------------------
# 既定値・引数解析
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNTIME_DIR="$PROJECT_ROOT/runtime"

ANYTHINGLLM_IMAGE="localrag-anythingllm:1.0.0"
OLLAMA_IMAGE="ollama/ollama:latest"
LLM_MODEL="llama3.1:8b"
EMBED_MODEL="mxbai-embed-large:latest"
VERSION=""
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)           VERSION="$2"; shift 2 ;;
    --output)            OUTPUT_DIR="$2"; shift 2 ;;
    --llm-model)         LLM_MODEL="$2"; shift 2 ;;
    --embed-model)       EMBED_MODEL="$2"; shift 2 ;;
    --anythingllm-image) ANYTHINGLLM_IMAGE="$2"; shift 2 ;;
    --help|-h)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "不明なオプション: $1"; exit 1 ;;
  esac
done

# バージョン未指定なら git から導出、なければ日付
if [[ -z "$VERSION" ]]; then
  VERSION="$(git -C "$PROJECT_ROOT" describe --tags --always 2>/dev/null || date '+%Y%m%d')"
fi
[[ -z "$OUTPUT_DIR" ]] && OUTPUT_DIR="$PROJECT_ROOT/dist/localrag-$VERSION"

GIT_COMMIT="$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo 'unknown')"
if [[ "$GIT_COMMIT" == "unknown" ]]; then
  echo "[ERROR] git commit hash を取得できません。git リポジトリ内で実行してください。" >&2
  exit 1
fi
LOG_FILE="$OUTPUT_DIR/export.log"
TEMP_CONTAINER="localrag-export-ollama-$$"

# ---------------------------------------------------------------------------
# ログ・クリーンアップ
# ---------------------------------------------------------------------------
log() {
  local level="$1"; shift
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
  echo "$msg"
  [[ -f "$LOG_FILE" ]] && echo "$msg" >> "$LOG_FILE"
}

cleanup() {
  local exit_code=$?
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${TEMP_CONTAINER}$"; then
    log INFO "一時コンテナを削除中..."
    docker rm -f "$TEMP_CONTAINER" >/dev/null 2>&1 || true
  fi
  [[ $exit_code -ne 0 ]] && log ERROR "エクスポート失敗 (exit $exit_code)。ログ: $LOG_FILE"
}
trap cleanup EXIT

# sha256 コマンド抽象化
sha256_cmd() {
  if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}

# ---------------------------------------------------------------------------
# 準備
# ---------------------------------------------------------------------------
mkdir -p "$OUTPUT_DIR/images" "$OUTPUT_DIR/ollama-models" "$OUTPUT_DIR/checksums"
# 以降 `cd "$OUTPUT_DIR/..."` した後にも $OUTPUT_DIR を使って書き込むため、
# 相対パスのまま (--output に相対パスを渡した場合) だと cd 後に意図しない
# 場所を指してしまう。作成直後に絶対パスへ正規化する。
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
exec > >(tee -a "$LOG_FILE") 2>&1

log INFO "=== LocalRAG オフライン配布パッケージ作成 ==="
log INFO "バージョン: $VERSION  / git commit: ${GIT_COMMIT:0:12}"
log INFO "出力先: $OUTPUT_DIR"

# --- 前提条件 ---
log INFO "[チェック] 前提条件を確認中..."
command -v docker >/dev/null || { log ERROR "Docker がありません"; exit 1; }
docker info >/dev/null 2>&1 || { log ERROR "Docker デーモンが起動していません"; exit 1; }
command -v sha256sum >/dev/null || command -v shasum >/dev/null \
  || { log ERROR "sha256sum / shasum が見つかりません"; exit 1; }

AVAIL_KB=$(df -k "$OUTPUT_DIR" | awk 'NR==2 {print $4}')
if [[ "$AVAIL_KB" -lt $((25 * 1024 * 1024)) ]]; then
  log ERROR "空きディスク容量不足。必要: 25GB、現在: $((AVAIL_KB / 1024 / 1024))GB"
  exit 2
fi
log INFO "      ディスク空き: $((AVAIL_KB / 1024 / 1024))GB  OK"

# ---------------------------------------------------------------------------
# 1. Docker イメージ取得 + digest 固定
# ---------------------------------------------------------------------------
log INFO "[1/6] Docker イメージを準備中..."
# カスタムビルド image (localrag-anythingllm 等) はレジストリに存在しないため、
# ローカルに既に存在する場合は pull しない。存在しなければレジストリからの
# pull を試みる (公式 ollama image 等)。
pull_if_missing() {
  local image="$1"
  if docker image inspect "$image" >/dev/null 2>&1; then
    log INFO "      $image はローカルに存在（pull をスキップ）"
  else
    log INFO "      $image を pull 中..."
    docker pull "$image"
  fi
}
pull_if_missing "$ANYTHINGLLM_IMAGE"
pull_if_missing "$OLLAMA_IMAGE"
# レジストリから pull した image は RepoDigest を持つが、ローカルビルド image (カスタム
# AnythingLLM image 等) は持たないため、その場合は image ID (sha256) にフォールバックする。
image_digest_or_id() {
  local image="$1" digest
  digest=$(docker inspect --format='{{index .RepoDigests 0}}' "$image" 2>/dev/null || true)
  if [[ -z "$digest" ]]; then
    digest=$(docker inspect --format='{{.Id}}' "$image" 2>/dev/null || true)
  fi
  echo "$digest"
}
ANYTHINGLLM_DIGEST=$(image_digest_or_id "$ANYTHINGLLM_IMAGE")
OLLAMA_DIGEST=$(image_digest_or_id "$OLLAMA_IMAGE")
if [[ -z "$ANYTHINGLLM_DIGEST" || -z "$OLLAMA_DIGEST" ]]; then
  log ERROR "image digest/ID を取得できません。image が正しく pull/build されているか確認してください。"
  exit 1
fi
log INFO "      anythingllm digest: $ANYTHINGLLM_DIGEST"
log INFO "      ollama digest:      $OLLAMA_DIGEST"

# ---------------------------------------------------------------------------
# 2. Docker イメージ保存 + checksum
# ---------------------------------------------------------------------------
log INFO "[2/6] Docker イメージを保存中..."
docker save "$ANYTHINGLLM_IMAGE" "$OLLAMA_IMAGE" | gzip > "$OUTPUT_DIR/images/rag-images.tar.gz"
log INFO "      サイズ: $(du -sh "$OUTPUT_DIR/images/rag-images.tar.gz" | cut -f1)"
( cd "$OUTPUT_DIR/images" && sha256_cmd "rag-images.tar.gz" > "$OUTPUT_DIR/checksums/images.sha256" )
log INFO "      images.sha256: $(awk '{print $1}' "$OUTPUT_DIR/checksums/images.sha256")"

# ---------------------------------------------------------------------------
# 3. Ollama モデル取得
# ---------------------------------------------------------------------------
log INFO "[3/6] Ollama モデルをダウンロード中..."
docker run -d --name "$TEMP_CONTAINER" \
  -v "$OUTPUT_DIR/ollama-models:/root/.ollama" "$OLLAMA_IMAGE" >/dev/null
sleep 5
log INFO "      $LLM_MODEL..."
docker exec "$TEMP_CONTAINER" ollama pull "$LLM_MODEL"
log INFO "      $EMBED_MODEL..."
docker exec "$TEMP_CONTAINER" ollama pull "$EMBED_MODEL"
docker rm -f "$TEMP_CONTAINER" >/dev/null

# ollama コンテナは root で動作し、/root/.ollama 配下 (id_ed25519 等) を
# root所有・600権限で作成する。ホスト側の非rootユーザーがその後の
# checksum生成・パッケージングで読めなくなるため、コンテナ経由で
# 現在のホストユーザーに所有権を戻す。
docker run --rm --entrypoint chown \
  -v "$OUTPUT_DIR/ollama-models:/root/.ollama" "$OLLAMA_IMAGE" \
  -R "$(id -u):$(id -g)" /root/.ollama

log INFO "      モデルサイズ: $(du -sh "$OUTPUT_DIR/ollama-models" | cut -f1)"

# ---------------------------------------------------------------------------
# 4. モデル checksum manifest
# ---------------------------------------------------------------------------
log INFO "[4/6] モデル checksum manifest を生成中..."
(
  cd "$OUTPUT_DIR"
  find ollama-models -type f -print0 | sort -z \
    | while IFS= read -r -d '' f; do sha256_cmd "$f"; done > "checksums/ollama-models.sha256"
)
if [[ ! -s "$OUTPUT_DIR/checksums/ollama-models.sha256" ]]; then
  log ERROR "ollama-models.sha256 の生成に失敗しました（空または未生成）。"
  exit 1
fi
MODEL_FILE_COUNT=$(wc -l < "$OUTPUT_DIR/checksums/ollama-models.sha256")
log INFO "      $MODEL_FILE_COUNT ファイルの checksum を記録"

# ---------------------------------------------------------------------------
# 5. versions.lock 生成
# ---------------------------------------------------------------------------
log INFO "[5/6] versions.lock を生成中..."
cat > "$OUTPUT_DIR/versions.lock" << EOF
# LocalRAG バージョン固定ファイル (配布後は変更しないこと)
# 生成日時: $(date '+%Y-%m-%d %H:%M:%S')

PACKAGE_VERSION=$VERSION
GIT_COMMIT=$GIT_COMMIT

ANYTHINGLLM_IMAGE=$ANYTHINGLLM_IMAGE
ANYTHINGLLM_DIGEST=$ANYTHINGLLM_DIGEST

OLLAMA_IMAGE=$OLLAMA_IMAGE
OLLAMA_DIGEST=$OLLAMA_DIGEST

LLM_MODEL=$LLM_MODEL
EMBED_MODEL=$EMBED_MODEL
EOF

# ---------------------------------------------------------------------------
# 6. スクリプト・設定・付属物コピー
# ---------------------------------------------------------------------------
log INFO "[6/6] スクリプト・設定・付属物をコピー中..."
cp "$RUNTIME_DIR/docker-compose.yml" "$OUTPUT_DIR/docker-compose.yml"
for s in install.sh uninstall.sh smoke-test.sh rag-e2e-test.sh start.sh stop.sh backup.sh restore.sh; do
  if [[ -f "$SCRIPT_DIR/$s" ]]; then
    cp "$SCRIPT_DIR/$s" "$OUTPUT_DIR/$s"
    chmod +x "$OUTPUT_DIR/$s"
  fi
done
for s in localrag-wsl-launcher.ps1 install.ps1 uninstall.ps1 start.ps1 stop.ps1 backup.ps1 restore.ps1; do
  [[ -f "$SCRIPT_DIR/$s" ]] && cp "$SCRIPT_DIR/$s" "$OUTPUT_DIR/$s"
done
# 付属ディレクトリ (存在すればコピー)
[[ -d "$PROJECT_ROOT/fixtures" ]] && cp -r "$PROJECT_ROOT/fixtures" "$OUTPUT_DIR/fixtures"
[[ -d "$PROJECT_ROOT/LICENSES" ]] && cp -r "$PROJECT_ROOT/LICENSES" "$OUTPUT_DIR/LICENSES"
[[ -f "$PROJECT_ROOT/NOTICE" ]] && cp "$PROJECT_ROOT/NOTICE" "$OUTPUT_DIR/NOTICE"
for doc in README.md INSTALL_GUIDE.md OPERATIONS_GUIDE.md SECURITY_GUIDE.md TROUBLESHOOTING.md; do
  [[ -f "$PROJECT_ROOT/docs/customer/$doc" ]] && cp "$PROJECT_ROOT/docs/customer/$doc" "$OUTPUT_DIR/$doc"
done

# パッケージ全体の checksum manifest (checksums/ 自身と log は除外)
log INFO "      package.sha256 を生成中..."
(
  cd "$OUTPUT_DIR"
  find . -type f \
    ! -path './checksums/*' ! -name 'export.log' -print0 | sort -z \
    | while IFS= read -r -d '' f; do sha256_cmd "$f"; done > "checksums/package.sha256"
)
if [[ ! -s "$OUTPUT_DIR/checksums/package.sha256" ]]; then
  log ERROR "package.sha256 の生成に失敗しました（空または未生成）。"
  exit 1
fi

# ---------------------------------------------------------------------------
# 完了
# ---------------------------------------------------------------------------
log INFO ""
log INFO "=== エクスポート完了 ==="
log INFO "パッケージサイズ: $(du -sh "$OUTPUT_DIR" | cut -f1)"
log INFO "出力先: $OUTPUT_DIR"
log INFO ""
log INFO "配布先（オフライン環境）での手順:"
log INFO "  1. このフォルダ全体をオフライン環境へコピー（USB/LAN）"
log INFO "  2. bash install.sh"
log INFO ""
log INFO "注意: FAT32 USB は 4GB 超ファイル不可。exFAT/NTFS でフォーマットすること。"
