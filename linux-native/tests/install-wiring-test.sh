#!/usr/bin/env bash
# install.sh の「ロールバックの配線」を検証する。
#
#   bash linux-native/tests/install-wiring-test.sh
#
# install-rollback-test.sh は rollback 関数“だけ”を抽出して検証しており、
# 関数を呼ぶ側（trap / ROLLBACK_ARMED=1 / INSTALL_OK=1 の位置）を一切見ていない。
# そのため「ロールバックを絶対に呼ばない install.sh」も全 PASS してしまう。
# ここでは install.sh を実際に走らせ、配線が機能していることを確かめる。
#
# 実行方法: 依存コマンド（docker/systemctl/id/…）をスタブに差し替え、
# 偽の配布物ディレクトリを作って install.sh をサンドボックスへインストールさせる。
# 実システム（/opt, /etc/systemd/system, 実 docker）には一切触れない。
set -uo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# MUTANT_SRC=<path> で別実装を対象にできる（ミューテーション解析用）。
SRC="${MUTANT_SRC:-$SELF_DIR/../package/install.sh}"
PKGSRC="$SELF_DIR/../package"
WORK="$SELF_DIR/.work-wiring"; rm -rf "$WORK"; mkdir -p "$WORK"
[ -f "$SRC" ] || { echo "対象がありません: $SRC" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] && { echo "root では実行しないでください（実システムを変更する恐れ）" >&2; exit 1; }

PASS=0; FAIL=0
result() {
  if [ "$2" = "$3" ]; then printf '  \033[32mPASS\033[0m  %-44s %s\n' "$1" "$3"; PASS=$((PASS+1))
  else printf '  \033[31mFAIL\033[0m  %-44s 期待=%s 実際=%s\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}

# ---------------------------------------------------------------- 偽の配布物
mkpkg() { # $1: 配布物ルート
  local p="$1"; mkdir -p "$p/config" "$p/systemd" "$p/images" "$p/models" "$p/assets"
  cp "$PKGSRC/docker-compose.yml" "$p/docker-compose.yml"
  cp "$PKGSRC/systemd/ote-rag.service" "$p/systemd/ote-rag.service"
  cp "$PKGSRC/config/ollama.env" "$p/config/ollama.env"
  cp "$PKGSRC/config/server.env.template" "$p/config/server.env.template"
  cp "$PKGSRC/config/collector.env.template" "$p/config/collector.env.template"
  for s in start.sh stop.sh uninstall.sh; do cp "$PKGSRC/$s" "$p/$s"; done
  printf 'dummy\n' > "$p/NOTICE"; printf 'dummy\n' > "$p/versions.lock"
  printf 'dummy\n' > "$p/INSTALL_GUIDE.md"
  cp "$SELF_DIR/../survey-target.sh" "$p/survey-target.sh"
  # install.sh の前提条件検査が要求するファイルを空で用意する（中身は使わない。
  # --skip-checksum と docker スタブにより、実際に読まれることはない）。
  local mf="$p/models/ollama/models/manifests/registry.ollama.ai/library"
  mkdir -p "$mf/gemma4" "$mf/bge-m3" "$p/models/ollama/models/blobs" \
           "$p/assets/reranker/hotchpotch/japanese-reranker-xsmall-v2/onnx" \
           "$p/assets/tesseract"
  printf 'x\n' > "$mf/gemma4/12b"
  printf 'x\n' > "$mf/bge-m3/latest"
  printf 'x\n' > "$p/models/ollama/models/blobs/sha256-dummy"
  local rr="$p/assets/reranker/hotchpotch/japanese-reranker-xsmall-v2"
  printf 'x\n' > "$rr/onnx/model_quantized.onnx"
  for f in config.json tokenizer.json tokenizer_config.json; do printf '{}\n' > "$rr/$f"; done
  printf 'x\n' > "$p/assets/tesseract/jpn.traineddata"
  printf 'x\n' > "$p/assets/tesseract/eng.traineddata"
  printf 'x\n' > "$p/images/localrag-anythingllm-1.1.0.tar.gz"
  printf 'x\n' > "$p/images/ollama-0.30.11.tar.gz"
  cp "$SRC" "$p/install.sh"
}

# 依存コマンドのスタブ。DOCKER_FAIL_AT で失敗地点を注入する。
mkstub() { # $1: スタブ置き場
  local s="$1"; mkdir -p "$s"
  cat > "$s/docker" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  compose)
    case "${2:-}" in
      config) [ "${DOCKER_FAIL_AT:-}" = "config" ] && { echo "injected compose failure" >&2; exit 1; }; exit 0 ;;
      up)     [ "${DOCKER_FAIL_AT:-}" = "up" ]     && { echo "injected up failure" >&2; exit 1; }; exit 0 ;;
      down)   [ -n "${CALLLOG:-}" ] && echo "compose down" >> "$CALLLOG"; exit 0 ;;
    esac; exit 0 ;;
  # 起動待ちループの `docker inspect --format ...` はヘルス状態を読む。
  # HEALTH_STATUS で「healthy（すぐ完了）」「missing（起動失敗）」を切り替える。
  inspect) echo "${HEALTH_STATUS:-healthy}"; exit 0 ;;
  image|load) echo "ok"; exit 0 ;;
  run) exit 0 ;;
esac
exit 0
EOF
  # 起動待ちで「コンテナが見つからない」を作るため inspect は missing を返させる
  cat > "$s/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "$s/nvidia-smi" <<'EOF'
#!/usr/bin/env bash
echo "NVIDIA-SMI stub"; exit 0
EOF
  # 非 root では chown が必ず失敗する（製品は root 実行が前提）。
  # ここを素通しにしないと、配線ではなく権限で落ちてしまい検証にならない。
  cat > "$s/chown" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$s/docker" "$s/systemctl" "$s/nvidia-smi" "$s/chown"
}

# install.sh を実行する。root チェックと重い処理はスキップ用の引数で回避する。
run_install() { # $1: ケース名, 残り: install.sh への追加引数
  local name="$1"; shift
  local base="$WORK/$name"; mkdir -p "$base"
  local pkg="$base/pkg" root="$base/opt/ote-rag" stub="$base/stub"
  mkpkg "$pkg"; mkstub "$stub"
  # root チェックのみ無効化（それ以外のロジックは無改変）。
  # 置換できたことを必ず確認する。無効化に失敗すると全ケースが「root 権限が必要」で
  # 終了し、何も起きていないのに REMOVED が観測されて偽の PASS になる（実際に一度やった）。
  sed 's|^if \[ "\$(id -u)" -ne 0 \]; then|if false; then|' "$pkg/install.sh" > "$pkg/install.test.sh"
  if ! grep -q '^if false; then' "$pkg/install.test.sh"; then
    echo "テストの前提が壊れています: root チェックを無効化できませんでした" >&2
    exit 1
  fi
  # --data-dir と --no-systemd は既定で付けるが、呼び出し側が
  # NO_DATA_DIR=1 / WITH_SYSTEMD=1 を指定すると外せる。
  # 固定していると .env 引き継ぎ経路と systemd 経路を一度も通らず、
  # それらの実装をまるごと消してもテストが気づかない（実測で確認済み）。
  # 🔴 ポートを明示する。既定の 3001 は開発機で製品が稼働していると衝突し、
  #    install.sh が「別のプログラムが使用中」で die する（テストの本題と無関係な失敗）。
  #    3001 を避けた固定値を使う（テスト用サンドボックスなので実際には listen しない）。
  local -a opts=(--install-root "$root" --port "${TEST_PORT:-39001}" --skip-checksum -y)
  [ "${NO_DATA_DIR:-0}" = 1 ] || opts+=(--data-dir "$base/data")
  [ "${WITH_SYSTEMD:-0}" = 1 ] || opts+=(--no-systemd)
  ( cd "$pkg" && CALLLOG="$base/calls.log" PATH="$stub:$PATH" \
      OTE_RAG_TEST_SYSTEMD_UNIT="${TEST_UNIT:-}" bash "$pkg/install.test.sh" \
      "${opts[@]}" "$@" ) >"$base/out.log" 2>&1
  echo $?
}

installed() { # $1: ケース名 -> INSTALLED / REMOVED
  local root="$WORK/$1/opt/ote-rag"
  if [ -f "$root/docker-compose.yml" ] && [ -f "$root/.env" ]; then echo INSTALLED; else echo REMOVED; fi
}

echo
echo "════ ロールバックの配線（install.sh を実際に走らせる）════"
echo

# 1. compose 検証で失敗 → ロールバックが発火して配置物が消えること
code=$(DOCKER_FAIL_AT=config run_install w1)
result "compose 検証失敗でロールバックする" "1/REMOVED" "$code/$(installed w1)"

# 2. 正常終了 → ロールバックせず配置物が残ること
code=$(run_install w2)
result "正常時はロールバックしない"        "0/INSTALLED" "$code/$(installed w2)"

# 3. データ領域が作られた後に失敗した場合、データは消さないこと。
#    compose 検証(step 5)はデータ作成(step 6)より前なので、w1 ではデータが
#    そもそも存在しない。ここでは起動(step 8)で失敗させる。
code=$(DOCKER_FAIL_AT=up run_install w3)
d=LOST; [ -f "$WORK/w3/data/anythingllm-storage/models/hotchpotch/japanese-reranker-xsmall-v2/config.json" ] && d=KEPT
result "起動失敗でもデータ領域は残す"      "1/REMOVED/KEPT" "$code/$(installed w3)/$d"

# 4. 起動後にコンテナが消えた場合は、インストールを巻き戻さない（exit 3）。
#    ここを die にすると、配置は正しいのに全部消えてしまう。
code=$(HEALTH_STATUS=missing run_install w4)
result "起動確認の失敗では巻き戻さない"    "3/INSTALLED" "$code/$(installed w4)"

# 5. 起動後に失敗したら、コンテナを止めてから巻き戻すこと。
#    これを怠ると compose ファイルを消した後にコンテナだけが残り、
#    ポートを掴んだまま再インストールもできなくなる。
#    w3（起動に成功した後 chown 等で失敗）で down が呼ばれたかを見る。
down_called=NO
[ -f "$WORK/w3/calls.log" ] && grep -q 'compose down' "$WORK/w3/calls.log" && down_called=YES
result "巻き戻し前にコンテナを停止する"    "YES" "$down_called"

echo
echo "════ データ領域の引き継ぎと保護 ════"
echo

# 6. --data-dir 未指定＋既存 .env → 記録された場所を引き継ぐ。
#    引き継ぎを消すとここが落ちる。
prep_env() { # $1=ケース名 $2=.env に書く値
  local base="$WORK/$1"; mkdir -p "$base/opt/ote-rag"
  printf 'OTE_RAG_DATA=%s\n' "$2" > "$base/opt/ote-rag/.env"
}
mkdir -p "$WORK/w5/prev-data"
prep_env w5 "$WORK/w5/prev-data"
code=$(NO_DATA_DIR=1 run_install w5)
inherited=NO
grep -q "OTE_RAG_DATA=$WORK/w5/prev-data" "$WORK/w5/opt/ote-rag/.env" 2>/dev/null && inherited=YES
result "既存 .env のデータ領域を引き継ぐ"  "0/YES" "$code/$inherited"

# 7. .env に危険な値（/）→ 中止する。
#    `//*` の glob が一致しない問題で、以前は全ガードを素通りしていた。
prep_env w6 "/"
code=$(NO_DATA_DIR=1 run_install w6)
# 🔴 終了コードだけを見てはいけない。ガードを外しても、非 root で / に書けず
#    別の理由で exit 1 になり偽の PASS になる（ミューテーションで実測）。
#    「なぜ止まったか」まで確認する。
reason=NO
grep -q 'データ領域に / は指定できません' "$WORK/w6/out.log" 2>/dev/null && reason=YES
result "危険なデータ領域（/）は中止する"    "1/YES" "$code/$reason"

echo
echo "════ systemd unit の保護 ════"
echo

# 8. 既存 unit がある状態で失敗 → 元の内容が復元される。
mkdir -p "$WORK/w7"; U="$WORK/w7/ote-rag.service"; printf 'OLD-UNIT\n' > "$U"
code=$(TEST_UNIT="$U" WITH_SYSTEMD=1 DOCKER_FAIL_AT=up run_install w7)
restored=NO; grep -q 'OLD-UNIT' "$U" 2>/dev/null && restored=YES
result "失敗時に既存 unit を復元する"      "1/YES" "$code/$restored"

# 9. 退避が取れない場合は中止する（続行すると復元不能になるため）。
#    退避先を書けないディレクトリにして再現する。
mkdir -p "$WORK/w8/ro"; U8="$WORK/w8/ro/ote-rag.service"; printf 'KEEP-ME\n' > "$U8"; chmod 500 "$WORK/w8/ro"
code=$(TEST_UNIT="$U8" WITH_SYSTEMD=1 run_install w8)
kept=NO; grep -q 'KEEP-ME' "$U8" 2>/dev/null && kept=YES
chmod 700 "$WORK/w8/ro" 2>/dev/null
result "退避できないなら顧客 unit を触らない" "1/YES" "$code/$kept"

echo
echo "──────────────────────────────────────────────"
printf '  合計: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || printf '  ログ: %s/*/out.log\n' "$WORK"
[ "$FAIL" -eq 0 ]
