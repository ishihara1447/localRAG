#!/usr/bin/env bash
# ビルドした Docker イメージの中身が fork のソースと一致することを検証する。
#
#   ./verify-image.sh [イメージタグ]        （既定: localrag-anythingllm:1.1.0）
#
# 目的: 「ソースには入っているのに配布物には入っていない」事故の検出。
#       Windows 版ビルド（docs/WINDOWS_BUILD_V1.2.6_2026-07-28.md §2, §5）と同じ検査を
#       Docker イメージに対して行う。
#
# 方式: コンテナは **起動しない**（docker create → docker cp → docker rm）。
#       稼働中のコンテナには一切触れない。
set -euo pipefail

IMAGE="${1:-localrag-anythingllm:1.1.0}"
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FORK="$REPO_ROOT/anything-llm"
TMP="$(mktemp -d)"
CID=""
trap 'rm -rf "$TMP"; [ -n "$CID" ] && docker rm -f "$CID" >/dev/null 2>&1; true' EXIT

# 一致を確認するファイル（fork 相対パス）。今回の配布で意味を持つ改修を網羅する。
FILES=(
  "server/utils/vectorDbProviders/lance/index.js"
  "server/utils/vectorDbProviders/lance/sentenceCushion.js"
  "server/utils/helpers/productProfile.js"
  "server/utils/helpers/updateENV.js"
  "server/utils/helpers/transformersOffline.js"
  "server/utils/EmbeddingRerankers/native/index.js"
  "server/utils/EmbeddingEngines/native/index.js"
  "server/utils/boot/verifyBundledAssets.js"
  "server/utils/boot/index.js"
  "server/utils/chats/queryReformulation.js"
  "server/utils/AiProviders/ollama/index.js"
  "collector/utils/transformersOffline.js"
  "collector/utils/OCRLoader/index.js"
  "collector/utils/WhisperProviders/localWhisper.js"
  "collector/processSingleFile/convert/asPDF/PDFLoader/index.js"
)

echo "=== イメージ内容の検証: $IMAGE ==="
docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "ERROR: イメージがありません: $IMAGE" >&2; exit 1; }
[ -d "$FORK" ] || { echo "ERROR: fork が見つかりません: $FORK" >&2; exit 1; }

echo "--- fork の状態 ---"
git -C "$FORK" log --oneline -1
if [ -n "$(git -C "$FORK" status --porcelain)" ]; then
  echo "🔴 注意: fork の作業ツリーに未コミットの変更があります。イメージはその状態を含みます。"
  git -C "$FORK" status --porcelain | sed 's/^/    /'
fi

CID="$(docker create "$IMAGE" /bin/true)"
echo "--- 一時コンテナ $CID を作成（起動はしない） ---"

fail=0
printf '\n%-8s  %s\n' "結果" "ファイル"
for rel in "${FILES[@]}"; do
  src="$FORK/$rel"
  if [ ! -f "$src" ]; then
    printf '%-8s  %s (fork 側に存在しない)\n' "SKIP" "$rel"
    continue
  fi
  mkdir -p "$TMP/$(dirname "$rel")"
  if ! docker cp "$CID:/app/$rel" "$TMP/$rel" >/dev/null 2>&1; then
    printf '%-8s  %s (イメージ内に存在しない)\n' "MISSING" "$rel"
    fail=$((fail + 1))
    continue
  fi
  a="$(sha256sum "$src" | cut -d' ' -f1)"
  b="$(sha256sum "$TMP/$rel" | cut -d' ' -f1)"
  if [ "$a" = "$b" ]; then
    printf '%-8s  %s  %s\n' "一致" "${a:0:16}…" "$rel"
  else
    printf '%-8s  %s\n' "不一致" "$rel"
    printf '          fork : %s\n' "$a"
    printf '          image: %s\n' "$b"
    fail=$((fail + 1))
  fi
done

# --- フロントエンドのビルド成果物 ---
echo
echo "--- frontend バンドルの検査 ---"
if docker cp "$CID:/app/server/public/index.js" "$TMP/index.js" >/dev/null 2>&1; then
  size=$(stat -c%s "$TMP/index.js")
  printf '  index.js: %s bytes\n' "$size"
  if grep -q "localhost:3001" "$TMP/index.js"; then
    echo "  🔴 不合格: バンドルに localhost:3001 が焼き込まれている（VITE_API_BASE が dev 値）"
    fail=$((fail + 1))
  else
    echo "  OK: localhost:3001 を含まない"
  fi
  if grep -q "この配布版では利用できません" "$TMP/index.js"; then
    echo "  OK: productProfile の URL ガード文言を含む（設定メニュー改修がバンドル済み）"
  else
    echo "  🔴 不合格: 設定メニュー改修（productProfile）がバンドルに入っていない"
    fail=$((fail + 1))
  fi
else
  echo "  🔴 不合格: /app/server/public/index.js がイメージに無い"
  fail=$((fail + 1))
fi

# --- 実行ユーザー ---
echo
echo "--- イメージのメタ情報 ---"
printf '  User        : %s\n' "$(docker image inspect "$IMAGE" --format '{{.Config.User}}')"
printf '  Entrypoint  : %s\n' "$(docker image inspect "$IMAGE" --format '{{json .Config.Entrypoint}}')"
printf '  Created     : %s\n' "$(docker image inspect "$IMAGE" --format '{{.Created}}')"
printf '  Size        : %s bytes\n' "$(docker image inspect "$IMAGE" --format '{{.Size}}')"

echo
if [ "$fail" -eq 0 ]; then
  echo "✅ 検証 PASS: イメージの内容は fork のソースと一致している。"
else
  echo "❌ 検証 FAIL: $fail 件の不一致・欠落があります。イメージを作り直してください。"
  exit 1
fi
