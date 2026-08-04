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

echo "[3/3] 結合スクリプトと照合ファイルを配置中..."
cp "$(dirname "$0")/Join-OTE-RAG.cmd" "$OUT/" 2>/dev/null || true
# 開発者向けの README.md（gh release create の手順など）は顧客に配らない。
# 代わりに、このフォルダで何をすればよいかだけを書いた案内を生成する。
cat > "$OUT/README.txt" <<EOF
OTE-RAG インストール手順（このフォルダ）

1. Join-OTE-RAG.cmd をダブルクリックしてください。
   分割ファイルを1つに結合し、壊れていないか自動で検証します。
   完了すると $BASE ができます。

2. OTE-RAG-Setup.exe を右クリックして「管理者として実行」を選んでください。
   「WindowsによってPCが保護されました」と出たら
   「詳細情報」→「実行」を押してください（署名を付けていないため出ます）。

3. 結合が終われば、分割ファイル（.001 〜）は削除して構いません。

必要な空き容量: 開始時に 40GB 以上（インストール後の製品本体は約10GB）

うまくいかない場合は、この画面の表示内容を保守担当へお送りください。
EOF

# 🔴 .sha256 は必ず同梱すること。
#    OTE-RAG-Setup.exe は zip と同じ場所の "<zip名>.sha256" を**必須**とし、
#    無ければ起動直後に「SHA-256 の照合ファイルが見つかりません」で終了する
#    （setup/OTE-RAG-Setup.cs の PackageLocator）。
#    Join-OTE-RAG.cmd も期待値をこのファイルから読む
#    （MANIFEST.txt は UTF-8、バッチは CP932 で日本語ラベルを照合できないため）。
if [ -f "$SRC.sha256" ]; then
  cp "$SRC.sha256" "$OUT/"
else
  ( cd "$(dirname "$SRC")" && sha256sum "$BASE" > "$OUT/${BASE}.sha256" )
fi
[ -s "$OUT/${BASE}.sha256" ] || { echo "エラー: ${BASE}.sha256 を用意できませんでした" >&2; exit 1; }

echo
echo "完了: $OUT"
ls -la --block-size=M "$OUT" | tail -n +2 | awk '{printf "  %8s  %s\n", $5, $9}'
echo
echo "次: gh release create でアップロードする（README.md 参照）"
