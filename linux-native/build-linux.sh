#!/usr/bin/env bash
# OTE-RAG Linux オフライン配布物のビルドスクリプト（開発機で実行する）。
#
#   ./linux-native/build-linux.sh                  # イメージのビルドから通しで実行
#   ./linux-native/build-linux.sh --skip-build     # イメージは既にある前提でパッケージだけ作る
#   ./linux-native/build-linux.sh --output /path   # 出力先（既定: <repo>/dist-linux）
#
# 🔴 稼働中のコンテナには一切触れない。docker compose up/down/stop/restart は実行しない。
#    使うのは docker build / docker save / docker create / docker cp / docker image inspect のみ。
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LINUX_DIR="$REPO_ROOT/linux-native"
FORK="$REPO_ROOT/anything-llm"
RUNTIME="$REPO_ROOT/runtime"

VERSION="1.1.0"
IMAGE_APP="localrag-anythingllm:$VERSION"
OLLAMA_VERSION="0.30.11"
OLLAMA_SRC_TAG="ollama/ollama:latest"
OLLAMA_PIN_TAG="ollama/ollama:$OLLAMA_VERSION"
# 2026-07-28 時点で ollama/ollama:latest が指していたマニフェストダイジェスト。
OLLAMA_DIGEST="sha256:c484b703176aa19dfc0a54cbfb60ab8094b38faa04283fb77eba1d33319e5eca"

OUTPUT="$REPO_ROOT/dist-linux"
SKIP_BUILD=0
SKIP_VERIFY=0
ALLOW_DIRTY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --output) OUTPUT="${2:?}"; shift 2 ;;
    --version) VERSION="${2:?}"; IMAGE_APP="localrag-anythingllm:$VERSION"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --skip-verify) SKIP_VERIFY=1; shift ;;
    --allow-dirty) ALLOW_DIRTY=1; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "不明なオプション: $1" >&2; exit 1 ;;
  esac
done

# 配布物の命名は linux-native/INSTALL_GUIDE.md の記載と一致させること。
PKG_NAME="ote-rag-linux-x64-v$VERSION"
PKG="$OUTPUT/$PKG_NAME"

say() { printf '\n=== %s ===\n' "$1"; }
die() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

[ -d "$FORK" ] || die "fork がありません: $FORK"
[ -d "$RUNTIME/ollama-models/models" ] || die "Ollama モデルがありません: $RUNTIME/ollama-models/models"
[ -d "$RUNTIME/anythingllm-storage/models/onnx-community/bge-reranker-v2-m3-ONNX" ] \
  || die "リランカーがありません: $RUNTIME/anythingllm-storage/models/onnx-community/bge-reranker-v2-m3-ONNX"
[ -d "$REPO_ROOT/windows-native/assets/tesseract" ] || die "OCR 言語データがありません（windows-native/assets/tesseract）"
[ -f "$LINUX_DIR/survey-target.sh" ] || die "survey-target.sh がありません: $LINUX_DIR/survey-target.sh"

# ---------------------------------------------------------------- 1. イメージのビルド
say "1. AnythingLLM イメージ ($IMAGE_APP)"
FORK_DIRTY=""
[ -n "$(git -C "$FORK" status --porcelain 2>/dev/null)" ] && FORK_DIRTY=1

if [ "$SKIP_BUILD" -eq 1 ]; then
  docker image inspect "$IMAGE_APP" >/dev/null 2>&1 || die "--skip-build ですが $IMAGE_APP がありません"
  echo "既存イメージを使用（--skip-build）"
  if [ -n "$FORK_DIRTY" ]; then
    # 既存イメージを使う場合、作業ツリーの状態はイメージに影響しない。
    # verify-image.sh が git のコミットを基準に照合するので、ここは警告で足りる。
    echo "  補足: fork の作業ツリーに未コミットの変更がありますが、"
    echo "        既存イメージを使うため配布物には影響しません（step 2 でコミット基準に照合）。"
  fi
else
  # 🔴 dirty な作業ツリーからビルドすると、未コミットの実験コードが製品イメージに
  #    焼き込まれる。しかも verify-image.sh はコミット基準で照合するため
  #    「不一致」として現れ、原因が分かりにくい失敗になる。ここで止める。
  if [ -n "$FORK_DIRTY" ] && [ "$ALLOW_DIRTY" -eq 0 ]; then
    echo "ERROR: fork の作業ツリーに未コミットの変更があります。" >&2
    git -C "$FORK" status --porcelain | sed 's/^/    /' >&2
    cat >&2 <<'EOS'

  この状態でビルドすると、未コミットのコードが顧客向けイメージに入ります。
  対処のいずれかを選んでください:
    1) 既存のイメージを使う         : --skip-build      ← 通常はこれ
    2) 変更をコミットしてからビルド : git -C anything-llm commit ...
    3) 承知のうえで強行する         : --allow-dirty
EOS
    exit 1
  fi
  ( cd "$FORK" && docker build --network=host -t "$IMAGE_APP" -f docker/Dockerfile . )
fi
docker image inspect "$IMAGE_APP" --format '  ID={{.Id}} Size={{.Size}} User={{.Config.User}}'

# ---------------------------------------------------------------- 2. 中身の検証
say "2. イメージ内容と fork ソースの SHA-256 一致検証"
if [ "$SKIP_VERIFY" -eq 1 ]; then
  echo "スキップ（--skip-verify）"
else
  bash "$LINUX_DIR/verify-image.sh" "$IMAGE_APP"
fi

# ---------------------------------------------------------------- 3. Ollama イメージのタグ固定
say "3. Ollama イメージのタグ固定 ($OLLAMA_PIN_TAG)"
if ! docker image inspect "$OLLAMA_PIN_TAG" >/dev/null 2>&1; then
  docker image inspect "$OLLAMA_SRC_TAG" >/dev/null 2>&1 \
    || die "$OLLAMA_SRC_TAG がありません。オフライン環境では pull できないため、あらかじめ取得しておくこと。"
  actual_digest="$(docker image inspect "$OLLAMA_SRC_TAG" --format '{{index .RepoDigests 0}}' | sed 's/.*@//')"
  if [ "$actual_digest" != "$OLLAMA_DIGEST" ]; then
    echo "🔴 注意: ollama/ollama:latest のダイジェストが記録と異なります。"
    echo "    記録: $OLLAMA_DIGEST"
    echo "    実際: $actual_digest"
    echo "    latest が更新されています。build-linux.sh の OLLAMA_DIGEST / OLLAMA_VERSION を更新してから続けてください。"
    die "ダイジェスト不一致のため中断"
  fi
  docker tag "$OLLAMA_SRC_TAG" "$OLLAMA_PIN_TAG"
fi
docker image inspect "$OLLAMA_PIN_TAG" --format '  ID={{.Id}} Size={{.Size}}'

# ---------------------------------------------------------------- 4. パッケージ構築
say "4. パッケージ構築: $PKG"
[ -e "$PKG" ] && die "$PKG が既に存在します。先に削除してください。"
mkdir -p "$PKG"/{images,models,assets,checksums,docs}

echo "[4-1] Docker イメージを保存（docker save + pigz）..."
GZ="gzip"; command -v pigz >/dev/null 2>&1 && GZ="pigz"
docker save "$IMAGE_APP"      | $GZ -c > "$PKG/images/localrag-anythingllm-$VERSION.tar.gz"
docker save "$OLLAMA_PIN_TAG" | $GZ -c > "$PKG/images/ollama-$OLLAMA_VERSION.tar.gz"
ls -l "$PKG/images" | sed 's/^/    /'

echo "[4-2] Ollama モデル（マニフェスト駆動で blob を選別）..."
mkdir -p "$PKG/models/ollama/models/blobs"
python3 - "$RUNTIME/ollama-models/models" "$PKG/models/ollama/models" <<'PY'
import json, os, shutil, sys
src, dst = sys.argv[1], sys.argv[2]
models = {
    "gemma4:12b":    "manifests/registry.ollama.ai/library/gemma4/12b",
    "bge-m3:latest": "manifests/registry.ollama.ai/library/bge-m3/latest",
}
total = 0
for name, rel in models.items():
    s = os.path.join(src, rel)
    if not os.path.isfile(s):
        raise SystemExit(f"ERROR: manifest が無い: {s}")
    d = os.path.join(dst, rel)
    os.makedirs(os.path.dirname(d), exist_ok=True)
    shutil.copy2(s, d)
    man = json.load(open(s))
    digests = [man["config"]["digest"]] + [l["digest"] for l in man["layers"]]
    n = 0
    for dig in digests:
        blob = "blobs/" + dig.replace(":", "-")
        bs, bd = os.path.join(src, blob), os.path.join(dst, blob)
        if not os.path.isfile(bs):
            raise SystemExit(f"ERROR: blob が無い: {bs}")
        if not os.path.exists(bd):
            shutil.copy2(bs, bd)
            total += os.path.getsize(bs)
        n += 1
    print(f"    bundled: {name} ({n} blobs)")
print(f"    合計 {total/1024**3:.2f} GiB")
PY

echo "[4-3] リランカー（int8 のみ。fp32 model.onnx は同梱しない）..."
RR_SRC="$RUNTIME/anythingllm-storage/models/onnx-community/bge-reranker-v2-m3-ONNX"
RR_DST="$PKG/assets/reranker/onnx-community/bge-reranker-v2-m3-ONNX"
mkdir -p "$RR_DST/onnx"
for f in config.json tokenizer.json tokenizer_config.json special_tokens_map.json; do
  [ -f "$RR_SRC/$f" ] || die "リランカーのファイルが無い: $f"
  cp -a "$RR_SRC/$f" "$RR_DST/$f"
done
[ -f "$RR_SRC/onnx/model_quantized.onnx" ] || die "リランカーの model_quantized.onnx が無い"
cp -a "$RR_SRC/onnx/model_quantized.onnx" "$RR_DST/onnx/model_quantized.onnx"
du -sh "$RR_DST" | sed 's/^/    /'

echo "[4-4] OCR 言語データ（tesseract jpn / eng）..."
mkdir -p "$PKG/assets/tesseract"
for f in jpn.traineddata eng.traineddata; do
  cp -a "$REPO_ROOT/windows-native/assets/tesseract/$f" "$PKG/assets/tesseract/$f"
done
du -sh "$PKG/assets/tesseract" | sed 's/^/    /'

echo "[4-5] スクリプト・設定・ドキュメント..."
cp -a "$LINUX_DIR/package/docker-compose.yml" "$PKG/docker-compose.yml"
cp -a "$LINUX_DIR/package/config" "$PKG/config"
cp -a "$LINUX_DIR/package/systemd" "$PKG/systemd"
for s in install.sh uninstall.sh start.sh stop.sh; do
  install -m 0755 "$LINUX_DIR/package/$s" "$PKG/$s"
done
# 導入先の事前調査スクリプト。install.sh と同じ階層（展開してすぐ見える位置）に置く。
# 🔴 内容は変更しないこと（main にコミット済み）。
install -m 0755 "$LINUX_DIR/survey-target.sh" "$PKG/survey-target.sh"
# 導入先担当者向けの手順書（開発者向けの linux-native/README.md ではない）
[ -f "$LINUX_DIR/INSTALL_GUIDE.md" ] || die "INSTALL_GUIDE.md がありません: $LINUX_DIR/INSTALL_GUIDE.md"
install -m 0644 "$LINUX_DIR/INSTALL_GUIDE.md" "$PKG/INSTALL_GUIDE.md"
[ -d "$REPO_ROOT/LICENSES" ] && cp -a "$REPO_ROOT/LICENSES" "$PKG/LICENSES"
[ -f "$REPO_ROOT/NOTICE" ] && cp -a "$REPO_ROOT/NOTICE" "$PKG/NOTICE"
[ -f "$REPO_ROOT/docs/MODEL_CARDS.md" ] && cp -a "$REPO_ROOT/docs/MODEL_CARDS.md" "$PKG/docs/MODEL_CARDS.md"

echo "[4-6] versions.lock..."
{
  echo "package_version=$VERSION"
  echo "platform=linux/amd64 (RHEL 9 / Docker + NVIDIA GPU)"
  echo "build_date=$(date -Iseconds)"
  echo "fork_commit=$(git -C "$FORK" rev-parse HEAD)"
  echo "fork_branch=$(git -C "$FORK" rev-parse --abbrev-ref HEAD)"
  echo "fork_dirty=$( [ -n "$(git -C "$FORK" status --porcelain)" ] && echo yes || echo no )"
  echo "image_anythingllm=$IMAGE_APP"
  echo "image_anythingllm_id=$(docker image inspect "$IMAGE_APP" --format '{{.Id}}')"
  echo "image_ollama=$OLLAMA_PIN_TAG"
  echo "image_ollama_id=$(docker image inspect "$OLLAMA_PIN_TAG" --format '{{.Id}}')"
  echo "image_ollama_source_digest=$OLLAMA_DIGEST"
  echo "models=gemma4:12b, bge-m3:latest"
  echo "reranker=onnx-community/bge-reranker-v2-m3-ONNX (int8, model_quantized.onnx)"
  echo "ocr=tesseract jpn+eng"
} > "$PKG/versions.lock"
sed 's/^/    /' "$PKG/versions.lock"

# ---------------------------------------------------------------- 5. チェックサム
# 網羅性検証（次工程）は install.sh が参照する checksums/package.sha256 の実在も見るため、
# 検証より先に生成する。
say "5. checksums/package.sha256 の生成"
( cd "$PKG" && find . -type f ! -path './checksums/*' -printf '%P\n' | LC_ALL=C sort \
    | xargs -d '\n' sha256sum > checksums/package.sha256 )
echo "    $(wc -l < "$PKG/checksums/package.sha256") ファイル"

# ---------------------------------------------------------------- 6. 同梱物の網羅性検証
say "6. 同梱物の網羅性検証"
bash "$LINUX_DIR/verify-package.sh" "$PKG"

# ---------------------------------------------------------------- 7. tar.gz 化
say "7. tar.gz 化"
TARBALL="$OUTPUT/$PKG_NAME.tar.gz"
# 中身の大半は圧縮済みバイナリ（GGUF / ONNX / gzip 済みイメージ）なので圧縮率はほぼ 1.0 だが、
# 受け取り側が `tar -xzf` で扱えるよう .tar.gz にそろえる。pigz -1 で時間コストを抑える。
if command -v pigz >/dev/null 2>&1; then
  tar -C "$OUTPUT" --owner=0 --group=0 --numeric-owner -cf - "$PKG_NAME" | pigz -1 -c > "$TARBALL"
else
  tar -C "$OUTPUT" --owner=0 --group=0 --numeric-owner -czf "$TARBALL" "$PKG_NAME"
fi
( cd "$OUTPUT" && sha256sum "$(basename "$TARBALL")" > "$(basename "$TARBALL").sha256" )

say "完了"
printf '  パッケージ  : %s\n' "$PKG"
printf '  配布物      : %s (%s バイト)\n' "$TARBALL" "$(stat -c%s "$TARBALL")"
printf '  sha256      : %s\n' "$(cut -d' ' -f1 "$TARBALL.sha256")"
echo
echo "  --- 同梱物の内訳 ---"
du -sh --apparent-size "$PKG"/images "$PKG"/models "$PKG"/assets "$PKG"/config "$PKG"/systemd 2>/dev/null | sed 's/^/    /'
du -sh --apparent-size "$PKG" | sed 's/^/    合計 /'
echo
echo "  次: GitHub Release へ分割アップロードする"
echo "      $LINUX_DIR/dist-split/split-release.sh $TARBALL"
