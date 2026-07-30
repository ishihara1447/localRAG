#!/usr/bin/env bash
# OTE-RAG Linux オフラインインストーラ（RHEL 9 / Docker + NVIDIA GPU 想定）
#
# 使い方（配布物を展開したディレクトリで、root 権限で実行）:
#   sudo ./install.sh
#   sudo ./install.sh --data-dir /var/lib/ote-rag --port 3001
#   sudo ./install.sh --help
#
# 🔴 このスクリプトはインターネットへ一切アクセスしない。
#    docker pull / ollama pull / dnf(yum) install / curl による外部取得は含まない。
#    同梱物だけでインストールが完結する。
#
# 何度実行しても壊れない（冪等）。既存の文書データ（anythingllm-storage 配下の
# documents / lancedb / *.db）は上書きしない。

set -euo pipefail

# ---------------------------------------------------------------- 既定値
PKG_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ROOT="/opt/ote-rag"
DATA_DIR=""              # 未指定なら <INSTALL_ROOT>/data
PORT="3001"
BIND="127.0.0.1"
WITH_SYSTEMD=1
SKIP_CHECKSUM=0
FORCE=0
START_AFTER_INSTALL=1
ASSUME_YES=0

# コンテナ内のユーザー（anything-llm/docker/Dockerfile の ARG_UID/ARG_GID）
APP_UID=1000
APP_GID=1000

IMAGE_APP="localrag-anythingllm:1.1.0"
IMAGE_OLLAMA="ollama/ollama:0.30.11"

# 必要な空き容量（GiB）
NEED_DATA_GIB=12
NEED_DOCKER_GIB=10
NEED_ROOT_GIB=1

# ---------------------------------------------------------------- 表示
STEP_TOTAL=9
step_no=0
step()  { step_no=$((step_no + 1)); printf '\n[%d/%d] %s\n' "$step_no" "$STEP_TOTAL" "$1"; }
info()  { printf '       %s\n' "$1"; }
ok()    { printf '  [OK] %s\n' "$1"; }
warn()  { printf '  [注意] %s\n' "$1" >&2; }
die() {
  printf '\n════════════════════════════════════════════════════════\n' >&2
  printf 'エラー: %s\n' "$1" >&2
  shift || true
  for line in "$@"; do printf '  %s\n' "$line" >&2; done
  printf '\nインストールを中止しました。環境は変更していません（またはこの時点までの変更のみ）。\n' >&2
  printf '\n詳しい状況は次のコマンドで確認できます（読み取りのみ・環境は変更しません）:\n' >&2
  printf '    bash %s/survey-target.sh\n' "$PKG_ROOT" >&2
  printf '  その出力をそのまま保守担当へお送りいただければ原因を特定できます。\n' >&2
  printf '════════════════════════════════════════════════════════\n' >&2
  exit 1
}

usage() {
  cat <<'USAGE'
OTE-RAG Linux オフラインインストーラ

  sudo ./install.sh [オプション]

オプション:
  --install-root <dir>  プログラムの配置先（既定: /opt/ote-rag）
  --data-dir <dir>      モデルと文書データの配置先（既定: <install-root>/data）
                        約 11GB を使う。/var など容量に余裕のある場所を指定できる。
  --port <n>            Web UI のポート（既定: 3001）
  --bind <addr>         Web UI を公開するアドレス（既定: 127.0.0.1）
                        LAN の他の端末から使う場合のみ 0.0.0.0 を指定する。
                        🔴 その場合は必ず先に UI で管理者パスワードを設定すること。
  --no-systemd          systemd への自動起動登録を行わない
  --no-start            インストール後にサービスを起動しない
  --skip-checksum       配布物の SHA-256 検証を省略（開発用途のみ。通常は使わない）
  --force               推奨環境を満たさない場合でも続行する（GPU メモリ不足など）
  -y, --yes             確認プロンプトに自動で「はい」と答える
  -h, --help            このヘルプ
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --install-root) INSTALL_ROOT="${2:?--install-root にディレクトリを指定してください}"; shift 2 ;;
    --data-dir)     DATA_DIR="${2:?--data-dir にディレクトリを指定してください}"; shift 2 ;;
    --port)         PORT="${2:?--port に番号を指定してください}"; shift 2 ;;
    --bind)         BIND="${2:?--bind にアドレスを指定してください}"; shift 2 ;;
    --no-systemd)   WITH_SYSTEMD=0; shift ;;
    --no-start)     START_AFTER_INSTALL=0; shift ;;
    --skip-checksum) SKIP_CHECKSUM=1; shift ;;
    --force)        FORCE=1; shift ;;
    -y|--yes)       ASSUME_YES=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) die "不明なオプション: $1" "--help でオプション一覧を表示できます。" ;;
  esac
done

# 🔴 パスを正規化する。ここで正規化しないと `--install-root /opt/ote-rag/`（タブ補完が
#    付ける末尾スラッシュ）が .env に `OTE_RAG_DATA=/opt/ote-rag//data` として書き込まれ、
#    uninstall.sh 側のパス比較が外れて顧客文書を巻き込む事故につながる。
#    readlink -m は対象が存在しなくても正規化できる（-f は途中の要素の存在を要求する）。
normalize_path() {  # $1: パス（絶対でなければエラー）
  case "$1" in
    /*) readlink -m -- "$1" ;;
    *)  die "パスは絶対パスで指定してください（指定値: $1）" ;;
  esac
}
INSTALL_ROOT="$(normalize_path "$INSTALL_ROOT")"

# 🔴 再インストール時は、既存の .env に記録されたデータ領域を引き継ぐ。
# これをしないと、--data-dir で別の場所を指定して導入した顧客が
# `sudo ./install.sh` を素で再実行しただけで、データ領域が既定
# （<install-root>/data）に切り替わる。旧データは消えないが製品からは
# 見えなくなり、画面には「文書データとモデルは保持されます」と出る。
# しかも旧 .env を上書きするため、後から旧データの場所を知る手段が失われる。
if [ -z "$DATA_DIR" ] && [ -f "$INSTALL_ROOT/.env" ]; then
  prev_data="$(awk '/^[[:space:]]*(export[[:space:]]+)?OTE_RAG_DATA[[:space:]]*=/{sub(/^[^=]*=/, ""); print}' \
                 "$INSTALL_ROOT/.env" 2>/dev/null | tail -1)"
  prev_data="${prev_data%$'\r'}"
  prev_data="${prev_data#"${prev_data%%[![:space:]]*}"}"
  prev_data="${prev_data%"${prev_data##*[![:space:]]}"}"
  case "$prev_data" in
    \"*\") prev_data="${prev_data#\"}"; prev_data="${prev_data%\"}" ;;
    \'*\') prev_data="${prev_data#\'}"; prev_data="${prev_data%\'}" ;;
  esac
  if [ -n "$prev_data" ]; then
    DATA_DIR="$prev_data"
    info "既存のデータ領域を引き継ぎます: $DATA_DIR"
    info "  （変更する場合は --data-dir で明示してください）"
  fi
fi

[ -n "$DATA_DIR" ] || DATA_DIR="$INSTALL_ROOT/data"
DATA_DIR="$(normalize_path "$DATA_DIR")"

if [ "$DATA_DIR" = "$INSTALL_ROOT" ]; then
  die "データ領域とプログラムの配置先に同じパスは指定できません（$INSTALL_ROOT）。" \
      "アンインストール時にデータだけを残すことができなくなります。"
fi

# 🔴 システムディレクトリを配置先にすると、アンインストール時に
#    その配下を丸ごと削除しようとする。専用ディレクトリ以外は受け付けない。
case "$INSTALL_ROOT" in
  / | /usr | /usr/* | /etc | /var | /opt | /home | /root | /boot | /bin | /sbin \
  | /lib | /lib32 | /lib64 | /libx32 | /srv | /tmp | /dev | /proc | /sys | /run)
    die "配置先に $INSTALL_ROOT は指定できません。" \
        "専用のディレクトリを指定してください（例: /opt/ote-rag）。" ;;
esac

# データ領域が配置先の上位を指していると、アンインストール時に
# 「データだけ残す」ことができず中止するしかなくなる（削除手段が失われる）。
case "$INSTALL_ROOT/" in
  "$DATA_DIR"/*)
    die "データ領域（$DATA_DIR）がプログラムの配置先（$INSTALL_ROOT）の上位です。" \
        "アンインストール時にデータだけを残せなくなるため、別の場所を指定してください。" ;;
esac

# ---------------------------------------------------------------- ロールバック
# 途中で失敗したときに「半インストール状態」を残さない。
# 🔴 ただしデータ領域（顧客文書・モデル）は何があっても削除しない。
INSTALL_OK=0
ROLLBACK_ARMED=0
INSTALL_ROOT_PREEXISTED=0
SYSTEMD_UNIT_INSTALLED=0
SYSTEMD_UNIT_BACKUP=""     # 既存 unit を上書きする場合の退避先
COMPOSE_STARTED=0
SYSTEMD_UNIT_PATH="${SYSTEMD_UNIT_PATH:-/etc/systemd/system/ote-rag.service}"

rollback() {
  [ "$ROLLBACK_ARMED" -eq 1 ] || return 0
  ROLLBACK_ARMED=0   # 再入防止
  # 巻き戻しの途中で中断されると、半端に消えた状態が残る。ここでは割り込みを無視する。
  trap '' INT TERM HUP
  local keep e
  printf '\n--- 変更を巻き戻しています ---\n' >&2

  if [ "$COMPOSE_STARTED" -eq 1 ] && [ -f "$INSTALL_ROOT/docker-compose.yml" ]; then
    if ( cd "$INSTALL_ROOT" && docker compose down --remove-orphans ) >/dev/null 2>&1; then
      printf '  コンテナを停止しました\n' >&2
    else
      printf '  [注意] コンテナの停止に失敗しました。手動で確認してください:\n' >&2
      printf '         cd %s && docker compose down\n' "$INSTALL_ROOT" >&2
    fi
  fi

  if [ "$SYSTEMD_UNIT_INSTALLED" -eq 1 ]; then
    systemctl disable --now ote-rag.service >/dev/null 2>&1 || true
    if [ -n "$SYSTEMD_UNIT_BACKUP" ] && [ -f "$SYSTEMD_UNIT_BACKUP" ]; then
      # アップグレードの失敗。元からあった unit を戻す。
      # 消してしまうと顧客は実行前より悪い状態で取り残される。
      mv -f "$SYSTEMD_UNIT_BACKUP" "$SYSTEMD_UNIT_PATH"
      systemctl daemon-reload >/dev/null 2>&1 || true
      systemctl enable ote-rag.service >/dev/null 2>&1 || true
      printf '  既存の systemd unit を復元しました（%s）\n' "$SYSTEMD_UNIT_PATH" >&2
    else
      # 新規インストールの失敗。自分が作った unit を消す。
      rm -f "$SYSTEMD_UNIT_PATH"
      systemctl daemon-reload >/dev/null 2>&1 || true
      printf '  systemd の登録を解除しました\n' >&2
    fi
  fi

  if [ "$INSTALL_ROOT_PREEXISTED" -eq 1 ]; then
    printf '  %s は元からあったため残しました\n' "$INSTALL_ROOT" >&2
  elif [ -d "$INSTALL_ROOT" ]; then
    case "$DATA_DIR/" in
      "$INSTALL_ROOT"/*)
        # データ領域が配置先の下にある構成。データ以外だけを消す。
        keep="${DATA_DIR#"$INSTALL_ROOT"/}"; keep="${keep%%/*}"
        for e in "$INSTALL_ROOT"/* "$INSTALL_ROOT"/.[!.]* "$INSTALL_ROOT"/..?*; do
          { [ -e "$e" ] || [ -L "$e" ]; } || continue
          [ -n "$keep" ] && [ "$e" = "$INSTALL_ROOT/$keep" ] && continue
          rm -rf "$e" 2>/dev/null || true
        done
        printf '  %s のプログラムを削除しました（データ %s は残しています）\n' \
               "$INSTALL_ROOT" "$DATA_DIR" >&2 ;;
      *)
        rm -rf "${INSTALL_ROOT:?}" 2>/dev/null \
          && printf '  %s を削除しました\n' "$INSTALL_ROOT" >&2 ;;
    esac
  fi

  printf '  Docker イメージとデータ領域は残しています（再実行時に再利用されます）\n' >&2
  printf '  同じコマンドでやり直せます。\n' >&2
}
trap '[ "$INSTALL_OK" -eq 1 ] || rollback' EXIT

printf '════════════════════════════════════════════════════════\n'
printf ' OTE-RAG Linux オフラインインストーラ\n'
printf ' 配布物   : %s\n' "$PKG_ROOT"
printf ' 配置先   : %s\n' "$INSTALL_ROOT"
printf ' データ   : %s\n' "$DATA_DIR"
printf ' Web UI   : http://%s:%s\n' "$BIND" "$PORT"
printf '════════════════════════════════════════════════════════\n'

# --- 🔴 LAN 公開の警告（--bind が loopback 以外のとき） ---
if [ "$BIND" != "127.0.0.1" ] && [ "$BIND" != "localhost" ] && [ "$BIND" != "::1" ]; then
  cat >&2 <<WARNBIND

🔴🔴🔴 警告: Web UI を loopback 以外（$BIND）へ公開しようとしています 🔴🔴🔴

  OTE-RAG は初回起動時、まだ管理者パスワードが設定されていません。
  この状態で LAN へ公開すると、同じネットワーク上の誰でも次のことができます。

    ・取り込んだ文書をすべて閲覧・ダウンロードする
    ・管理者としてログインし、設定を変更する
    ・API キーを取得する
      （2026-07-15 に修正した「管理者パスワード未設定時に /system/api-keys が
        誰でも読める」問題は、到達できないことを前提に loopback 既定にしています）

  正しい手順:
    1. まず既定（--bind 127.0.0.1）でインストールする
    2. サーバー上のブラウザ、または SSH ポート転送で Web UI を開く
         ssh -L 3001:127.0.0.1:$PORT <このサーバー>
    3. 管理者パスワードを設定する
    4. そのうえで $INSTALL_ROOT/.env の OTE_RAG_BIND を 0.0.0.0 に変更し、
       stop.sh → start.sh で反映する
    5. ファイアウォール（firewalld）で接続元を絞る

WARNBIND
  if [ "$ASSUME_YES" -eq 0 ] && [ "$FORCE" -eq 0 ]; then
    if [ -t 0 ]; then
      printf '  危険性を理解したうえで %s へ公開して続行しますか？ [y/N]: ' "$BIND" >&2
      read -r _bind_ans
      case "$_bind_ans" in
        [yY]*) printf '  続行します。インストール後すぐに管理者パスワードを設定してください。\n\n' >&2 ;;
        *) printf '  中止しました。--bind を付けずに実行すると loopback 既定になります。\n' >&2; exit 1 ;;
      esac
    else
      die "対話できない環境で --bind $BIND が指定されました。" \
          "危険性を理解したうえで実行する場合は --yes を併記してください。"
    fi
  else
    printf '  （--yes / --force が指定されているため確認を省略しました）\n\n' >&2
  fi
fi

# ================================================================
step "前提条件を確認しています"
# ================================================================

# --- root 権限 ---
if [ "$(id -u)" -ne 0 ]; then
  die "root 権限が必要です。" \
      "次のように実行してください:  sudo ./install.sh"
fi
ok "root 権限"

# --- アーキテクチャ ---
arch="$(uname -m)"
if [ "$arch" != "x86_64" ]; then
  die "この配布物は x86_64 専用です（このマシンは $arch）。" \
      "別アーキテクチャ向けの配布物が必要です。保守担当へご連絡ください。"
fi
ok "アーキテクチャ x86_64"

# --- 配布物の中身が揃っているか（この時点で分かる欠落は先に落とす） ---
for required in \
  "$PKG_ROOT/docker-compose.yml" \
  "$PKG_ROOT/config/server.env.template" \
  "$PKG_ROOT/config/collector.env.template" \
  "$PKG_ROOT/config/ollama.env" \
  "$PKG_ROOT/start.sh" \
  "$PKG_ROOT/stop.sh" \
  "$PKG_ROOT/uninstall.sh" \
  "$PKG_ROOT/systemd/ote-rag.service" \
  "$PKG_ROOT/survey-target.sh" \
  "$PKG_ROOT/images/localrag-anythingllm-1.1.0.tar.gz" \
  "$PKG_ROOT/images/ollama-0.30.11.tar.gz" \
  "$PKG_ROOT/models/ollama/models/manifests/registry.ollama.ai/library/gemma4/12b" \
  "$PKG_ROOT/models/ollama/models/manifests/registry.ollama.ai/library/bge-m3/latest" \
  "$PKG_ROOT/assets/reranker/onnx-community/bge-reranker-v2-m3-ONNX/onnx/model_quantized.onnx" \
  "$PKG_ROOT/assets/tesseract/jpn.traineddata" \
  "$PKG_ROOT/assets/tesseract/eng.traineddata" \
; do
  [ -e "$required" ] || die "配布物が不完全です。次のファイルがありません:" "$required" \
      "ダウンロードした分割ファイルの結合に失敗しているか、展開が途中で終わっている可能性があります。" \
      "INSTALL_GUIDE.md の「転送と結合」の手順をやり直してください。"
done
ok "配布物の主要ファイルが揃っている"

# --- docker コマンド（podman 別名の検出を含む） ---
command -v docker >/dev/null 2>&1 || die \
  "docker コマンドが見つかりません。" \
  "本製品は Docker Engine 20.10 以降を前提としています。" \
  "導入状況を確認するには survey-target.sh を実行し、その出力を保守担当へお送りください。"

docker_version_line="$(docker --version 2>&1 || true)"
if printf '%s' "$docker_version_line" | grep -qi podman; then
  die "docker コマンドの実体が podman です（podman-docker パッケージ）。" \
      "検出した内容: $docker_version_line" \
      "本配布物は本物の Docker Engine を前提に作られており、podman では" \
      "GPU の渡し方・SELinux ラベル・compose の書式が異なるため、そのままでは動きません。" \
      "対処: Docker Engine を導入するか、保守担当へ podman 向け構成をご依頼ください。" \
      "（詳細は INSTALL_GUIDE.md「RHEL 9 特有の注意点」を参照）"
fi
ok "Docker Engine: $docker_version_line"

# --- docker デーモンへ到達できるか ---
docker info >/dev/null 2>&1 || die \
  "docker デーモンに接続できません。" \
  "次を確認してください:" \
  "  systemctl status docker    （停止していれば systemctl start docker）" \
  "  systemctl enable docker    （自動起動の有効化）"

server_version="$(docker info --format '{{.ServerVersion}}' 2>/dev/null || echo unknown)"
cgroup_version="$(docker info --format '{{.CgroupVersion}}' 2>/dev/null || echo unknown)"
docker_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)"
info "Docker Server $server_version / cgroup v$cgroup_version / root=$docker_root"

# RHEL 9 は cgroup v2。Docker 20.10 以降であれば問題ない。
major="${server_version%%.*}"
if [ "$major" = "unknown" ] || ! printf '%s' "$major" | grep -qE '^[0-9]+$'; then
  warn "Docker のバージョンを判定できませんでした（$server_version）。20.10 以降であることを確認してください。"
elif [ "$major" -lt 20 ]; then
  die "Docker Engine が古すぎます（$server_version）。" \
      "cgroup v2（RHEL 9 の既定）に対応した 20.10 以降が必要です。"
fi
if [ "$cgroup_version" = "2" ] && [ "$major" != "unknown" ] && printf '%s' "$major" | grep -qE '^[0-9]+$' && [ "$major" -lt 20 ]; then
  die "cgroup v2 の環境で Docker $server_version は動作しません。20.10 以降へ更新してください。"
fi
ok "Docker デーモン稼働（cgroup v$cgroup_version）"

# --- docker compose v2 プラグイン ---
if docker compose version >/dev/null 2>&1; then
  ok "docker compose: $(docker compose version 2>&1 | head -1)"
else
  msg_extra=""
  command -v docker-compose >/dev/null 2>&1 && msg_extra="（docker-compose v1 は検出しましたが、書式が異なるため使えません）"
  die "docker compose（v2 プラグイン）が見つかりません$msg_extra。" \
      "本配布物は compose v2 の書式（deploy.resources による GPU 予約）を使います。" \
      "docker-compose-plugin パッケージを導入してください（オフラインなら RPM を持ち込む必要があります）。"
fi

# --- NVIDIA GPU ---
if command -v nvidia-smi >/dev/null 2>&1; then
  gpu_list="$(nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>/dev/null || true)"
  if [ -z "$gpu_list" ]; then
    die "nvidia-smi は存在しますが GPU 情報を取得できませんでした。" \
        "NVIDIA ドライバーの状態を確認してください（nvidia-smi を手で実行して出力をご確認ください）。"
  fi
  printf '%s\n' "$gpu_list" | sed 's/^/       GPU: /'
  vram_mib="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')"
  if printf '%s' "$vram_mib" | grep -qE '^[0-9]+$'; then
    if [ "$vram_mib" -lt 15000 ]; then
      if [ "$FORCE" -eq 1 ]; then
        warn "GPU メモリが 16GB 未満です（${vram_mib}MiB）。--force が指定されたため続行します。"
      else
        die "GPU メモリが 16GB 未満です（${vram_mib}MiB）。" \
            "本製品は RTX 5070 Ti（16GB）相当で動作確認しています。" \
            "gemma4:12b が VRAM に載らず CPU 動作へ転落すると、1問あたり数分かかり実用外になります。" \
            "それでも続行する場合は --force を付けて再実行してください。"
      fi
    else
      ok "GPU メモリ ${vram_mib}MiB"
    fi
  fi
else
  die "nvidia-smi が見つかりません（NVIDIA ドライバー未導入の可能性）。" \
      "本製品は NVIDIA GPU 必須です。GPU が使えないと 1問あたり数分かかり実用になりません。"
fi

# --- nvidia-container-toolkit（コンテナから GPU を使うための部品） ---
toolkit_found=0
command -v nvidia-ctk >/dev/null 2>&1 && toolkit_found=1
command -v nvidia-container-runtime-hook >/dev/null 2>&1 && toolkit_found=1
[ -x /usr/bin/nvidia-container-runtime-hook ] && toolkit_found=1
docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q nvidia && toolkit_found=1
if [ "$toolkit_found" -eq 0 ]; then
  die "nvidia-container-toolkit が見つかりません。" \
      "GPU ドライバーがあっても、これが無いとコンテナから GPU を使えません。" \
      "その場合 CPU 動作へ転落し、1問あたり数分かかって実用になりません。" \
      "対処: INSTALL_GUIDE.md「nvidia-container-toolkit をオフラインで導入する」の手順に従って" \
      "      RPM を依存関係ごと持ち込み、次を実行してください:" \
      "        sudo dnf install --disablerepo=* ./nvidia-container-toolkit-rpms/*.rpm" \
      "        sudo nvidia-ctk runtime configure --runtime=docker" \
      "        sudo systemctl restart docker"
fi
ok "nvidia-container-toolkit あり"

# --- SELinux（エラーにはしない。情報表示のみ） ---
if command -v getenforce >/dev/null 2>&1; then
  selinux_mode="$(getenforce 2>/dev/null || echo unknown)"
  info "SELinux: $selinux_mode"
  if [ "$selinux_mode" = "Enforcing" ]; then
    info "  → バインドマウントに :z ラベルを付けた compose を使うため、この構成のままで動きます。"
  fi
else
  info "SELinux: 未導入（getenforce なし）"
fi

# --- ディスク容量 ---
avail_gib() {  # $1: 存在しないかもしれないパス → 最も近い既存の親で判定
  local p="$1"
  while [ ! -d "$p" ] && [ "$p" != "/" ]; do p="$(dirname "$p")"; done
  df -B1 --output=avail "$p" 2>/dev/null | tail -1 | awk '{printf "%d", $1/1073741824}'
}
data_free="$(avail_gib "$DATA_DIR")"
root_free="$(avail_gib "$INSTALL_ROOT")"
docker_free="$(avail_gib "$docker_root")"
info "空き容量: データ ${data_free}GiB / 配置先 ${root_free}GiB / Docker ${docker_free}GiB"
[ "$data_free" -ge "$NEED_DATA_GIB" ]     || die "データ領域（$DATA_DIR）の空き容量が不足しています（${data_free}GiB）。" "モデルと文書データ用に ${NEED_DATA_GIB}GiB 以上必要です。--data-dir で別の場所を指定できます。"
[ "$root_free" -ge "$NEED_ROOT_GIB" ]     || die "配置先（$INSTALL_ROOT）の空き容量が不足しています（${root_free}GiB）。" "${NEED_ROOT_GIB}GiB 以上必要です。"
[ "$docker_free" -ge "$NEED_DOCKER_GIB" ] || die "Docker のデータ領域（$docker_root）の空き容量が不足しています（${docker_free}GiB）。" "イメージ用に ${NEED_DOCKER_GIB}GiB 以上必要です。"
ok "ディスク容量"

# --- ポート競合 ---
port_in_use=0
if command -v ss >/dev/null 2>&1; then
  ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${PORT}\$" && port_in_use=1
elif command -v netstat >/dev/null 2>&1; then
  netstat -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${PORT}\$" && port_in_use=1
else
  warn "ss / netstat が無いためポート競合を確認できませんでした。"
fi
if [ "$port_in_use" -eq 1 ]; then
  # 既に自分自身（再インストール）が使っている場合は競合ではない
  if docker ps --filter "name=ote-rag-app" --format '{{.Names}}' 2>/dev/null | grep -q ote-rag-app; then
    info "ポート $PORT は既存の OTE-RAG が使用中です（再インストールとして続行します）。"
  else
    die "ポート $PORT は既に別のプログラムが使用中です。" \
        "そのプログラムを停止するか、--port で別のポートを指定してください。" \
        "使用中のプロセスは次で確認できます:  sudo ss -lntp | grep :$PORT"
  fi
fi
ok "ポート $PORT"

# --- systemd ---
if [ "$WITH_SYSTEMD" -eq 1 ] && ! command -v systemctl >/dev/null 2>&1; then
  warn "systemd がないため自動起動の登録をスキップします（起動は start.sh で行えます）。"
  WITH_SYSTEMD=0
fi

# --- 既存インストール ---
if [ -e "$INSTALL_ROOT/docker-compose.yml" ] && [ "$FORCE" -eq 0 ]; then
  info "$INSTALL_ROOT に既存のインストールがあります。設定と実行ファイルを更新します"
  info "（文書データとモデルは保持されます）。"
fi

# ================================================================
step "配布物の完全性を検証しています（SHA-256）"
# ================================================================
if [ "$SKIP_CHECKSUM" -eq 1 ]; then
  warn "--skip-checksum が指定されたため検証を省略しました（開発用途のみ）。"
else
  checksum_file="$PKG_ROOT/checksums/package.sha256"
  [ -f "$checksum_file" ] || die "checksums/package.sha256 が見つかりません。配布物が不完全です。"
  file_count="$(grep -c . "$checksum_file" || true)"
  info "$file_count ファイルを検証します。数分かかります（約12GB を読み込みます）。"
  if ! ( cd "$PKG_ROOT" && sha256sum -c --quiet checksums/package.sha256 ); then
    die "配布物の整合性チェックに失敗しました。" \
        "上に表示されたファイルが破損しているか欠落しています。" \
        "分割ファイルの結合・転送をやり直してください（INSTALL_GUIDE.md「転送と結合」）。"
  fi
  ok "$file_count ファイルすべて一致"
fi

# ここから先はファイルを作成する
umask 022

# ================================================================
step "Docker イメージを読み込んでいます（オフライン）"
# ================================================================
load_image() {  # $1: tar.gz, $2: 期待するイメージタグ
  local tarball="$1" tag="$2"
  if docker image inspect "$tag" >/dev/null 2>&1; then
    ok "$tag は既に読み込み済み（スキップ）"
    return 0
  fi
  info "読み込み中: $(basename "$tarball") → $tag"
  docker load --input "$tarball" --quiet >/dev/null \
    || die "Docker イメージの読み込みに失敗しました: $tarball" \
           "ディスク容量（$docker_root）とファイルの破損を確認してください。"
  docker image inspect "$tag" >/dev/null 2>&1 \
    || die "イメージ $tag が読み込まれませんでした。配布物が想定と異なります。"
  ok "$tag"
}
load_image "$PKG_ROOT/images/localrag-anythingllm-1.1.0.tar.gz" "$IMAGE_APP"
load_image "$PKG_ROOT/images/ollama-0.30.11.tar.gz" "$IMAGE_OLLAMA"

# ================================================================
step "コンテナから GPU が見えることを確認しています"
# ================================================================
# ここが通らないと CPU 動作に転落して実用外になる。読み込んだ ollama イメージで実際に試す。
gpu_probe_log="$(docker run --rm --gpus all --entrypoint nvidia-smi "$IMAGE_OLLAMA" -L 2>&1)" && gpu_probe_rc=0 || gpu_probe_rc=$?
if [ "$gpu_probe_rc" -ne 0 ]; then
  if [ "$FORCE" -eq 1 ]; then
    warn "コンテナから GPU を認識できませんでしたが、--force のため続行します。"
    warn "検出内容: $gpu_probe_log"
  else
    die "コンテナから GPU を認識できませんでした。" \
        "docker run --gpus all の実行結果:" \
        "$gpu_probe_log" \
        "" \
        "考えられる原因:" \
        "  1. nvidia-container-toolkit の設定が済んでいない" \
        "     → sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker" \
        "  2. SELinux がデバイスアクセスを拒否している" \
        "     → sudo setsebool -P container_use_devices 1" \
        "  3. NVIDIA ドライバーとツールキットのバージョンが合っていない" \
        "" \
        "この確認を省略して続行する場合は --force を付けてください（CPU 動作となり実用外です）。"
  fi
else
  printf '%s\n' "$gpu_probe_log" | sed 's/^/       /'
  ok "コンテナから GPU を認識"
fi

# ================================================================
step "プログラムを配置しています"
# ================================================================
# ここから環境を変更する。以降の失敗は rollback で巻き戻す。
[ -d "$INSTALL_ROOT" ] && INSTALL_ROOT_PREEXISTED=1
ROLLBACK_ARMED=1

mkdir -p "$INSTALL_ROOT" "$INSTALL_ROOT/config" "$INSTALL_ROOT/systemd"
install -m 0644 "$PKG_ROOT/docker-compose.yml" "$INSTALL_ROOT/docker-compose.yml"
install -m 0644 "$PKG_ROOT/systemd/ote-rag.service" "$INSTALL_ROOT/systemd/ote-rag.service"
for s in start.sh stop.sh uninstall.sh; do
  install -m 0755 "$PKG_ROOT/$s" "$INSTALL_ROOT/$s"
done
install -m 0644 "$PKG_ROOT/config/ollama.env" "$INSTALL_ROOT/config/ollama.env"
for f in NOTICE versions.lock INSTALL_GUIDE.md; do
  [ -f "$PKG_ROOT/$f" ] && install -m 0644 "$PKG_ROOT/$f" "$INSTALL_ROOT/$f"
done
if [ -d "$PKG_ROOT/LICENSES" ]; then
  mkdir -p "$INSTALL_ROOT/LICENSES"
  cp -a "$PKG_ROOT/LICENSES/." "$INSTALL_ROOT/LICENSES/"
fi
ok "$INSTALL_ROOT"

# 設定ファイルの生成（テンプレートが正。既存が違う内容ならバックアップしてから更新）
render_config() {  # $1: template, $2: 出力先
  local tpl="$1" out="$2" bak
  if [ -f "$out" ] && ! cmp -s "$tpl" "$out"; then
    bak="$out.bak-$(date +%Y%m%d-%H%M%S)"
    cp -a "$out" "$bak"
    warn "既存の設定 $out を $bak へ退避し、配布物の内容で更新しました。"
  fi
  install -m 0644 "$tpl" "$out"
}
render_config "$PKG_ROOT/config/server.env.template"    "$INSTALL_ROOT/config/server.env"
render_config "$PKG_ROOT/config/collector.env.template" "$INSTALL_ROOT/config/collector.env"
# テンプレート自体も残す（差分確認・再生成用）
install -m 0644 "$PKG_ROOT/config/server.env.template"    "$INSTALL_ROOT/config/server.env.template"
install -m 0644 "$PKG_ROOT/config/collector.env.template" "$INSTALL_ROOT/config/collector.env.template"

# compose の変数定義（データ配置・ポート・公開アドレス）
# config/*.env と同様、既存の内容が異なる場合は退避してから上書きする。
# ここにはデータ領域の場所が記録されており、失うと復旧の手がかりが消える。
if [ -f "$INSTALL_ROOT/.env" ]; then
  env_bak="$INSTALL_ROOT/.env.bak-$(date +%Y%m%d-%H%M%S)"
  cp -a "$INSTALL_ROOT/.env" "$env_bak" && info "既存の .env を $(basename "$env_bak") へ退避しました"
fi
cat > "$INSTALL_ROOT/.env" <<EOF
# OTE-RAG の配置設定（docker compose の変数展開に使う）。install.sh が生成。
# 変更したら stop.sh → start.sh で反映する。
OTE_RAG_DATA=$DATA_DIR
OTE_RAG_PORT=$PORT
# 🔴 0.0.0.0 にすると LAN の他端末から到達できるようになる。
#    その場合は必ず先に UI で管理者パスワードを設定すること。
OTE_RAG_BIND=$BIND
EOF
chmod 0644 "$INSTALL_ROOT/.env"
ok "設定ファイル（config/server.env, config/collector.env, .env）"

# 🔴 compose の検証はここで行う（旧版は systemd 登録より後だった）。
#    ここで落とせば、この後の 11GB のコピーも systemd 登録も走らないので、
#    巻き戻す対象が最小で済む。compose config は実体のディレクトリを要求しない。
compose_err="$( cd "$INSTALL_ROOT" && docker compose config -q 2>&1 )" || die \
  "docker-compose.yml の検証に失敗しました。" \
  "$compose_err" \
  "compose プラグインのバージョンが古い可能性があります（v2.20 以降を推奨）:" \
  "  docker compose version"
ok "compose ファイルの検証"

# ================================================================
step "モデルとデータ領域を準備しています（約11GB のコピー。数分かかります）"
# ================================================================
mkdir -p "$DATA_DIR/ollama-models/models" "$DATA_DIR/anythingllm-storage/models"

# Ollama モデル（blob 名は内容ハッシュなので、既にあるものは上書きしない）
info "Ollama モデル（gemma4:12b, bge-m3）を配置中..."
# blob 名は内容ハッシュなので -n（既存は上書きしない）で冪等かつ再実行が速い。
cp -a -n "$PKG_ROOT/models/ollama/models/." "$DATA_DIR/ollama-models/models/" || true
for m in "registry.ollama.ai/library/gemma4/12b" "registry.ollama.ai/library/bge-m3/latest"; do
  [ -f "$DATA_DIR/ollama-models/models/manifests/$m" ] \
    || die "Ollama モデルの配置に失敗しました: $m" "$DATA_DIR の書き込み権限と空き容量を確認してください。"
done
# コピー漏れ・途中で切れたファイルを検出する（同名・同サイズであることを確認）。
for b in "$PKG_ROOT/models/ollama/models/blobs/"*; do
  [ -f "$b" ] || continue
  bn="$(basename "$b")"
  bd="$DATA_DIR/ollama-models/models/blobs/$bn"
  if [ ! -f "$bd" ] || [ "$(stat -c%s "$b")" != "$(stat -c%s "$bd")" ]; then
    die "モデルファイルのコピーが完了していません: $bn" \
        "$DATA_DIR の空き容量を確認し、install.sh をもう一度実行してください。" \
        "（不完全なファイルは自動では上書きされません。手動で削除してから再実行してください:" \
        "  sudo rm -f $bd ）"
  fi
done

# リランカー（bge-reranker-v2-m3 ONNX int8）
info "リランカー（bge-reranker-v2-m3 ONNX int8）を配置中..."
mkdir -p "$DATA_DIR/anythingllm-storage/models/onnx-community"
cp -a -f "$PKG_ROOT/assets/reranker/onnx-community/bge-reranker-v2-m3-ONNX" \
         "$DATA_DIR/anythingllm-storage/models/onnx-community/"
for f in config.json tokenizer.json tokenizer_config.json onnx/model_quantized.onnx; do
  [ -f "$DATA_DIR/anythingllm-storage/models/onnx-community/bge-reranker-v2-m3-ONNX/$f" ] \
    || die "リランカーの配置に失敗しました: $f" \
           "このファイルが無いと検索精度が静かに低下します（起動は成功してしまいます）。"
done

# OCR 言語データ（tesseract）
info "OCR 言語データ（jpn, eng）を配置中..."
mkdir -p "$DATA_DIR/anythingllm-storage/models/tesseract"
cp -a -f "$PKG_ROOT/assets/tesseract/jpn.traineddata" "$PKG_ROOT/assets/tesseract/eng.traineddata" \
         "$DATA_DIR/anythingllm-storage/models/tesseract/"

# 所有者を合わせる（コンテナ内のユーザーと一致していないと書き込めない）
info "所有者を設定中（anythingllm=UID $APP_UID / ollama=root）..."
chown -R "$APP_UID:$APP_GID" "$DATA_DIR/anythingllm-storage"
chown -R 0:0 "$DATA_DIR/ollama-models"
chmod 0755 "$DATA_DIR"
ok "$DATA_DIR"

# ================================================================
step "自動起動（systemd）を設定しています"
# ================================================================
if [ "$WITH_SYSTEMD" -eq 1 ]; then
  docker_bin="$(command -v docker)"
  # 🔴 既存 unit があれば退避してから上書きする。
  # これをしないと、アップグレードが途中で失敗したときにロールバックが
  # 「元からあった unit」まで削除し、顧客は実行前より悪い状態
  # （サービス停止＋自動起動なし）で取り残される。
  if [ -f "$SYSTEMD_UNIT_PATH" ]; then
    SYSTEMD_UNIT_BACKUP="$SYSTEMD_UNIT_PATH.bak-$(date +%Y%m%d-%H%M%S)"
    cp -a "$SYSTEMD_UNIT_PATH" "$SYSTEMD_UNIT_BACKUP" \
      && info "既存の systemd unit を $(basename "$SYSTEMD_UNIT_BACKUP") へ退避しました"
  fi
  sed -e "s|@INSTALL_ROOT@|$INSTALL_ROOT|g" -e "s|@DOCKER@|$docker_bin|g" \
      "$PKG_ROOT/systemd/ote-rag.service" > "$SYSTEMD_UNIT_PATH"
  chmod 0644 "$SYSTEMD_UNIT_PATH"
  systemctl daemon-reload
  SYSTEMD_UNIT_INSTALLED=1
  systemctl enable ote-rag.service >/dev/null 2>&1 \
    || warn "systemctl enable に失敗しました。手動起動（start.sh）は使えます。"
  ok "/etc/systemd/system/ote-rag.service を登録（OS 起動時に自動で立ち上がります）"
else
  info "systemd への登録はスキップしました（--no-systemd）。"
fi

# ================================================================
step "サービスを起動しています"
# ================================================================
# compose ファイルの検証は step 5（配置直後）で済ませてある。
if [ "$START_AFTER_INSTALL" -eq 0 ]; then
  info "--no-start が指定されたため起動しません。起動するには: sudo $INSTALL_ROOT/start.sh"
else
  COMPOSE_STARTED=1
  ( cd "$INSTALL_ROOT" && docker compose up -d ) \
    || die "サービスの起動に失敗しました。" \
           "ログを確認してください:  cd $INSTALL_ROOT && docker compose logs --tail=100"
  ok "コンテナを起動しました"
fi

# 🔴 ここでインストールは成立している。以降の失敗（起動確認のタイムアウト、
#    待機中の SIGHUP／SIGTERM）で巻き戻してはいけない。
#    ロールバックを解除するのが遅いと、5分の起動待ちの最中に SSH が切れる
#    （SIGHUP）だけで EXIT trap が発火し、成功したインストールが消える。
#    遠隔導入では現実的に起こる（実測で再現済み）。
INSTALL_OK=1

# ================================================================
step "起動を待っています（最大 5 分。初回はモデル読み込みに時間がかかります）"
# ================================================================
if [ "$START_AFTER_INSTALL" -eq 0 ]; then
  info "起動していないため確認をスキップしました。"
  healthy=0
else
  healthy=0
  for _ in $(seq 1 60); do
    sleep 5
    status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' ote-rag-app 2>/dev/null || echo missing)"
    if [ "$status" = "healthy" ]; then healthy=1; break; fi
    if [ "$status" = "missing" ]; then
      # ここでの失敗は「配置」ではなく「起動」の失敗。ファイルは正しく置かれて
      # いるので削除しない（die は使わない）。原因調査に必要な情報だけ出す。
      printf '\n════════════════════════════════════════════════════════\n' >&2
      printf 'エラー: コンテナ ote-rag-app が見つかりません。起動に失敗しています。\n' >&2
      printf '  インストール自体は完了しています（%s）。\n' "$INSTALL_ROOT" >&2
      printf '  ログ:  cd %s && docker compose logs --tail=100\n' "$INSTALL_ROOT" >&2
      printf '  再起動: sudo %s/start.sh\n' "$INSTALL_ROOT" >&2
      printf '  削除  : sudo %s/uninstall.sh\n' "$INSTALL_ROOT" >&2
      printf '════════════════════════════════════════════════════════\n' >&2
      exit 3
    fi
  done
fi

printf '\n════════════════════════════════════════════════════════\n'
if [ "$healthy" -eq 1 ]; then
  printf ' インストールが完了しました\n'
else
  printf ' インストールは完了しました（起動確認はタイムアウトしました）\n'
fi
printf '════════════════════════════════════════════════════════\n'
printf '\n'
ui_host="localhost"
if [ "$BIND" = "0.0.0.0" ]; then
  ui_host="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [ -n "$ui_host" ] || ui_host="$(hostname)"
fi
printf '  Web UI      : http://%s:%s\n' "$ui_host" "$PORT"
if [ "$BIND" = "127.0.0.1" ]; then
  printf '                （このサーバー上のブラウザからのみ開けます。\n'
  printf '                  他の端末から使う場合は INSTALL_GUIDE.md「LAN から使う」を参照）\n'
fi
printf '  プログラム  : %s\n' "$INSTALL_ROOT"
printf '  データ      : %s\n' "$DATA_DIR"
printf '  起動 / 停止 : sudo %s/start.sh  /  sudo %s/stop.sh\n' "$INSTALL_ROOT" "$INSTALL_ROOT"
printf '  状態確認    : cd %s && docker compose ps\n' "$INSTALL_ROOT"
printf '  ログ        : cd %s && docker compose logs -f\n' "$INSTALL_ROOT"
printf '  アンインストール: sudo %s/uninstall.sh\n' "$INSTALL_ROOT"
printf '\n'
if [ "$healthy" -eq 0 ] && [ "$START_AFTER_INSTALL" -eq 1 ]; then
  printf '  注意: 5分以内に応答がありませんでした。初回はモデルの読み込みに時間が\n'
  printf '        かかることがあります。数分待ってから Web UI を開いてください。\n'
  printf '        改善しない場合: cd %s && docker compose logs --tail=100\n' "$INSTALL_ROOT"
  printf '\n'
  exit 3
fi
printf '  最初にすること: Web UI を開き、管理者パスワードを設定してください。\n'
if [ "$BIND" != "127.0.0.1" ] && [ "$BIND" != "localhost" ] && [ "$BIND" != "::1" ]; then
  printf '\n'
  printf '  🔴 この構成は Web UI を %s へ公開しています。管理者パスワードを\n' "$BIND"
  printf '     設定するまで、同じネットワークの誰でも文書を閲覧できます。\n'
  printf '     今すぐ設定し、firewalld で接続元を絞ってください。\n'
fi
printf '\n'
