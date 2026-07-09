# Windows オフライン配布 人手確認チェックリスト

作成日: 2026-07-05

## 目的

LocalRAG を Windows 11 顧客PCへ配布する前提で、**Docker Desktopなし / WSL2 Ubuntu + Docker Engine / オフライン配布物のみ**でインストール・起動・RAG動作確認まで完了できるかを、人手で確認する。

このメモは、Codex や Claude Code が自動では確認しきれない Windows 実機操作・UI操作・ネットワーク遮断・対話入力の確認漏れを防ぐためのチェックリスト。

## ゴール

最終的に以下を確認できれば合格。

- 配布パッケージを Windows + WSL2 環境へ置ける。
- ネットワーク遮断状態でも `install.sh` / `install.ps1` が成功する。
- Docker image / Ollama model が外部 pull なしで読み込まれる。
- Windows ブラウザから `http://localhost:3001` を開ける。
- `smoke-test.sh` が通る。
- APIキー発行後、`rag-e2e-test.sh` が通る。

## 前提

- 実行環境: Windows 11
- WSL2 distro: `Ubuntu-22.04` 想定
- Docker Desktop: 使用しない
- Docker Engine: WSL2 Ubuntu 内で稼働
- NVIDIA GPU / nvidia-container-toolkit: 導入済み想定
- 配布物配置先: WSL2 Linux filesystem 側

推奨配置例:

```text
\\wsl.localhost\Ubuntu-22.04\home\<user>\localrag
```

`C:\` や `/mnt/c` 配下は、モデル・DB・文書ストレージの I/O が遅くなるため、原則避ける。

## 人手確認チェックリスト

### 1. 配布パッケージを準備する

- [ ] `export.sh` で配布パッケージを生成する。
- [ ] `dist/localrag-<version>/` が生成されている。
- [ ] `images/rag-images.tar.gz` が含まれている。
- [ ] `ollama-models/` が含まれている。
- [ ] `checksums/` が含まれている。
- [ ] `install.sh` / `install.ps1` が含まれている。
- [ ] `smoke-test.sh` / `rag-e2e-test.sh` が含まれている。

### 2. WSL2 側へ配置する

- [ ] 配布パッケージを WSL2 Linux filesystem 側へコピーする。
- [ ] 配置先が `/home/<user>/...` 配下である。
- [ ] `/mnt/c/...` 配下ではない。

確認例:

```bash
pwd
df -h .
ls -la
```

### 3. ネットワーク遮断状態にする

- [ ] Wi-Fi / LAN を切る、または外部通信できない状態にする。
- [ ] Docker image pull や Ollama model pull ができない状態であることを意識する。

注意:

WSL2 / Docker Engine / nvidia-container-toolkit などの土台構築は、事前にオンライン環境で済ませてよい。ここで確認するのは、**LocalRAG 配布パッケージ自体がオフラインで入るか**。

### 4. WSL2 内で `install.sh` を実行する

WSL2 Ubuntu 内で実行。

```bash
cd ~/localrag
bash install.sh
```

- [ ] checksum 検証が成功する。
- [ ] `docker load` が成功する。
- [ ] `ollama-models/` がそのまま使われる。
- [ ] 外部 pull / download が発生しない。
- [ ] `anythingllm` / `rag-ollama` が起動する。
- [ ] `http://localhost:3001` が起動完了として表示される。

### 5. Windows PowerShell から `install.ps1` を実行する

Windows 側 PowerShell / Windows Terminal で実行。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

- [ ] `ExecutionPolicy Bypass` 付きで `.ps1` が起動する。
- [ ] `localrag-wsl-launcher.ps1` がパースエラーなく読み込まれる。
- [ ] `wsl.exe -d Ubuntu-22.04 -- bash ...` 経由で WSL2 内の `install.sh` が呼ばれる。
- [ ] Windows 側 Docker Desktop ではなく、WSL2 内 Docker Engine が使われる。
- [ ] 日本語ログが読める、または運用上問題ない。

文字化けする場合の確認:

```powershell
chcp 65001
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

または Windows Terminal で実行する。

### 6. Windows ブラウザから画面を開く

Windows 側ブラウザで以下へアクセス。

```text
http://localhost:3001
```

- [ ] LocalRAG / AnythingLLM の画面が開く。
- [ ] 初期セットアップまたはログイン画面に進める。
- [ ] Windows 側から `localhost:3001` で到達できる。

### 7. `smoke-test.sh` を実行する

WSL2 内で実行。

```bash
cd ~/localrag
bash smoke-test.sh
```

- [ ] `GET /api/ping` が成功する。
- [ ] Ollama API 応答確認が成功する。
- [ ] GPU 検出が成功する。
- [ ] `FAIL: 0` で終わる。

API キー未設定による `SKIP` は、この段階では許容。

### 8. AnythingLLM 画面で API キーを発行する

Windows ブラウザで操作。

- [ ] Settings を開く。
- [ ] API Keys を開く。
- [ ] テスト用 API キーを発行する。
- [ ] API キーは他人に共有しない。

### 9. `rag-e2e-test.sh` を実行する

WSL2 内で実行。

```bash
cd ~/localrag
LOCALRAG_API_KEY=<発行したAPIキー> bash rag-e2e-test.sh
```

- [ ] テスト用 workspace 作成が成功する。
- [ ] fixture 文書アップロードが成功する。
- [ ] 文書内質問で正しい回答が返る。
- [ ] sources が付与される。
- [ ] 文書外質問で「不明」または出典なしになる。
- [ ] 外部 provider の `openai` 指定が API 側で拒否される。
- [ ] Swagger docs が無効である。
- [ ] `FAIL=0` で終わる。

### 10. 運用系 PowerShell ランチャーを確認する

Windows 側 PowerShell / Windows Terminal で確認。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\start.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\stop.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\backup.ps1
```

- [ ] `start.ps1` が WSL2 内 `start.sh` を呼ぶ。
- [ ] `stop.ps1` が WSL2 内 `stop.sh` を呼ぶ。
- [ ] `backup.ps1` が WSL2 内 `backup.sh` を呼ぶ。
- [ ] backup ファイルが作成される。

### 11. 対話入力を確認する

特に以下。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\restore.ps1 -BackupFile <backup.tar.gz>
```

- [ ] `続行しますか？ [y/N]` のような入力に応答できる。
- [ ] PowerShell → WSL2 → bash 経由で stdin が通る。
- [ ] 誤操作防止の確認文が読める。

注意:

`uninstall.ps1` は破壊的操作を含むため、確認時は `-KeepData` や検証専用環境の利用を検討する。

### 12. Docker Desktop 併存時の確認

Docker Desktop がインストールされている環境では、必要に応じて確認。

- [ ] Docker Desktop 停止状態で `install.ps1` が動く。
- [ ] Docker Desktop 起動状態でも、`install.ps1` が WSL2 内 Docker Engine を使う。
- [ ] ポート `3001` の競合が起きない。
- [ ] 競合時に分かりやすいエラーになる。

## 記録すべき結果

確認後、以下をメモする。

```text
確認日:
確認者:
Windows version:
WSL distro:
Docker version:
Docker Compose version:
NVIDIA driver:
GPU:
ネットワーク遮断方法:

install.sh:
install.ps1:
Windows browser access:
smoke-test.sh:
rag-e2e-test.sh:
start.ps1 / stop.ps1:
backup.ps1:
restore.ps1:
uninstall.ps1:

発生した問題:
対応内容:
残課題:
```

## 優先順位

最優先:

1. ネットワーク遮断状態で `install.sh`
2. ネットワーク遮断状態で `install.ps1`
3. Windows ブラウザで `http://localhost:3001`
4. `smoke-test.sh`
5. API キー発行
6. `rag-e2e-test.sh`

次点:

7. `start.ps1` / `stop.ps1`
8. `backup.ps1`
9. `restore.ps1`
10. `uninstall.ps1`
11. Docker Desktop 併存時確認

## 補足

Codex / Claude Code でできる確認は、スクリプト構文、差分レビュー、通常オンライン状態での Docker 状態確認、smoke test まで。

最終的な合否に関わる **Windows実機・オフライン・ブラウザ・APIキー・対話入力** は人手確認が必要。
