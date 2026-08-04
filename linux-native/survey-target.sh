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
    # 🔴 [注意] ではなく [NG]。これは導入可否を左右する最重要項目であり、
    #    podman-docker が入っていると他の項目はほぼ [OK] になるため、
    #    弱い表示だと「概ね問題なし」と誤読される。
    ng "docker コマンドの実体が podman です（podman-docker パッケージ）。"
    ng "→ 本配布物は使用できません。導入前に開発元へご連絡ください。"
    info "  compose の書式・GPU の渡し方・SELinux の扱いが Docker と異なります。"
    info "  対処は次のいずれかです:"
    info "    (a) Docker Engine を導入する（RHEL では非サポート構成になる点に注意）"
    info "    (b) podman 向けの配布物を用意する（開発元で対応します）"
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

# --- podman 環境の詳細（podman 版が必要になった場合の判断材料）---
# ここは「podman があるかどうか」ではなく「podman 版をどう作るべきか」を
# 決めるための情報を集める。判断を1往復で終わらせるため、Docker が
# 見つかった場合でも podman が同居していれば記録する。
if command -v podman >/dev/null 2>&1; then
  info ""
  info "--- podman の詳細（podman 版を用意する場合の判断材料）---"
  info "  podman: $(podman --version 2>/dev/null)"
  info "  rootless: $(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null || echo '取得不可')"
  # Quadlet は podman 4.4 以降。systemd 連携の方式がこれで決まる。
  if [ -d /usr/share/containers/systemd ] || [ -d /etc/containers/systemd ]; then
    info "  Quadlet: 利用可能（/etc/containers/systemd あり）"
  else
    info "  Quadlet: ディレクトリが見つかりません（podman 4.4 未満の可能性）"
  fi
  # compose プロバイダは podman 本体に含まれず、RHEL 標準リポジトリにも無い。
  cp_found=""
  for c in docker-compose podman-compose; do
    command -v "$c" >/dev/null 2>&1 && cp_found="$cp_found $c"
  done
  info "  compose プロバイダ:${cp_found:- なし（podman compose は単独では動きません）}"
  # 短縮イメージ名の解決先。オフラインでは localhost/ への完全修飾が要る。
  info "  レジストリ検索設定: $(grep -s '^unqualified-search-registries' /etc/containers/registries.conf 2>/dev/null || echo '既定')"
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
  # CDI spec の有無。podman は CDI 経由で GPU を渡すため、podman 版が
  # 必要になった場合にここが未生成だと GPU が使えない（要 nvidia-ctk cdi generate）。
  if [ -e /etc/cdi/nvidia.yaml ] || [ -e /var/run/cdi/nvidia.yaml ]; then
    info "  CDI spec: あり（podman での GPU 利用に必要な設定が生成済み）"
  else
    info "  CDI spec: なし（Docker では不要。podman を使う場合は要生成）"
  fi
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
sec "4-2. CPU 命令セット（AVX2）★v1.1.2 で新たに必要になりました"
# 同梱リランカーの ONNX は AVX2 向けに量子化されている
# （model_qint8_avx2.onnx をリネームして同梱）。旧リランカーは命令セット
# 非依存だったため、この確認は v1.1.2 から必要になった。
if [ -r /proc/cpuinfo ]; then
  CPU_MODEL=$(awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo)
  [ -n "$CPU_MODEL" ] && info "CPU: $CPU_MODEL"
  if grep -qm1 '^flags.*\bavx2\b' /proc/cpuinfo; then
    ok "AVX2 に対応しています"
  else
    ng "AVX2 に対応していません。"
    ng "→ 検索結果を並べ替えるモデルが想定どおり動かない可能性があります。"
    ng "  エラーにならず、静かに遅くなる・精度が落ちる形で出ることがあります。"
    ng "  この結果を開発元へお知らせください（AVX512/ARM64 版への差し替えが可能です）"
  fi
else
  warn "/proc/cpuinfo を読めないため AVX2 の有無を確認できませんでした"
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
elif sudo -nv 2>&1 | grep -q 'password is required'; then
  # 🔴 `sudo -v` は使わない。パスワードを対話的に要求してしまい、
  #    「読み取りのみ・root 権限不要」という本スクリプトの説明と矛盾する。
  #    sudo 権限の無いユーザーでは監査ログに失敗記録が残る点にも配慮する。
  ok "sudo が使えます（実行時にパスワードが必要）"
else
  warn "sudo が使えない可能性があります。導入には管理者権限が必要です。"
fi

# ---------------------------------------------------------------
sec "9. ネットワーク（オフラインであることの確認）"
if [ "${SURVEY_CHECK_NETWORK:-0}" != "1" ]; then
  # 🔴 既定では外部へ接続しない。閉域網の本番サーバから Docker Hub への
  #    接続試行は IDS/プロキシのアラートを引く可能性があり、
  #    「読み取りのみ」と説明した調査で外部通信するのは信頼を損なう。
  #    確認したい場合のみ SURVEY_CHECK_NETWORK=1 を付けて実行する。
  info "外部への疎通確認は既定で行いません（本スクリプトは外部へ接続しません）"
  info "  → 確認する場合: SURVEY_CHECK_NETWORK=1 bash survey-target.sh"
elif timeout 5 curl -sSf -o /dev/null https://registry-1.docker.io/v2/ 2>/dev/null; then
  warn "外部ネットワークに到達できます（完全オフラインではありません）"
  info "  → その場合でも、本製品は外部へ出ない設計のまま導入します"
else
  ok "外部ネットワークに到達できません（完全オフライン環境）"
fi

echo
echo "======================================================"
echo " 調査完了。この出力をそのまま貼り付けてください。"
echo "======================================================"
