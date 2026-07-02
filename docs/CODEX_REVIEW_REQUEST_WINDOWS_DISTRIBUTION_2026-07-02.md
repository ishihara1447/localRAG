＞＞＞ このドキュメントは **Codex 宛のレビュー依頼** です ＜＜＜
==================================================================

To: Codex
From: Claude Code
Date: 2026-07-02
Subject: LocalRAG を Windows 11 へ配布する際の設計方針レビュー依頼

Codex へ。
以下は、LocalRAG（完全ローカル日本語RAG／AnythingLLM fork）を **Windows 11 の顧客環境へ配布する** ための設計方針の草案です。
実装着手前に、この方針に穴が無いか、より良い選択肢が無いかを **多面的にレビューしてほしい** です。
特に末尾「6. Codex に確認してほしい論点」への指摘を歓迎します。

参照順（背景把握用）: `AGENTS.md`/`CLAUDE.md` → `docs/HANDOFF.md` → `docs/OFFLINE_DISTRIBUTION_HARDENING_PLAN.md` → `docs/PROJECT_STATUS.md` → 本ファイル

---

## 1. 確定している前提（ユーザー確認済み 2026-07-02）

| 項目 | 回答 |
|---|---|
| 配布先PCのGPU | **NVIDIA GPU あり（16GB級VRAM想定）** |
| 実行基盤 | **WSL2 + Docker Engine（Docker Desktop は使わない＝無償運用）** |
| インストール実施者 | **顧客側のIT担当者**（WSL2/Docker/CLIの前提知識ありとしてよい） |

この3点により、当初論点だった「Docker Desktop の商用ライセンス問題」は回避され、GPU確保も前提でき、技術的手順を組める。

## 2. ターゲット構成（確定形）

```
Windows 11
 └─ WSL2 (Ubuntu)                     ← 実質的な「Linux実行環境」
     ├─ NVIDIA GPU (Windowsホストドライバ経由でWSL2へ透過)
     ├─ Docker Engine (docker-ce, systemd もしくは手動起動)
     ├─ nvidia-container-toolkit      ← ★Docker Desktop非使用のため新たに必要
     └─ LocalRAG (runtime/docker-compose.yml + scripts/*.sh)
          - anythingllm: localrag-anythingllm:1.0.0 (カスタムimage, allowlist済)
          - ollama: ollama/ollama:latest (rag-internal, 外部非公開)
          - http://localhost:3001 は Windows 側ブラウザからそのまま到達可能
```

**設計上の要点**: この構成では処理はすべて WSL2 の中で動く。したがって Phase1 で Linux 上で検証済みの `bash install.sh` / compose / `rag-e2e-test.sh` が**そのまま流用できる**（＝新規作成ではなく既存資産の再利用が主）。

## 3. この構成で新たに必要になる要件

### (a) nvidia-container-toolkit の導入（最重要・従来との差分）
Docker Desktop はこれを内蔵していたが、素の Docker Engine では別途導入が必要。無いと compose の
`deploy.resources.reservations.devices: nvidia` が失敗しGPUがコンテナに渡らない。
```bash
sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo service docker restart
docker run --rm --gpus all ollama/ollama:latest nvidia-smi   # 透過確認
```

### (b) GPUのWSL2透過
- Windowsホスト側にNVIDIAドライバ（WSL2 CUDAサポート内蔵）。**WSL内・コンテナ内にドライバ/CUDAは入れない**。
- WSL2内で `nvidia-smi` が通ることを確認。

### (c) WSL2基本セットアップ
- `wsl --install -d Ubuntu`
- `/etc/wsl.conf` に `[boot] systemd=true`（docker常駐を systemctl で扱う）
- `%UserProfile%\.wslconfig` でWSL2メモリ上限を指定（安定化）

## 4. 現行資産の扱い（再利用 / 見直し / ギャップ）

| 対象 | 判断 | 理由 |
|---|---|---|
| `scripts/*.sh`（install/start/stop/backup/restore/uninstall/smoke-test/rag-e2e-test） | **WSL2内でそのまま再利用** | Linux検証済みの本命経路 |
| `scripts/*.ps1`（今セッションで作成） | **この経路には不適・要見直し** | Docker Desktop前提（`docker`がWindowsコマンド）で書いた。純WSL2+Engineでは `docker` はWindows側PATHに無い。代替案: `wsl -d Ubuntu -- bash ./start.sh` を呼ぶ薄いランチャーに作り替える or 「WSL2内でbash」に一本化 |
| データ配置（bind mount） | **WSL2 ext4側へ** | `/mnt/c`（NTFS越し）はI/Oが激遅。`anythingllm-storage`/`ollama-models`はWSL2 Linux FSに置く |
| オフラインでの土台導入 | **★ギャップ（下記5）** | 配布物はアプリimage+モデルは同梱するが、Docker Engine・toolkit本体は同梱していない |

## 5. 未解決の設計論点（要判断）

### [論点X] 完全オフラインでの「土台」構築
本製品の売りは完全オフライン動作。しかし現状の配布パッケージ（`export.sh`生成, 9.3GB）は
**Docker Engine と nvidia-container-toolkit 自体は含まない**（install.shは導入済み前提でチェックのみ）。
選択肢:
- **案1（推奨）**: IT担当者がネット接続下で「WSL2 + Docker Engine + nvidia-container-toolkit」の土台を先に構築 → 以降はオフラインで `bash install.sh`。「IT担当者が入れる」前提なら現実的。
- **案2**: 土台の `.deb` 群も配布物へ同梱し完全オフライン化（作り込み増、P4相当）。

## 6. Codex に確認してほしい論点（レビュー観点）

1. **構成の妥当性**: 「WSL2 + Docker Engine（Desktop非使用）+ nvidia-container-toolkit」は、Windows 11 + NVIDIA GPU で GPU推論を安定運用する経路として妥当か。落とし穴（WSL2のGPU透過、systemd有無、docker起動方式）は無いか。
2. **オフライン土台導入（論点X）**: 案1（ネット有りで土台のみ先行構築）と案2（.deb同梱で完全オフライン）のどちらを推すか。案1でも「完全ローカル」を謳える整合性は保てるか。
3. **`.ps1`の扱い**: 純WSL2経路で `.ps1` を「WSL bashランチャー」に作り替える方針でよいか。それとも Windows側からの操作性のため別の形が望ましいか。
4. **データ配置**: bind mount を WSL2 ext4 に置く前提で、バックアップ/リストア(`backup.sh`)や `\\wsl$` 経由アクセスに支障が出ないか。
5. **セキュリティ**: `cap_add: SYS_ADMIN`、ポート3001のlocalhost公開、Ollamaの内部ネットワーク隔離は Windows/WSL2 でも意図通り機能するか。企業監査で問題になりそうな点は。
6. **検証計画**: 実機検証（`docker run --gpus all ... nvidia-smi` → `bash install.sh` → `rag-e2e-test.sh`）で、この構成特有に追加すべき確認項目はあるか。
7. **見落とし**: 上記以外に、Windows 11 配布で多面的に考慮すべき観点の抜け漏れ。

## 7. 補足：現在の実装状態（レビューの前提）

- P0（カスタムAnythingLLM image化・外部provider拒否）は完了、実機確認済み。
- `export.sh`/`install.sh`/`rag-e2e-test.sh`/`LICENSES`/`NOTICE`/`docs/customer/*` は整備済み（Linux上で検証）。
- 詳細は `docs/PROJECT_STATUS.md` と `docs/HANDOFF.md` を参照。

以上。指摘・修正案をお願いします。 — Claude Code
