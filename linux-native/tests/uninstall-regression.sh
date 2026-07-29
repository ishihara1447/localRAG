#!/usr/bin/env bash
# package/uninstall.sh の回帰テスト。
#
#   bash linux-native/tests/uninstall-regression.sh
#
# 顧客文書を誤って削除しないことを検証する。サンドボックス（tests/.work/）に
# インストール先を模擬して実行するので、実システムには一切触れない。
# docker / systemctl はスタブに差し替える。
#
# 判定は「doc（顧客文書の生死）/prog（プログラムが消えたか）」の複合で行う。
# prog を見ないと「何も削除しないアンインストーラ」が全 PASS してしまうため
# （実際に v1 のテストはミューテーションで素通りした）。
#
# 唯一の改変: root チェック行の無効化のみ（テスト実行者が root でないため）。
#
# MUTANT_SRC=<path> を渡すと別実装を対象にできる（ミューテーション解析用）。
set -uo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BASE="$SELF_DIR/.work"; rm -rf "$BASE"; mkdir -p "$BASE"
NEW_SRC="${MUTANT_SRC:-$SELF_DIR/../package/uninstall.sh}"
if [ ! -f "$NEW_SRC" ]; then
  echo "エラー: 対象スクリプトが見つかりません: $NEW_SRC" >&2; exit 1
fi
STUB="$BASE/stubbin2"

mkdir -p "$STUB"
cat > "$STUB/docker" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "compose" ] && [ "${2:-}" = "down" ] && [ "${DOCKER_FAIL:-0}" = "1" ]; then
  echo "stub docker: compose down failed" >&2; exit 1
fi
exit 0
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/systemctl"
chmod +x "$STUB/docker" "$STUB/systemctl"

PASS=0; FAIL=0; FAILED_NAMES=()
result() {
  if [ "$2" = "$3" ]; then printf '  \033[32mPASS\033[0m  %-44s %s\n' "$1" "$3"; PASS=$((PASS+1))
  else printf '  \033[31mFAIL\033[0m  %-44s 期待=%s 実際=%s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); fi
}

# scenario <id> <old|new> <envspec> <datarel> [--check <rel>] [-- 追加引数...]
#   envspec: none | noline | 値テンプレート（@R@=インストール先ルート）
scenario() {
  local id="$1" variant="$2" envspec="$3" datarel="$4"; shift 4
  local checkrel="$datarel"
  if [ "${1:-}" = "--check" ]; then checkrel="$2"; shift 2; fi
  [ "${1:-}" = "--" ] && shift

  local root="$BASE/sb2/$variant.$id"; rm -rf "$root"; mkdir -p "$root"
  local src; [ "$variant" = old ] && src="$OLD_SRC" || src="$NEW_SRC"
  sed 's|^\[ "\$(id -u)" -eq 0 \].*|: # root check disabled|' "$src" > "$root/uninstall.sh"

  mkdir -p "$root/$datarel/anythingllm-storage"
  echo "CUSTOMER DOCUMENT" > "$root/$datarel/anythingllm-storage/doc.txt"
  touch "$root/docker-compose.yml" "$root/start.sh" "$root/NOTICE"
  # 「存在するが実際のデータ領域ではない」ディレクトリ（--data-dir 誤指定の検証用）
  mkdir -p "$root/other"

  case "$envspec" in
    none)   : ;;
    noline) printf 'SOMETHING_ELSE=1\n' > "$root/.env" ;;
    crlf)   printf 'OTE_RAG_DATA=%s/data\r\n' "$root" > "$root/.env" ;;
    *)      printf 'OTE_RAG_DATA=%s\n' "${envspec//@R@/$root}" > "$root/.env" ;;
  esac
  # 呼び出し側が @R@ を含む追加引数を渡せるようにする
  local -a args=(); local a
  for a in "$@"; do args+=("${a//@R@/$root}"); done

  local out code
  out="$(cd "$root" && PATH="$STUB:$PATH" bash "$root/uninstall.sh" -y ${args[@]+"${args[@]}"} 2>&1)"; code=$?

  local doc=LOST prog=RESIDUAL
  [ -f "$root/$checkrel/anythingllm-storage/doc.txt" ] && doc=KEPT
  # プログラムが本当に消えたか（v1 はここを見ていなかった）
  if [ ! -e "$root/start.sh" ] && [ ! -e "$root/NOTICE" ] && [ ! -e "$root/docker-compose.yml" ]; then
    prog=REMOVED
  fi

  if [ "$code" -ne 0 ]; then printf 'ABORT%s/%s' "$code" "$doc"
  else printf '%s/%s' "$doc" "$prog"; fi
}

echo
echo "════ A. 旧版が顧客文書を消す経路（現行版で塞げているか）════"
echo
echo "  ── 現行版 ──"
result "[new] .env なし"                  "ABORT2/KEPT"   "$(scenario a01 new none   data)"
result "[new] OTE_RAG_DATA 行なし"        "ABORT2/KEPT"   "$(scenario a02 new noline data)"
result "[new] CRLF 改行"                  "KEPT/REMOVED"  "$(scenario a03 new crlf data)"
result "[new] 引用符付き"                 "KEPT/REMOVED"  "$(scenario a04 new '"@R@/data"' data)"
result "[new] 末尾スラッシュ付き"         "KEPT/REMOVED"  "$(scenario a05 new '@R@/data/' data)"
result "[new] 二重スラッシュ //data"      "KEPT/REMOVED"  "$(scenario a06 new '@R@//data' data)"
result "[new] ./ を含む /./data"          "KEPT/REMOVED"  "$(scenario a07 new '@R@/./data' data)"
result "[new] データ領域==インストール先" "ABORT2/KEPT"   "$(scenario a08 new '@R@' data)"
result "[new] データ領域が / （上位）"    "ABORT2/KEPT"   "$(scenario a09 new '/' data)"
result "[new] 行末コメント付き"           "ABORT2/KEPT"   "$(scenario a10 new '@R@/data # 移設' data)"
result "[new] 打鍵ミス（存在しない）"     "ABORT2/KEPT"   "$(scenario a11 new '@R@/dataa' data)"
result "[new] 2階層下 var/data"           "KEPT/REMOVED"  "$(scenario a12 new '@R@/var/data' var/data)"
result "[new] 正常な .env（回帰）"        "KEPT/REMOVED"  "$(scenario a13 new '@R@/data' data)"
echo
echo "  （旧版比較は省略）"

echo
echo "════ B. --data-dir の指定違い ════"
echo
result "[new] 正しい場所を指定（復旧）"   "KEPT/REMOVED" "$(scenario b01 new none data -- --data-dir '@R@/data')"
result "[new] 存在しない場所を指定"       "ABORT2/KEPT"  "$(scenario b02 new none data -- --data-dir '@R@/nope')"
result "[new] 存在するが別の場所を指定"   "ABORT2/KEPT"  "$(scenario b03 new none data -- --data-dir '@R@/other')"
result "[new] 相対パスを拒否"             "ABORT2/KEPT"  "$(scenario b04 new none data -- --data-dir data)"
result "[new] 空文字を拒否"               "ABORT1/KEPT"  "$(scenario b05 new '@R@/data' data -- --data-dir '')"

echo
echo "════ C. シンボリックリンクと環境 ════"
echo
mkdir -p "$BASE/sb2"
# データ領域がシンボリックリンク経由（実体は realdata）
symcase() {
  local root="$BASE/sb2/new.c01"; rm -rf "$root"; mkdir -p "$root/realdata/anythingllm-storage"
  echo DOC > "$root/realdata/anythingllm-storage/doc.txt"; ln -s "$root/realdata" "$root/data"
  sed 's|^\[ "\$(id -u)" -eq 0 \].*|: |' "$NEW_SRC" > "$root/uninstall.sh"
  touch "$root/docker-compose.yml" "$root/start.sh" "$root/NOTICE"
  printf 'OTE_RAG_DATA=%s/data\n' "$root" > "$root/.env"
  local code; (cd "$root" && PATH="$STUB:$PATH" bash "$root/uninstall.sh" -y >/dev/null 2>&1); code=$?
  local doc=LOST; [ -f "$root/realdata/anythingllm-storage/doc.txt" ] && doc=KEPT
  local prog=RESIDUAL; [ ! -e "$root/start.sh" ] && prog=REMOVED
  [ "$code" -ne 0 ] && printf 'ABORT%s/%s' "$code" "$doc" || printf '%s/%s' "$doc" "$prog"
}
result "[new] データ領域がシンボリックリンク" "KEPT/REMOVED" "$(symcase)"
result "[new] export 接頭辞"               "KEPT/REMOVED" "$(scenario c02 new '@R@/data' data)"
# export 版は envspec 経路では書けないので個別に
expcase() {
  local root="$BASE/sb2/new.c03"; rm -rf "$root"; mkdir -p "$root/data/anythingllm-storage"
  echo DOC > "$root/data/anythingllm-storage/doc.txt"
  sed 's|^\[ "\$(id -u)" -eq 0 \].*|: |' "$NEW_SRC" > "$root/uninstall.sh"
  touch "$root/docker-compose.yml" "$root/start.sh" "$root/NOTICE"
  printf 'export OTE_RAG_DATA=%s/data\n' "$root" > "$root/.env"
  local code; (cd "$root" && PATH="$STUB:$PATH" bash "$root/uninstall.sh" -y >/dev/null 2>&1); code=$?
  local doc=LOST; [ -f "$root/data/anythingllm-storage/doc.txt" ] && doc=KEPT
  local prog=RESIDUAL; [ ! -e "$root/start.sh" ] && prog=REMOVED
  [ "$code" -ne 0 ] && printf 'ABORT%s/%s' "$code" "$doc" || printf '%s/%s' "$doc" "$prog"
}
result "[new] export OTE_RAG_DATA= 形式"    "KEPT/REMOVED" "$(expcase)"
result "[new] compose down 失敗時は中止"    "ABORT3/KEPT"  "$(DOCKER_FAIL=1 scenario c04 new '@R@/data' data)"
# docker コマンド自体が無い環境（PATH からスタブを外す）
nodockercase() {
  local root="$BASE/sb2/new.c05"; rm -rf "$root"; mkdir -p "$root/data/anythingllm-storage"
  echo DOC > "$root/data/anythingllm-storage/doc.txt"
  sed 's|^\[ "\$(id -u)" -eq 0 \].*|: |' "$NEW_SRC" > "$root/uninstall.sh"
  touch "$root/docker-compose.yml" "$root/start.sh" "$root/NOTICE"
  printf 'OTE_RAG_DATA=%s/data\n' "$root" > "$root/.env"
  # docker "だけ" が無い環境を作る。PATH を空にすると readlink/awk/rm まで消えて
  # 別の失敗（exit 127）になり、検証にならない。必要なコマンドだけを並べる。
  local minbin="$BASE/minbin"; rm -rf "$minbin"; mkdir -p "$minbin"
  local c p
  for c in readlink awk find grep rm rmdir sed cat ls mkdir touch ln id tail dirname basename; do
    p="$(command -v "$c" 2>/dev/null)" && ln -sf "$p" "$minbin/$c"
  done
  command -v docker >/dev/null 2>&1 && [ -e "$minbin/docker" ] && { echo "BUG:docker残存"; return; }
  local code; (cd "$root" && PATH="$minbin" /bin/bash "$root/uninstall.sh" -y >/dev/null 2>&1); code=$?
  local doc=LOST; [ -f "$root/data/anythingllm-storage/doc.txt" ] && doc=KEPT
  local prog=RESIDUAL; [ ! -e "$root/start.sh" ] && prog=REMOVED
  [ "$code" -ne 0 ] && printf 'ABORT%s/%s' "$code" "$doc" || printf '%s/%s' "$doc" "$prog"
}
result "[new] docker 不在でも詰まない"      "KEPT/REMOVED" "$(nodockercase)"

echo
echo "════ D. --purge（従来どおり全部消える）════"
echo
result "[new] --purge"                     "LOST/REMOVED" "$(scenario d01 new '@R@/data' data -- --purge)"

echo
echo "──────────────────────────────────────────────"
printf '  合計: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -gt 0 ] && printf '  失敗: %s\n' "${FAILED_NAMES[*]}"
[ "$FAIL" -eq 0 ]
