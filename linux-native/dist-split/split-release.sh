#!/usr/bin/env bash
# OTE-RAG Linux 配布物を GitHub Release へアップロードできるサイズに分割する。
#
# 背景: 配布物は約12GB。GitHub Releases のアセット上限は 2GiB のため、単体では置けない。
#
# 方式: 素のバイト分割。パート名を `.001` `.002` … とする。
#       結合は同梱の join.sh（Linux 側で実行）で行う。
#       windows-native/dist-split/split-release.sh と同じ方式なので、
#       7-Zip がある Windows 端末で .001 を右クリックして結合することもできる。
#
# 使い方:
#   ./split-release.sh /path/to/ote-rag-linux-x64-v1.1.0.tar.gz
#
# 出力: <配布物と同じディレクトリ>/parts/
#   ote-rag-linux-x64-v1.1.0.tar.gz.001 …
#   MANIFEST.txt   （元ファイルと各パートの SHA-256）
#   join.sh        （結合スクリプト）
#   README.md      （受け取り側の手順）
set -euo pipefail

SRC="${1:?使い方: split-release.sh <配布物のパス>}"
[ -f "$SRC" ] || { echo "ERROR: ファイルが無い: $SRC" >&2; exit 1; }

# GitHub Releases のアセット上限は 2GiB。安全側に 1,900,000,000 バイト（約1.77GiB）で刻む。
CHUNK=1900000000
OUT="$(dirname "$SRC")/parts"
BASE="$(basename "$SRC")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$OUT"
rm -f "$OUT/${BASE}."[0-9][0-9][0-9] "$OUT/MANIFEST.txt" 2>/dev/null || true

SIZE=$(stat -c%s "$SRC")
echo "元ファイル : $BASE"
echo "サイズ     : $SIZE バイト ($((SIZE / 1024 / 1024)) MB)"
echo "分割単位   : $CHUNK バイト"
echo "予想分割数 : $(((SIZE + CHUNK - 1) / CHUNK))"
echo

echo "[1/3] 分割中..."
split -b "$CHUNK" -d -a 3 --numeric-suffixes=1 "$SRC" "$OUT/${BASE}."

echo "[2/3] 各パートの SHA-256 を計算中..."
{
  echo "# OTE-RAG Linux 分割配布マニフェスト"
  echo "# 生成: $(date -Iseconds)"
  echo "#"
  echo "# 元ファイル: $BASE"
  echo "# 元サイズ  : $SIZE バイト"
  echo "# 元SHA-256 : $(sha256sum "$SRC" | cut -d' ' -f1)"
  echo "#"
  echo "# 結合手順は同ディレクトリの join.sh / README.md を参照。"
  echo "# 各パートのSHA-256:"
  for f in "$OUT/${BASE}."[0-9][0-9][0-9]; do
    echo "$(sha256sum "$f" | cut -d' ' -f1)  $(basename "$f")"
  done
} > "$OUT/MANIFEST.txt"

echo "[3/3] 結合スクリプトを配置中..."
install -m 0755 "$SCRIPT_DIR/join.sh" "$OUT/join.sh"
[ -f "$SCRIPT_DIR/README.md" ] && install -m 0644 "$SCRIPT_DIR/README.md" "$OUT/README.md"

echo
echo "完了: $OUT"
ls -l --block-size=M "$OUT" | tail -n +2 | awk '{printf "  %8s  %s\n", $5, $9}'
echo
echo "次: gh release create でアップロードする"
