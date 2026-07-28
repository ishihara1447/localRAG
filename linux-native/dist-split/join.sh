#!/usr/bin/env bash
# 分割された OTE-RAG 配布物を結合し、SHA-256 で検証する。
#
# 使い方（分割ファイル・MANIFEST.txt・join.sh を同じディレクトリに置いて実行）:
#   bash join.sh
#
# 何をするか:
#   1. MANIFEST.txt から元ファイル名・サイズ・SHA-256 を読む
#   2. 各パートの SHA-256 を検証する（壊れているパートだけを特定できる）
#   3. パートを順に連結して元ファイルを復元する
#   4. 復元したファイルの SHA-256 を検証する
#
# インターネット接続は不要。
set -euo pipefail

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

MANIFEST="MANIFEST.txt"
[ -f "$MANIFEST" ] || { echo "エラー: $MANIFEST がありません。分割ファイルと同じ場所に置いてください。" >&2; exit 1; }

BASE="$(awk -F': *' '/^# 元ファイル:/{print $2; exit}' "$MANIFEST")"
SIZE="$(awk -F': *' '/^# 元サイズ/{print $2; exit}' "$MANIFEST" | awk '{print $1}')"
WANT="$(awk -F': *' '/^# 元SHA-256/{print $2; exit}' "$MANIFEST")"

[ -n "$BASE" ] || { echo "エラー: MANIFEST.txt から元ファイル名を読めません。" >&2; exit 1; }

echo "════════════════════════════════════════════════════"
echo " OTE-RAG 分割ファイルの結合"
echo "   復元先  : $DIR/$BASE"
echo "   サイズ  : ${SIZE:-不明} バイト"
echo "════════════════════════════════════════════════════"

# --- 1. パートの存在確認 ---
shopt -s nullglob
parts=("$BASE".[0-9][0-9][0-9])
shopt -u nullglob
expected="$(grep -cE '^[0-9a-f]{64}  ' "$MANIFEST" || true)"
echo
echo "[1/4] パートの確認: ${#parts[@]} 個（MANIFEST の記載: ${expected} 個）"
if [ "${#parts[@]}" -eq 0 ]; then
  echo "エラー: 分割ファイル（$BASE.001 など）が見つかりません。" >&2
  exit 1
fi
if [ "${#parts[@]}" -ne "$expected" ]; then
  echo "エラー: パート数が一致しません。ダウンロードが不足しています。" >&2
  echo "  必要なパート:" >&2
  grep -E '^[0-9a-f]{64}  ' "$MANIFEST" | awk '{print "    "$2}' >&2
  exit 1
fi

# --- 2. 各パートの検証 ---
echo "[2/4] 各パートの SHA-256 を検証しています..."
if ! grep -E '^[0-9a-f]{64}  ' "$MANIFEST" | sha256sum -c --quiet; then
  echo "エラー: 壊れているパートがあります（上に表示）。そのパートだけ再ダウンロードしてください。" >&2
  exit 1
fi
echo "       すべて一致"

# --- 3. 結合 ---
echo "[3/4] 結合しています（数分かかります）..."
rm -f "$BASE"
cat "${parts[@]}" > "$BASE"

if [ -n "$SIZE" ]; then
  actual_size="$(stat -c%s "$BASE")"
  if [ "$actual_size" != "$SIZE" ]; then
    echo "エラー: 復元したファイルのサイズが違います（$actual_size / 期待 $SIZE）。" >&2
    exit 1
  fi
fi

# --- 4. 全体の検証 ---
echo "[4/4] 復元したファイルの SHA-256 を検証しています..."
got="$(sha256sum "$BASE" | cut -d' ' -f1)"
if [ "$got" != "$WANT" ]; then
  echo "エラー: SHA-256 が一致しません。" >&2
  echo "  期待: $WANT" >&2
  echo "  実際: $got" >&2
  exit 1
fi

echo
echo "✅ 結合と検証が完了しました: $DIR/$BASE"
echo
echo "次の手順:"
echo "  tar -xzf $BASE"
echo "  cd ${BASE%.tar.gz}"
echo "  bash survey-target.sh          # まず前提条件を確認する"
echo "  sudo ./install.sh              # 問題が無ければインストール"
echo
echo "（結合後は分割ファイル $BASE.0?? を削除して容量を空けられます）"
