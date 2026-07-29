#!/usr/bin/env bash
# OTE-RAG をアンインストールする。
#
#   sudo /opt/ote-rag/uninstall.sh              # プログラムのみ削除（文書データは残す）
#   sudo /opt/ote-rag/uninstall.sh --purge      # 文書データとモデルも削除（元に戻せない）
#   sudo /opt/ote-rag/uninstall.sh --keep-images  # Docker イメージを残す
#   sudo /opt/ote-rag/uninstall.sh --data-dir /srv/ote-rag-data
#                                               # .env が失われた場合にデータ領域を明示する
#
# 既定では文書データ（<データ領域>/anythingllm-storage）を削除しない。
# データ領域を特定できない場合は、削除せずに中止する（誤ってデータを消さないため）。
set -euo pipefail

INSTALL_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PURGE=0
KEEP_IMAGES=0
ASSUME_YES=0
DATA_DIR_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --purge)       PURGE=1; shift ;;
    --keep-images) KEEP_IMAGES=1; shift ;;
    -y|--yes)      ASSUME_YES=1; shift ;;
    --data-dir)
      [ $# -ge 2 ] && [ -n "$2" ] || {
        echo "エラー: --data-dir にはパスを指定してください。" >&2; exit 1; }
      DATA_DIR_OVERRIDE="$2"; shift 2 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "不明なオプション: $1" >&2; exit 1 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo "エラー: root 権限が必要です。 sudo $0" >&2; exit 1; }

DATA_DIR=""
DATA_DIR_SOURCE=""
if [ -n "$DATA_DIR_OVERRIDE" ]; then
  DATA_DIR="$DATA_DIR_OVERRIDE"
  DATA_DIR_SOURCE="--data-dir"
elif [ -f "$INSTALL_ROOT/.env" ]; then
  # 値に = を含む場合に備え、最初の = 以降をすべて取る（awk $2 では切れる）。
  # `export OTE_RAG_DATA=...` も docker compose は受け付けるので同じく認識する。
  DATA_DIR="$(awk '/^[[:space:]]*(export[[:space:]]+)?OTE_RAG_DATA[[:space:]]*=/{sub(/^[^=]*=/, ""); print}' \
                "$INSTALL_ROOT/.env" | tail -1)"
  DATA_DIR_SOURCE="$INSTALL_ROOT/.env"
fi

# 値の正規化。CR（CRLF 改行）・前後空白・引用符・末尾スラッシュのいずれか一つでも
# 残っていると、以降のパス比較が静かに外れてデータ保護が効かなくなる。
DATA_DIR="${DATA_DIR%$'\r'}"
DATA_DIR="${DATA_DIR#"${DATA_DIR%%[![:space:]]*}"}"
DATA_DIR="${DATA_DIR%"${DATA_DIR##*[![:space:]]}"}"
case "$DATA_DIR" in
  \"*\") DATA_DIR="${DATA_DIR#\"}"; DATA_DIR="${DATA_DIR%\"}" ;;
  \'*\') DATA_DIR="${DATA_DIR#\'}"; DATA_DIR="${DATA_DIR%\'}" ;;
esac
while [ "$DATA_DIR" != "/" ] && [ "${DATA_DIR%/}" != "$DATA_DIR" ]; do
  DATA_DIR="${DATA_DIR%/}"
done

# 相対パスは以降のパス比較（INSTALL_ROOT 配下かの判定）が必ず外れ、
# 保護されないまま削除される。絶対パス以外は受け付けない。
if [ -n "$DATA_DIR" ]; then
  case "$DATA_DIR" in
    /*) : ;;
    *)
      echo "エラー: データ領域は絶対パスで指定してください（現在: $DATA_DIR）。" >&2
      echo "  取得元: ${DATA_DIR_SOURCE:-不明}" >&2
      exit 2 ;;
  esac
fi

# 🔴 fail-closed: データ領域を特定できないまま削除に進まない。
# 既定構成ではデータがプログラム本体（/opt/ote-rag）の下に同居しているため、
# ここで進むと --purge を指定していなくても文書データごと消える。
if [ "$PURGE" -eq 0 ] && [ -z "$DATA_DIR" ]; then
  echo "エラー: データ領域の場所を特定できませんでした。" >&2
  if [ -f "$INSTALL_ROOT/.env" ]; then
    echo "  $INSTALL_ROOT/.env に OTE_RAG_DATA= の行が見つかりません。" >&2
  else
    echo "  $INSTALL_ROOT/.env が見つかりません。" >&2
  fi
  echo "  このまま進むと文書データごと削除される可能性があるため、中止しました。" >&2
  echo "" >&2
  echo "  対処:" >&2
  echo "    データ領域が分かる場合   : sudo $0 --data-dir /path/to/data" >&2
  echo "    データごと削除してよい場合: sudo $0 --purge" >&2
  exit 2
fi

# 🔴 実体パスに正規化してから比較する。
# 文字列の前方一致だけでは `//data` `./data` シンボリックリンク等で判定が外れ、
# 「データは残しました」と表示しながら消すという最悪の失敗をする。
# `--install-root /opt/ote-rag/`（末尾スラッシュ）で install.sh が .env に
# `OTE_RAG_DATA=/opt/ote-rag//data` を書くため、これは正式な操作だけで起きる。
INSTALL_ROOT_REAL="$(readlink -f -- "$INSTALL_ROOT")"
DATA_DIR_REAL=""
if [ -n "$DATA_DIR" ]; then
  # 存在しないデータ領域は「特定できていない」のと同じ。守る対象を確定できない。
  if [ ! -d "$DATA_DIR" ]; then
    if [ "$PURGE" -eq 0 ]; then
      echo "エラー: データ領域が見つかりません: $DATA_DIR" >&2
      echo "  取得元: ${DATA_DIR_SOURCE:-不明}" >&2
      echo "  場所を確定できないため、誤って削除しないよう中止しました。" >&2
      echo "" >&2
      echo "  対処:" >&2
      echo "    正しい場所を指定する    : sudo $0 --data-dir /path/to/data" >&2
      echo "    データごと削除してよい場合: sudo $0 --purge" >&2
      exit 2
    fi
  else
    DATA_DIR_REAL="$(readlink -f -- "$DATA_DIR")"
  fi
fi

if [ "$PURGE" -eq 0 ] && [ -n "$DATA_DIR_REAL" ]; then
  # データ領域がプログラム本体そのもの／その上位を指している場合、
  # 「データ以外だけ消す」ことが原理的に不可能なので中止する。
  if [ "$DATA_DIR_REAL" = "$INSTALL_ROOT_REAL" ] || [ "$DATA_DIR_REAL" = "/" ]; then
    echo "エラー: データ領域がプログラムの配置先と同じ場所を指しています。" >&2
    echo "  データ    : $DATA_DIR (-> $DATA_DIR_REAL)" >&2
    echo "  プログラム: $INSTALL_ROOT (-> $INSTALL_ROOT_REAL)" >&2
    echo "  文書だけを残して削除することができないため中止しました。" >&2
    echo "  データごと削除してよい場合: sudo $0 --purge" >&2
    exit 2
  fi
  case "$INSTALL_ROOT_REAL/" in
    "$DATA_DIR_REAL"/*)
      echo "エラー: データ領域がプログラムの配置先の上位を指しています。" >&2
      echo "  データ    : $DATA_DIR (-> $DATA_DIR_REAL)" >&2
      echo "  プログラム: $INSTALL_ROOT (-> $INSTALL_ROOT_REAL)" >&2
      echo "  .env の OTE_RAG_DATA を確認してください。中止しました。" >&2
      exit 2 ;;
  esac
fi

echo "════════════════════════════════════════════════════════"
echo " OTE-RAG のアンインストール"
echo "   プログラム: $INSTALL_ROOT"
echo "   データ    : ${DATA_DIR:-（不明）}${DATA_DIR_SOURCE:+  （$DATA_DIR_SOURCE より）}"
if [ "$PURGE" -eq 1 ]; then
  echo "   🔴 --purge が指定されています。文書データとモデルも削除します（元に戻せません）。"
else
  echo "   文書データとモデルは残します（削除するには --purge）。"
fi
echo "════════════════════════════════════════════════════════"

if [ "$ASSUME_YES" -eq 0 ]; then
  printf '続行しますか？ [y/N]: '
  read -r ans
  case "$ans" in [yY]*) ;; *) echo "中止しました。"; exit 0 ;; esac
fi

# 1. サービス停止・削除
if [ -f "$INSTALL_ROOT/docker-compose.yml" ] && ! command -v docker >/dev/null 2>&1; then
  # docker が無い環境では停止すべきコンテナも存在しない。ここで中止すると
  # 「Docker を先に消した顧客がアンインストールできなくなる」ため続行する。
  echo "[1/5] docker コマンドが見つかりません。コンテナの停止をスキップします。"
elif [ -f "$INSTALL_ROOT/docker-compose.yml" ]; then
  echo "[1/5] コンテナを停止・削除しています..."
  # ここを握り潰すと、docker-compose.yml を消したあとに動いたままのコンテナが残り、
  # 停止手段が失われる。失敗したら削除に進まず中止する。
  if ! ( cd "$INSTALL_ROOT" && docker compose down --remove-orphans ); then
    echo "エラー: コンテナの停止に失敗しました。" >&2
    echo "  プログラム本体を削除すると docker-compose.yml が失われ、" >&2
    echo "  残ったコンテナを停止できなくなるため中止しました。" >&2
    echo "  手動で停止してから再実行してください:" >&2
    echo "    cd $INSTALL_ROOT && docker compose down --remove-orphans" >&2
    exit 3
  fi
fi

# 2. systemd
if command -v systemctl >/dev/null 2>&1 && [ -f /etc/systemd/system/ote-rag.service ]; then
  echo "[2/5] systemd の登録を解除しています..."
  systemctl disable --now ote-rag.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/ote-rag.service
  systemctl daemon-reload || true
fi

# 3. Docker イメージ
if [ "$KEEP_IMAGES" -eq 0 ]; then
  echo "[3/5] Docker イメージを削除しています..."
  docker image rm localrag-anythingllm:1.1.0 >/dev/null 2>&1 || true
  docker image rm ollama/ollama:0.30.11 >/dev/null 2>&1 || true
else
  echo "[3/5] Docker イメージは残します（--keep-images）。"
fi

# 4. データ
if [ "$PURGE" -eq 1 ] && [ -n "$DATA_DIR" ] && [ -d "$DATA_DIR" ]; then
  echo "[4/5] データを削除しています: $DATA_DIR"
  rm -rf "${DATA_DIR:?}/ollama-models" "${DATA_DIR:?}/anythingllm-storage"
  rmdir "$DATA_DIR" 2>/dev/null || true
elif [ "$PURGE" -eq 1 ]; then
  # --purge だがデータ領域を特定できない。プログラム本体の下に同居していれば
  # 次の [5/5] で消える。誤解を招かないよう「残した」とは言わない。
  echo "[4/5] データ領域を特定できませんでした（${DATA_DIR:-未設定}）。"
  echo "      $INSTALL_ROOT の下にある分は次の手順で削除されます。"
else
  echo "[4/5] データは残しました: $DATA_DIR"
fi

# 5. プログラム本体（データがこの中にある場合は --purge のときだけ消す）
echo "[5/5] プログラムを削除しています: $INSTALL_ROOT"
KEEP_ENTRY=""
if [ "$PURGE" -eq 0 ] && [ -n "$DATA_DIR_REAL" ]; then
  # 実体パスどうしで比較する（文字列前方一致は //data ./data symlink で外れる）。
  case "$DATA_DIR_REAL" in
    "$INSTALL_ROOT_REAL"/*)
      # データが INSTALL_ROOT の下にある構成。直下の何を残せば守れるかを求める。
      # 例: DATA_DIR=/opt/ote-rag/var/data なら var ごと残す（保守的側に倒す）。
      rel="${DATA_DIR_REAL#"$INSTALL_ROOT_REAL"/}"
      KEEP_ENTRY="${rel%%/*}"
      ;;
  esac
fi

# 削除対象の一覧を作る。残す対象は文字列の完全一致で判定する
# （find -name/-path はグロブ解釈されるため、パスに [ や * を含むと保護が外れる）。
# 隠しファイル（.env 等）も対象に含めるため 3 種のグロブを列挙する。
# dangling symlink は -e が偽になるので -L も見る（消し残しを防ぐ）。
DOOMED=()
for entry in "$INSTALL_ROOT_REAL"/* "$INSTALL_ROOT_REAL"/.[!.]* "$INSTALL_ROOT_REAL"/..?*; do
  { [ -e "$entry" ] || [ -L "$entry" ]; } || continue
  if [ -n "$KEEP_ENTRY" ] && [ "$entry" = "$INSTALL_ROOT_REAL/$KEEP_ENTRY" ]; then
    continue
  fi
  DOOMED+=("$entry")
done

# 🔴 最後の砦。実際に消す直前に、消える範囲へ文書データが紛れ込んでいないか確かめる。
# --data-dir に「存在するが実際とは違う場所」を渡された場合、ここまでの検査は
# すべて通ってしまう（パスとしては正当なため）。消す直前の中身で判断する。
if [ "$PURGE" -eq 0 ] && [ ${#DOOMED[@]} -gt 0 ]; then
  for entry in "${DOOMED[@]}"; do
    # 深さで打ち切らない。-maxdepth 3 では ROOT/a/b/c/data/anythingllm-storage を
    # 見逃し、「データは残しました」と表示しながら文書を消していた（実測）。
    # -print -quit で最初の1件が見つかった時点で止まるので、走査コストは小さい。
    if find "$entry" \( -name anythingllm-storage -o -name ollama-models \) \
         -print -quit 2>/dev/null | grep -q .; then
      echo "エラー: 削除しようとしている場所に文書データが含まれています。" >&2
      echo "  検出場所: $entry" >&2
      echo "  データ領域の指定（${DATA_DIR:-未特定}）が実際の配置と食い違っています。" >&2
      echo "  取得元: ${DATA_DIR_SOURCE:-不明}" >&2
      echo "  文書を失わないよう中止しました。--data-dir で正しい場所を指定してください。" >&2
      exit 2
    fi
  done
fi

RM_FAILED=0
for entry in ${DOOMED[@]+"${DOOMED[@]}"}; do
  rm -rf "$entry" || RM_FAILED=1
done
if [ "$RM_FAILED" -eq 1 ]; then
  echo "警告: 一部のファイルを削除できませんでした（$INSTALL_ROOT_REAL を確認してください）。" >&2
fi

if [ -n "$KEEP_ENTRY" ]; then
  echo "  データ（$DATA_DIR）は残しました。"
else
  # 残すものが無いので入れ物ごと削除する。
  rmdir "$INSTALL_ROOT_REAL" 2>/dev/null || rm -rf "${INSTALL_ROOT_REAL:?}"
fi

echo
echo "アンインストールが完了しました。"
if [ "$PURGE" -eq 0 ]; then
  echo "文書データとモデルは ${DATA_DIR:-（不明）} に残っています。"
  echo "完全に削除するには手動で削除するか、再インストール後に --purge で実行してください。"
fi
