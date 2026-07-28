#!/usr/bin/env bash
# OTE-RAG 導入先Linux環境の調査スクリプト（RHEL 9 想定）
#
# 目的: オフライン導入前に、構成を決めるうえで必須の情報を一度に集める。
#       読み取りのみ。インストールも設定変更も一切しない。
#
# 使い方:
#   bash survey-target.sh              # 画面に出す
#   bash survey-target.sh > survey.txt # ファイルに保存して持ち帰る
#
# sudo は不要。ただし一部項目は sudo があるとより正確に取れる（その旨を表示する）。

echo "======================================================"
echo " OTE-RAG 導入先環境 調査結果"
echo " 実行: $(date '+%Y-%m-%d %H:%M:%S')  ホスト: $(hostname)"
echo "======================================================"

sec() { echo; echo "── $1 ──────────────────────────"; }
ok()  { echo "  [OK]   $1"; }
ng()  { echo "  [NG]   $1"; }
warn(){ echo "  [注意] $1"; }
info(){ echo "         $1"; }

# ---------------------------------------------------------------
sec "1. OS / カーネル / アーキテクチャ"
[ -f /etc/os-release ] && . /etc/os-release && info "$PRETTY_NAME"
info "カーネル: $(uname -r)"
ARCH=$(uname -m)
info "アーキテクチャ: $ARCH"
if [ "$ARCH" != "x86_64" ]; then
  ng "x86_64 ではありません。配布物は x86_64 前提のため作り直しが必要です。"
else
  ok "x86_64"
fi
info "glibc: $(ldd --version 2>/dev/null | head -1)"

# ---------------------------------------------------------------
sec "2. コンテナ実行環境 ★最重要"
# RHEL 9 は podman が既定。docker コマンドが podman の別名になっていることがある。
if command -v docker >/dev/null 2>&1; then
  DV=$(docker --version 2>&1)
  info "docker --version: $DV"
  if echo "$DV" | grep -qi podman; then
    warn "docker コマンドの実体が podman です（podman-docker パッケージ）。"
    warn "→ compose の書式や SELinux の扱いが異なります。構成を変える必要があります。"
  else
    ok "本物の Docker Engine です"
  fi
else
  ng "docker コマンドがありません"
fi

if command -v podman >/dev/null 2>&1; then
  info "podman --version: $(podman --version 2>&1)"
fi

echo
info "--- compose の有無（どちらが使えるかで手順が変わる） ---"
if docker compose version >/dev/null 2>&1; then
  ok "docker compose (v2 プラグイン): $(docker compose version 2>&1 | head -1)"
elif command -v docker-compose >/dev/null 2>&1; then
  warn "docker-compose (v1 単体版): $(docker-compose --version 2>&1)"
  warn "→ v1 は書式差があります。v2 プラグインの導入を推奨します。"
elif command -v podman-compose >/dev/null 2>&1; then
  warn "podman-compose: $(podman-compose --version 2>&1 | head -1)"
else
  ng "compose が見つかりません。これが無いと現行の構成では起動できません。"
fi

echo
info "--- デーモンの稼働と権限 ---"
if docker info >/dev/null 2>&1; then
  ok "現在のユーザーで docker が実行できます"
  info "  ストレージドライバ: $(docker info --format '{{.Driver}}' 2>/dev/null)"
  info "  cgroup: $(docker info --format '{{.CgroupVersion}}' 2>/dev/null)"
  info "  ルートディレクトリ: $(docker info --format '{{.DockerRootDir}}' 2>/dev/null)"
else
  ng "docker info が失敗しました（デーモン未起動、または権限不足）"
  info "  sudo docker info が通るか、docker グループに所属しているか確認してください"
  id -nG 2>/dev/null | tr ' ' '\n' | grep -qx docker && info "  → docker グループには所属しています" || warn "  → docker グループに所属していません"
fi

# ---------------------------------------------------------------
sec "3. GPU ★実用性を左右する"
if command -v nvidia-smi >/dev/null 2>&1; then
  ok "nvidia-smi あり"
  nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>/dev/null | sed 's/^/         /'
  DRV=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
  info "  ドライバ: $DRV"
else
  ng "nvidia-smi がありません（GPUドライバ未導入の可能性）"
fi

echo
info "--- コンテナからGPUを使うための部品 ★RHEL定番の落とし穴 ---"
if command -v nvidia-ctk >/dev/null 2>&1; then
  ok "nvidia-container-toolkit あり: $(nvidia-ctk --version 2>&1 | head -1)"
else
  ng "nvidia-container-toolkit がありません"
  ng "→ これが無いと、GPUがあってもコンテナからは使えません（CPU動作に転落し実用外）"
  ng "→ オフライン導入では RPM を依存関係ごと持ち込む必要があります"
fi
if [ -f /etc/docker/daemon.json ]; then
  info "  /etc/docker/daemon.json:"
  sed 's/^/           /' /etc/docker/daemon.json 2>/dev/null
  grep -q nvidia /etc/docker/daemon.json 2>/dev/null && ok "  nvidia ランタイムが登録されています" || warn "  nvidia ランタイムの登録が見当たりません"
else
  warn "  /etc/docker/daemon.json がありません（nvidia ランタイム未設定の可能性）"
fi

# ---------------------------------------------------------------
sec "4. SELinux ★RHEL定番の落とし穴"
if command -v getenforce >/dev/null 2>&1; then
  SE=$(getenforce 2>/dev/null)
  info "getenforce: $SE"
  if [ "$SE" = "Enforcing" ]; then
    warn "Enforcing です。バインドマウントに :z / :Z を付けないとコンテナが"
    warn "モデルファイルを読めず『Permission denied』で起動に失敗します。"
    warn "→ 配布する compose ファイル側で対応します（環境変更は不要です）"
  else
    ok "Enforcing ではないため、マウントの追加対応は不要です"
  fi
else
  info "getenforce なし（SELinux未導入と思われる）"
fi

# ---------------------------------------------------------------
sec "5. ディスク容量"
info "--- 空き容量（配布物の展開と Docker イメージの保存先）---"
df -h / /var /var/lib/docker /opt /home 2>/dev/null | awk 'NR==1 || !seen[$6]++' | sed 's/^/         /'
echo
info "必要量の目安:"
info "  配布物(tar)の置き場        : 約 14GB"
info "  Docker イメージ(/var/lib/docker) : 約  9GB"
info "  モデル・データの永続領域    : 約 11GB"
info "  ピーク合計                  : 約 34GB"

# ---------------------------------------------------------------
sec "6. ポートと既存プロセス"
for p in 3001 11434; do
  if command -v ss >/dev/null 2>&1; then
    if ss -lntp 2>/dev/null | grep -q ":$p "; then
      warn "ポート $p は既に使用中です"
      ss -lntp 2>/dev/null | grep ":$p " | sed 's/^/           /'
    else
      ok "ポート $p は空いています"
    fi
  fi
done
if command -v ollama >/dev/null 2>&1; then
  warn "ホスト側に ollama が導入済みです（$(ollama --version 2>&1 | head -1)）"
  warn "→ ポート 11434 が競合する可能性があります"
fi

# ---------------------------------------------------------------
sec "7. systemd（自動起動に使う）"
if command -v systemctl >/dev/null 2>&1; then
  ok "systemd あり"
  systemctl is-active docker >/dev/null 2>&1 && ok "  docker.service は稼働中" || warn "  docker.service が稼働していません"
  systemctl is-enabled docker >/dev/null 2>&1 && ok "  docker.service は自動起動有効" || warn "  docker.service の自動起動が無効です"
else
  warn "systemd がありません。自動起動の仕組みを別途検討します。"
fi

# ---------------------------------------------------------------
sec "8. 権限"
info "実行ユーザー: $(id -un)  (uid=$(id -u))"
if sudo -n true 2>/dev/null; then
  ok "パスワード無しで sudo が使えます"
elif sudo -v 2>/dev/null; then
  ok "sudo が使えます（パスワード必要）"
else
  warn "sudo が使えない可能性があります。導入には管理者権限が必要です。"
fi

# ---------------------------------------------------------------
sec "9. ネットワーク（オフラインであることの確認）"
if timeout 5 curl -sSf -o /dev/null https://registry-1.docker.io/v2/ 2>/dev/null; then
  warn "外部ネットワークに到達できます（完全オフラインではありません）"
  info "  → その場合でも、本製品は外部へ出ない設計のまま導入します"
else
  ok "外部ネットワークに到達できません（完全オフライン環境）"
fi

echo
echo "======================================================"
echo " 調査完了。この出力をそのまま貼り付けてください。"
echo "======================================================"
