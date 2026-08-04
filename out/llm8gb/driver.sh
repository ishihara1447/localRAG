#!/usr/bin/env bash
# LLM 差し替え A/B（2026-08-04）
#   条件A（対照）: gemma4:12b     — 現行。VRAM 8.4GB で 8GB には載らない
#   条件B（候補）: granite4.1:8b  — IBM / Apache-2.0。VRAM 6.7GB
#
# 事前登録: docs/PREREG_LLM_8GB_SWAP_2026-08-04.md
#   sha256 41e175d21d8d8bc39e9b498a0115e1eb41f298776d359063d53fc6e8cba3f8ef
#
# 交互実行（A1→B1→A2→B2→A3→B3）。時間帯の揺れを両条件に等しく載せるため。
# 各 run の前に両モデルをアンロードする（コールド条件を対称にする）。

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
OUTDIR="out/llm8gb"
mkdir -p "$OUTDIR/raw"

OLLAMA_C="$(docker ps -qf name=ollama | head -1)"
[ -n "$OLLAMA_C" ] || { echo "ollama コンテナが見つかりません" >&2; exit 1; }

A_MODEL="gemma4:12b"
B_MODEL="granite4.1:8b"

unload_all() {
  docker exec "$OLLAMA_C" ollama stop "$A_MODEL" >/dev/null 2>&1 || true
  docker exec "$OLLAMA_C" ollama stop "$B_MODEL" >/dev/null 2>&1 || true
  sleep 3
}

run_one() {
  local label="$1" model="$2"
  echo "===== $label ($model) 開始 $(date '+%H:%M:%S') ====="
  unload_all
  CHAT_MODEL="$model" \
  HAKUSHO_SLUG="${HAKUSHO_SLUG:-ttft-hakusho}" \
  HAKUSHO_RUN="llm8gb-$label" \
  HAKUSHO_OUT="$OUTDIR/raw/$label.json" \
    uv run scripts/hakusho-eval.py > "$OUTDIR/raw/$label.log" 2>&1 || {
      echo "  !! $label が異常終了（ログ: $OUTDIR/raw/$label.log）"
    }
  # VRAM を実測して残す（判定基準 P5 の証跡）
  docker exec "$OLLAMA_C" ollama ps > "$OUTDIR/raw/$label.ps.txt" 2>&1 || true
  local total
  total="$(grep -oE '合計: [0-9]+/[0-9]+' "$OUTDIR/raw/$label.log" | tail -1 || echo '取得失敗')"
  echo "  $label: $total"
  echo "===== $label 終了 $(date '+%H:%M:%S') ====="
}

echo "開始: $(date '+%Y-%m-%d %H:%M:%S')"
for i in 1 2 3; do
  run_one "A$i" "$A_MODEL"
  run_one "B$i" "$B_MODEL"
done
echo "完了: $(date '+%Y-%m-%d %H:%M:%S')"
