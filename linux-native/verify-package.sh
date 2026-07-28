#!/usr/bin/env bash
# 配布パッケージの「同梱物の網羅性」を機械的に検証する。
#
#   ./verify-package.sh <パッケージディレクトリ>
#
# 目的: 「参照されているのに同梱されていないファイル」を検出する。
#       これがあると導入先で必ず失敗するため、ビルド時に落とす。
#
# 検査項目:
#   A. install.sh が参照する $PKG_ROOT 配下のパスがすべて実在するか
#   B. docker-compose.yml が参照する env_file / 変数がそろっているか
#   C. compose の image タグが、同梱イメージ tar の中身と一致するか
#   D. 同梱スクリプトに外部ネットワークへ出る処理が含まれていないか
#   E. systemd unit のプレースホルダを install.sh が確実に置換するか
set -uo pipefail

PKG="${1:?使い方: verify-package.sh <パッケージディレクトリ>}"
PKG="$(cd "$PKG" && pwd)"
LINUX_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="$PKG/install.sh"
COMPOSE="$PKG/docker-compose.yml"

fail=0
pass() { printf '  [OK]   %s\n' "$1"; }
bad()  { printf '  [NG]   %s\n' "$1" >&2; fail=$((fail + 1)); }
note() { printf '         %s\n' "$1"; }

[ -f "$INSTALL_SH" ] || { echo "ERROR: $INSTALL_SH がありません" >&2; exit 1; }
[ -f "$COMPOSE" ]    || { echo "ERROR: $COMPOSE がありません" >&2; exit 1; }

echo "=== 同梱物の網羅性検証: $PKG ==="

# ---------------------------------------------------------------- A
echo
echo "── A. install.sh が参照するパスの実在確認 ──"

# A-1: リテラル参照（$PKG_ROOT/xxx の形。変数が続くものは A-2 で扱う）
literals="$(grep -oE '\$PKG_ROOT/[A-Za-z0-9_./@:-]+' "$INSTALL_SH" | sed 's|^\$PKG_ROOT/||' | sort -u)"
n_lit=0
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  n_lit=$((n_lit + 1))
  if [ -e "$PKG/$rel" ]; then
    pass "$rel"
  else
    bad "$rel  ← install.sh が参照しているが同梱されていない"
  fi
done <<< "$literals"
note "リテラル参照 $n_lit 件"

# A-2: ループ変数経由の参照。install.sh の該当行が変わったら検証側も直す必要があるため、
#      行の存在をアサートしてから中身を確認する。
assert_line() {  # $1: 説明, $2: 完全一致で存在すべき行（前後の空白は無視）
  if grep -qF "$2" "$INSTALL_SH"; then
    return 0
  fi
  bad "install.sh の構造が変わりました（$1）。verify-package.sh を更新してください。"
  note "期待した行: $2"
  return 1
}

if assert_line "スクリプトのコピーループ" 'for s in start.sh stop.sh uninstall.sh; do'; then
  for s in start.sh stop.sh uninstall.sh; do
    [ -f "$PKG/$s" ] && pass "$s" || bad "$s ← install.sh がコピーするが同梱されていない"
  done
fi
if assert_line "付随ファイルのコピーループ" 'for f in NOTICE versions.lock INSTALL_GUIDE.md; do'; then
  for f in NOTICE versions.lock INSTALL_GUIDE.md; do
    # このループは [ -f ] ガード付きなので欠落しても致命ではないが、意図的に同梱するもの。
    [ -f "$PKG/$f" ] && pass "$f" || bad "$f ← 同梱すべきファイルが無い"
  done
fi
if assert_line "リランカー必須ファイルの確認ループ" 'for f in config.json tokenizer.json tokenizer_config.json onnx/model_quantized.onnx; do'; then
  for f in config.json tokenizer.json tokenizer_config.json onnx/model_quantized.onnx; do
    p="assets/reranker/onnx-community/bge-reranker-v2-m3-ONNX/$f"
    [ -f "$PKG/$p" ] && pass "$p" || bad "$p ← install.sh が起動前に必須と判定するが同梱されていない"
  done
fi
if assert_line "OCR 言語データのコピー" 'cp -a -f "$PKG_ROOT/assets/tesseract/jpn.traineddata" "$PKG_ROOT/assets/tesseract/eng.traineddata" \'; then
  for f in jpn.traineddata eng.traineddata; do
    [ -f "$PKG/assets/tesseract/$f" ] && pass "assets/tesseract/$f" || bad "assets/tesseract/$f ← 同梱されていない"
  done
fi
if assert_line "Ollama モデルの配置" 'cp -a -n "$PKG_ROOT/models/ollama/models/." "$DATA_DIR/ollama-models/models/" || true'; then
  for m in "registry.ollama.ai/library/gemma4/12b" "registry.ollama.ai/library/bge-m3/latest"; do
    mp="models/ollama/models/manifests/$m"
    if [ -f "$PKG/$mp" ]; then
      pass "$mp"
      # マニフェストが参照する blob がすべて同梱されているか
      missing="$(python3 - "$PKG/$mp" "$PKG/models/ollama/models/blobs" <<'PY'
import json, os, sys
man = json.load(open(sys.argv[1])); blobdir = sys.argv[2]
digs = [man["config"]["digest"]] + [l["digest"] for l in man["layers"]]
miss = [d for d in digs if not os.path.isfile(os.path.join(blobdir, d.replace(":", "-")))]
print("\n".join(miss))
PY
)"
      if [ -z "$missing" ]; then
        pass "  └ blob すべて同梱"
      else
        bad "  └ blob が欠落: $missing"
      fi
    else
      bad "$mp ← 同梱されていない"
    fi
  done
fi

# ---------------------------------------------------------------- B
echo
echo "── B. docker-compose.yml が参照する設定の確認 ──"
env_files="$(grep -oE '^\s+- \./config/[A-Za-z0-9_.-]+' "$COMPOSE" | sed 's|.*\./||' | sort -u)"
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  if [ -f "$PKG/$rel" ]; then
    pass "$rel（同梱済み）"
  elif [ -f "$PKG/$rel.template" ]; then
    pass "$rel（install.sh が $rel.template から生成）"
    if ! grep -q "config/$(basename "$rel").template" "$INSTALL_SH"; then
      bad "$rel.template はあるが install.sh がそれを生成に使っていない"
    fi
  else
    bad "$rel ← compose が env_file として要求するが、実体もテンプレートも無い"
  fi
done <<< "$env_files"

for v in OTE_RAG_DATA OTE_RAG_PORT OTE_RAG_BIND; do
  if grep -q "$v" "$COMPOSE"; then
    grep -q "$v=" "$INSTALL_SH" && pass "変数 $v は install.sh が .env に書き出す" \
      || bad "compose が使う変数 $v を install.sh が .env に書いていない"
  fi
done

# SELinux ラベルが全バインドマウントに付いているか
mounts="$(grep -cE '^\s+- \$\{OTE_RAG_DATA[^}]*\}[^:]*:[^:]+:z$' "$COMPOSE")"
all_binds="$(grep -cE '^\s+- \$\{OTE_RAG_DATA' "$COMPOSE")"
if [ "$mounts" -gt 0 ] && [ "$mounts" -eq "$all_binds" ]; then
  pass "バインドマウント $all_binds 件すべてに SELinux ラベル :z が付いている"
else
  bad "SELinux ラベル(:z)の無いバインドマウントがあります（:z 付き $mounts / 全 $all_binds）"
fi

# ---------------------------------------------------------------- C
echo
echo "── C. compose の image タグと同梱イメージ tar の一致 ──"
images="$(grep -oE '^\s+image: \S+' "$COMPOSE" | awk '{print $2}' | sort -u)"
while IFS= read -r tag; do
  [ -n "$tag" ] || continue
  found=""
  for t in "$PKG"/images/*.tar.gz "$PKG"/images/*.tar; do
    [ -f "$t" ] || continue
    # docker save の manifest.json に RepoTags が入っている
    if tar -xzOf "$t" manifest.json 2>/dev/null | grep -qF "\"$tag\"" \
       || tar -xOf "$t" manifest.json 2>/dev/null | grep -qF "\"$tag\""; then
      found="$t"; break
    fi
  done
  if [ -n "$found" ]; then
    pass "$tag → $(basename "$found") ($(stat -c%s "$found") バイト)"
  else
    bad "$tag ← compose が要求するイメージが images/ に同梱されていない"
  fi
  # install.sh 側の load 対象とも一致しているか
  grep -qF "$tag" "$INSTALL_SH" || bad "$tag を install.sh が docker load していない"
done <<< "$images"

# pull_policy: never が全サービスに付いているか（オフラインで pull されないこと）
svc_images="$(grep -cE '^\s+image: ' "$COMPOSE")"
svc_never="$(grep -cE '^\s+pull_policy: never' "$COMPOSE")"
[ "$svc_images" -eq "$svc_never" ] \
  && pass "全 $svc_images サービスに pull_policy: never" \
  || bad "pull_policy: never が足りません（image $svc_images / never $svc_never）"

# ---------------------------------------------------------------- D
echo
echo "── D. 外部ネットワークへ出る処理が無いことの確認 ──"
# survey-target.sh は「オフラインであることの確認」のために意図的に外へ出るので対象外。
scripts=("$PKG/install.sh" "$PKG/start.sh" "$PKG/stop.sh" "$PKG/uninstall.sh")
forbidden='docker pull|docker[[:space:]]+compose[[:space:]]+pull|ollama pull|(yum|dnf|apt-get|apt|rpm)[[:space:]]+(install|update|-i)|(curl|wget)[[:space:]]+[^|]*https?://|pip install|npm install|yarn install'
# 除外するもの:
#   ・コメント行（行番号の直後が # または 空白+#）
#   ・行頭がダブルクォートの行（エラーメッセージ本文。手作業での RPM 導入手順などを案内している）
hits="$(grep -nE "$forbidden" "${scripts[@]}" 2>/dev/null \
        | grep -vE ':[0-9]+:[[:space:]]*#' \
        | grep -vE ':[0-9]+:[[:space:]]*"')"
if [ -z "$hits" ]; then
  pass "install.sh / start.sh / stop.sh / uninstall.sh に外部取得処理なし"
else
  bad "外部へ出る処理が含まれています:"
  printf '%s\n' "$hits" | sed 's/^/           /' >&2
fi
# 参考情報（エラーにはしない）
if grep -q 'registry-1.docker.io' "$PKG/survey-target.sh" 2>/dev/null; then
  note "survey-target.sh は疎通確認のため意図的に外部へ出る（調査用のため対象外）"
fi

# ---------------------------------------------------------------- E
echo
echo "── E. systemd unit のプレースホルダ置換 ──"
UNIT="$PKG/systemd/ote-rag.service"
if [ -f "$UNIT" ]; then
  for ph in @INSTALL_ROOT@ @DOCKER@; do
    if grep -q "$ph" "$UNIT"; then
      grep -qF "s|$ph|" "$INSTALL_SH" \
        && pass "$ph を install.sh が置換する" \
        || bad "$ph が unit に残っているが install.sh が置換していない（起動に失敗します）"
    fi
  done
else
  bad "systemd/ote-rag.service が同梱されていない"
fi

# ---------------------------------------------------------------- F
echo
echo "── F. その他の同梱物 ──"
for p in survey-target.sh INSTALL_GUIDE.md NOTICE LICENSES versions.lock; do
  [ -e "$PKG/$p" ] && pass "$p" || bad "$p が同梱されていない"
done
# survey-target.sh はリポジトリ版と同一（改変していない）こと
if [ -f "$PKG/survey-target.sh" ] && [ -f "$LINUX_DIR/survey-target.sh" ]; then
  if cmp -s "$PKG/survey-target.sh" "$LINUX_DIR/survey-target.sh"; then
    pass "survey-target.sh はリポジトリ版と同一（無改変）"
  else
    bad "survey-target.sh がリポジトリ版と異なります（改変禁止）"
  fi
fi
if [ -x "$PKG/install.sh" ]; then pass "install.sh に実行権限あり"; else bad "install.sh に実行権限が無い"; fi
if [ -x "$PKG/survey-target.sh" ]; then pass "survey-target.sh に実行権限あり"; else bad "survey-target.sh に実行権限が無い"; fi

echo
if [ "$fail" -eq 0 ]; then
  echo "✅ 網羅性検証 PASS"
  exit 0
fi
echo "❌ 網羅性検証 FAIL: $fail 件" >&2
exit 1
