#!/usr/bin/env bash
# OTE-RAG 配布zipを GitHub Release へアップロードできるサイズに分割する。
#
# 背景: 配布zipは約10.5GB。GitHubの制限は通常push 100MB / LFS 2GB /
#       Releasesアセット 2GB のため、単体では置けない。
#
# 方式: 素のバイト分割。ただしパート名を `.001` `.002` … とすることで
#       **7-Zip が分割書庫として自動認識**し、.001 を右クリックするだけで
#       結合できる。7-Zip が無い環境でも Windows標準の `copy /b`
#       （同梱の Join-OTE-RAG.cmd）で復元でき、どちらの経路でも復元可能。
#
# 使い方:
#   ./split-release.sh /mnt/c/LocalRAG/dist/OTE-RAG-win64-v1.2.7.zip
set -euo pipefail

SRC="${1:?使い方: split-release.sh <配布zipのパス>}"
[ -f "$SRC" ] || { echo "ERROR: ファイルが無い: $SRC" >&2; exit 1; }

# GitHub Releases のアセット上限は 2GiB。安全側に 1,900,000,000 バイト（約1.77GiB）で刻む。
CHUNK=1900000000
OUT="$(dirname "$SRC")/parts"
BASE="$(basename "$SRC")"

mkdir -p "$OUT"
rm -f "$OUT/${BASE}."[0-9][0-9][0-9] "$OUT/MANIFEST.txt" 2>/dev/null || true

SIZE=$(stat -c%s "$SRC")
echo "元ファイル : $BASE"
echo "サイズ     : $SIZE バイト ($((SIZE/1024/1024)) MB)"
echo "分割単位   : $CHUNK バイト"
echo "予想分割数 : $(( (SIZE + CHUNK - 1) / CHUNK ))"
echo

echo "[1/3] 分割中..."
# 7-Zip互換の連番（.001 始まり）にする
split -b "$CHUNK" -d -a 3 --numeric-suffixes=1 "$SRC" "$OUT/${BASE}."

echo "[2/3] 各パートの SHA-256 を計算中..."
{
  echo "# OTE-RAG 分割配布マニフェスト"
  echo "# 生成: $(date -Iseconds)"
  echo "#"
  echo "# 元ファイル: $BASE"
  echo "# 元サイズ  : $SIZE バイト"
  echo "# 元SHA-256 : $(sha256sum "$SRC" | cut -d' ' -f1)"
  echo "#"
  echo "# 結合手順は同ディレクトリの Join-OTE-RAG.cmd を参照。"
  echo "# 各パートのSHA-256:"
  for f in "$OUT/${BASE}."[0-9][0-9][0-9]; do
    echo "$(sha256sum "$f" | cut -d' ' -f1)  $(basename "$f")"
  done
} > "$OUT/MANIFEST.txt"

echo "[3/3] 結合スクリプトを配置中..."
cp "$(dirname "$0")/Join-OTE-RAG.cmd" "$OUT/" 2>/dev/null || true
cp "$(dirname "$0")/README.md" "$OUT/" 2>/dev/null || true

echo
echo "完了: $OUT"
ls -la --block-size=M "$OUT" | tail -n +2 | awk '{printf "  %8s  %s\n", $5, $9}'
echo
echo "次: gh release create でアップロードする（README.md 参照）"
