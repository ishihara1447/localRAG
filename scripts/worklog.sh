#!/usr/bin/env bash
# docs/WORKLOG.md へ作業記録を1件追記する。
#
# なぜ必要か:
#   docs/HANDOFF.md は「現在地」を毎回書き換える形式なので、
#   「何を試して、何が失敗して、なぜそうしたか」の時系列が残らない。
#   セッションをまたぐと、同じ失敗を繰り返す・撤回済みの数値を再び持ち出す、
#   といった事故が起きる（実際に複数回起きている）。
#   WORKLOG.md は追記専用で、過去のエントリを書き換えない。
#
# 使い方:
#   scripts/worklog.sh "見出し" <<'EOF'
#   本文（markdown。何行でも可）
#   EOF
#
#   scripts/worklog.sh "見出し" -m "本文を1行で"
#
# 追記される内容には、日時・git HEAD・ブランチが自動で入る。
# 「そのとき何がコミットされていたか」を後から追えるようにするため。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="$REPO_ROOT/docs/WORKLOG.md"

if [ $# -lt 1 ]; then
  echo "使い方: $0 \"見出し\" [-m \"本文\"]" >&2
  echo "        本文を標準入力から渡す場合は -m を省く" >&2
  exit 1
fi

TITLE="$1"; shift
BODY=""
if [ "${1:-}" = "-m" ]; then
  BODY="${2:?-m の後に本文を指定してください}"
else
  # 標準入力が端末の場合は本文なしとして扱う（見出しだけの記録を許す）
  if [ ! -t 0 ]; then
    BODY="$(cat)"
  fi
fi

TS="$(date '+%Y-%m-%d %H:%M')"
HEAD_SHA="$(cd "$REPO_ROOT" && git rev-parse --short HEAD 2>/dev/null || echo '(git外)')"
BRANCH="$(cd "$REPO_ROOT" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '-')"
DIRTY=""
if [ -n "$(cd "$REPO_ROOT" && git status --porcelain 2>/dev/null)" ]; then
  DIRTY=" / 未コミットの変更あり"
fi

if [ ! -f "$LOG" ]; then
  echo "エラー: $LOG がありません。先に作成してください。" >&2
  exit 1
fi

# 見出し行（## で始まる最初の行）の直前に挿入する＝新しいものが上に来る。
# 追記位置を固定するためのマーカーを使う。
MARKER='<!-- 新しい記録はこの行のすぐ下に入る -->'
if ! grep -qF "$MARKER" "$LOG"; then
  echo "エラー: $LOG に挿入位置のマーカーがありません: $MARKER" >&2
  exit 1
fi

ENTRY_FILE="$(mktemp)"
trap 'rm -f "$ENTRY_FILE"' EXIT
{
  echo
  echo "## $TS — $TITLE"
  echo
  echo "\`$BRANCH\` @ \`$HEAD_SHA\`$DIRTY"
  if [ -n "$BODY" ]; then
    echo
    echo "$BODY"
  fi
} > "$ENTRY_FILE"

# マーカー行の後ろにエントリを差し込む
awk -v marker="$MARKER" -v entry="$ENTRY_FILE" '
  { print }
  index($0, marker) && !done {
    while ((getline line < entry) > 0) print line
    close(entry)
    done = 1
  }
' "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"

echo "記録しました: $TS — $TITLE"
echo "  → $LOG"
