#!/usr/bin/env bash
# install.sh のロールバックとパス正規化の単体テスト。
#
#   bash linux-native/tests/install-rollback-test.sh
#
# install.sh 全体は root・docker・11GB の配布物を要求するため通しでは実行できない。
# ここでは **install.sh から該当関数を抽出して**（写経せず）挙動を検証する。
# サンドボックス（tests/.work-rollback/）以外には触れない。
set -uo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SELF_DIR/../package/install.sh"
WORK="$SELF_DIR/.work-rollback"; rm -rf "$WORK"; mkdir -p "$WORK"
[ -f "$SRC" ] || { echo "対象がありません: $SRC" >&2; exit 1; }

PASS=0; FAIL=0
result() {
  if [ "$2" = "$3" ]; then printf '  \033[32mPASS\033[0m  %-46s %s\n' "$1" "$3"; PASS=$((PASS+1))
  else printf '  \033[31mFAIL\033[0m  %-46s 期待=%s 実際=%s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}

# 実コードから関数を抜き出す（写経しない）
extract() { sed -n "/^$1() {/,/^}/p" "$SRC"; }
ROLLBACK_FN="$(extract rollback)"
NORMALIZE_FN="$(extract normalize_path)"
[ -n "$ROLLBACK_FN" ]  || { echo "rollback() を抽出できません" >&2; exit 1; }
[ -n "$NORMALIZE_FN" ] || { echo "normalize_path() を抽出できません" >&2; exit 1; }

# ---------------------------------------------------------------- パス正規化
echo
echo "════ normalize_path（.env に //data を書かせない）════"
echo
norm() {
  local input="$1"
  ( die() { echo "DIE"; exit 9; }
    eval "$NORMALIZE_FN"
    normalize_path "$input" ) 2>/dev/null
}
result "末尾スラッシュを落とす"        "/opt/ote-rag"      "$(norm /opt/ote-rag/)"
result "二重スラッシュを畳む"          "/opt/ote-rag/data" "$(norm //opt//ote-rag//data)"
result "./ を解決する"                 "/opt/ote-rag/data" "$(norm /opt/ote-rag/./data)"
result "../ を解決する"                "/opt/data"         "$(norm /opt/ote-rag/../data)"
result "存在しないパスでも正規化する"  "/nonexistent/x/y"  "$(norm /nonexistent/x//y/)"
result "相対パスは die"                "DIE"               "$(norm relative/path)"

# ---------------------------------------------------------------- ロールバック
echo
echo "════ rollback（顧客データを絶対に消さない）════"
echo

# $1=ケース名 $2=データ配置(under|outside) $3=INSTALL_ROOT が既存か(0|1) $4=armed(0|1)
run_rollback() {
  local name="$1" layout="$2" preexist="$3" armed="$4"
  local root="$WORK/$name/opt/ote-rag" data
  mkdir -p "$root"
  if [ "$layout" = under ]; then data="$root/data"; else data="$WORK/$name/srv/ote-data"; fi
  mkdir -p "$data/anythingllm-storage"
  echo "CUSTOMER DOCUMENT" > "$data/anythingllm-storage/doc.txt"
  # プログラム側の成果物
  touch "$root/docker-compose.yml" "$root/start.sh" "$root/NOTICE" "$root/.env"
  mkdir -p "$root/config"; touch "$root/config/server.env"

  local out
  out="$(
    INSTALL_ROOT="$root" DATA_DIR="$data" \
    ROLLBACK_ARMED="$armed" INSTALL_ROOT_PREEXISTED="$preexist" \
    SYSTEMD_UNIT_INSTALLED=0 COMPOSE_STARTED=0 \
    bash -c '
      systemctl() { :; }; docker() { :; }
      '"$ROLLBACK_FN"'
      rollback
    ' 2>&1
  )"

  local doc=LOST prog=RESIDUAL
  [ -f "$data/anythingllm-storage/doc.txt" ] && doc=KEPT
  if [ ! -e "$root/start.sh" ] && [ ! -e "$root/NOTICE" ] && [ ! -e "$root/docker-compose.yml" ] \
     && [ ! -e "$root/config" ] && [ ! -e "$root/.env" ]; then prog=REMOVED; fi
  printf '%s/%s' "$doc" "$prog"
}

result "配下にデータ: program だけ消す"   "KEPT/REMOVED"   "$(run_rollback c1 under   0 1)"
result "配下外にデータ: 丸ごと消す"       "KEPT/REMOVED"   "$(run_rollback c2 outside 0 1)"
result "既存の配置先は消さない"           "KEPT/RESIDUAL"  "$(run_rollback c3 under   1 1)"
result "未 arm なら何もしない"            "KEPT/RESIDUAL"  "$(run_rollback c4 under   0 0)"

# systemd / compose の巻き戻しが呼ばれるか（スタブで呼び出しを記録）
echo
echo "════ rollback（systemd / compose の巻き戻し）════"
echo
# 実コードは呼び出しの出力を /dev/null に捨てるため、stdout では観測できない。
# スタブ側からファイルへ記録させる。
called() {
  local root="$WORK/c5/opt/ote-rag"; mkdir -p "$root"; touch "$root/docker-compose.yml"
  local log="$WORK/c5/calls.log"; : > "$log"
  INSTALL_ROOT="$root" DATA_DIR="$root/data" CALLLOG="$log" \
  ROLLBACK_ARMED=1 INSTALL_ROOT_PREEXISTED=1 \
  SYSTEMD_UNIT_INSTALLED=1 COMPOSE_STARTED=1 \
  bash -c '
    systemctl() { echo "systemctl $*" >> "$CALLLOG"; }
    docker()    { echo "docker $*"    >> "$CALLLOG"; }
    '"$ROLLBACK_FN"'
    rollback
  ' >/dev/null 2>&1
  grep -c . "$log"
}
n="$(called)"
result "systemd と compose の停止が呼ばれる" "true" "$([ "$n" -ge 2 ] && echo true || echo "false(呼び出し$n件)")"

echo
echo "──────────────────────────────────────────────"
printf '  合計: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
rm -rf "$WORK"
[ "$FAIL" -eq 0 ]
