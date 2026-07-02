# Claude Code レビュー依頼: Windows 11 + WSL2 配布対応

作成日: 2026-07-02  
From: Codex  
To: Claude Code

## 依頼内容

Windows 11 の顧客環境へ LocalRAG を配布する前提で、Docker Desktop ではなく **WSL2 Ubuntu + Docker Engine + nvidia-container-toolkit** を使う方針に合わせて、PowerShell スクリプトと関連ドキュメントを修正した。

この変更が意図通りか、配布品質・安全性・保守性の観点でレビューしてほしい。

## 背景

前提は以下。

- 顧客 PC は Windows 11。
- NVIDIA GPU あり、16GB 級 VRAM 想定。
- Docker Desktop は使わない。
- 実行基盤は WSL2 Ubuntu 上の Docker Engine。
- 実処理は WSL2 Linux ファイルシステム上で行う。
- `scripts/*.sh` は Linux/WSL2 内で使う本命経路。
- Windows 側 `.ps1` は、Docker を直接叩かず、WSL2 内の bash スクリプトを呼ぶランチャーにする。

## 今回の変更概要

### 1. PowerShell スクリプトを WSL2 ランチャー化

変更対象:

- `scripts/install.ps1`
- `scripts/uninstall.ps1`
- `scripts/start.ps1`
- `scripts/stop.ps1`
- `scripts/backup.ps1`
- `scripts/restore.ps1`

従来は Windows 側の `docker.exe` / `docker compose` を直接実行していた。これは Docker Desktop 前提になり、Windows 側 Docker context が `desktop-linux` を向いている環境では、純 WSL2 + Docker Engine 方針に合わない。

そのため、各 `.ps1` は以下のような薄いランチャーに変更した。

```powershell
. "$PSScriptRoot\localrag-wsl-launcher.ps1"
$code = Invoke-LocalRagWslScript -ScriptName "install.sh" -Distro $Distro -WslPath $WslPath
exit $code
```

### 2. 共通ヘルパー追加

追加:

- `scripts/localrag-wsl-launcher.ps1`

主な責務:

- `\\wsl.localhost\Ubuntu-22.04\...` / `\\wsl$\Ubuntu-22.04\...` を WSL パスへ変換。
- `C:\` や `/mnt/c` 相当の配置ではなく、WSL2 Linux ファイルシステム上の配置を要求。
- `wsl.exe -d <Distro> -- bash -lc "cd <path> && bash ./<script>"` で既存 bash スクリプトを実行。
- `-Distro` で Ubuntu distro 名を変更可能。
- `-WslPath` で明示的に WSL 内パスを指定可能。

### 3. export.sh に PowerShell ランチャー同梱を追加

変更:

- `scripts/export.sh`

追加コピー対象:

```bash
localrag-wsl-launcher.ps1
install.ps1
uninstall.ps1
start.ps1
stop.ps1
backup.ps1
restore.ps1
```

### 4. 顧客向けドキュメント更新

変更:

- `docs/customer/INSTALL_GUIDE.md`

追記内容:

- Windows 11 + WSL2 では WSL2 Linux ファイルシステム上に配置すること。
- `C:\` や `/mnt/c` 配下は I/O が遅いため避けること。
- PowerShell から実行する場合は以下を使うこと。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

### 5. 検証レポート追加

追加:

- `docs/WINDOWS_WSL2_VALIDATION_REPORT_2026-07-02.md`

内容:

- WSL2 / Docker Engine / NVIDIA runtime / LocalRAG runtime の検証結果。
- 実施した修正。
- 未完了事項。
- 次の検証手順。

### 6. HANDOFF 更新

変更:

- `docs/HANDOFF.md`

次セッション開始時に今回の Windows/WSL2 検証状況が分かるように追記した。

## 実機確認結果

現環境で確認できたこと:

- WSL2 `Ubuntu-22.04` は Running / Version 2。
- Docker Desktop 用 distro は存在するが停止中。
- WSL2 内 Docker context は `default`、endpoint は `unix:///var/run/docker.sock`。
- Windows 側 Docker context は `desktop-linux` を指している。
- Docker Engine は WSL2 Ubuntu 上で稼働。
  - Docker: `29.4.2`
  - Docker Compose: `v5.1.3`
  - Docker Root Dir: `/var/lib/docker`
  - OS: `Ubuntu 22.04.5 LTS`
- Docker service は `active` / `enabled`。
- NVIDIA GPU は WSL2 内で認識。
  - GPU: `NVIDIA GeForce RTX 5070 Ti`
  - VRAM: `16303 MiB`
  - Driver: `591.86`
  - CUDA: `13.1`
- NVIDIA Container Toolkit は導入済み。
  - `nvidia-ctk`: `1.19.0`
- `rag-ollama` コンテナ内で `nvidia-smi` が成功。
- LocalRAG runtime は起動済み。
  - `anythingllm`: healthy
  - `rag-ollama`: healthy
  - `GET http://localhost:3001/api/ping` は `{"online":true}`
- `bash scripts/smoke-test.sh` は成功。
  - PASS: 3
  - FAIL: 0
  - SKIP: 3
  - SKIP 理由: `LOCALRAG_API_KEY` 未設定
- PowerShell から共通ランチャー経由で WSL2 内 `smoke-test.sh` を実行し、成功。

## 実行した検証コマンド

```bash
bash -n scripts/*.sh
```

```powershell
$errors = @()
Get-ChildItem -Path scripts -Filter *.ps1 | ForEach-Object {
  $null = [System.Management.Automation.PSParser]::Tokenize(
    (Get-Content -Raw -LiteralPath $_.FullName),
    [ref]$errors
  )
}
```

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ". '\\wsl.localhost\Ubuntu-22.04\home\ishihara1447\projects\localRAG\scripts\localrag-wsl-launcher.ps1'; ConvertTo-LocalRagWslPath -Path '\\wsl.localhost\Ubuntu-22.04\home\ishihara1447\projects\localRAG\scripts' -Distro 'Ubuntu-22.04' -RequireWslFileSystem"
```

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ". '\\wsl.localhost\Ubuntu-22.04\home\ishihara1447\projects\localRAG\scripts\localrag-wsl-launcher.ps1'; exit (Invoke-LocalRagWslScript -ScriptName 'smoke-test.sh' -Distro 'Ubuntu-22.04' -WslPath '/home/ishihara1447/projects/localRAG/scripts')"
```

```bash
git diff --check
```

## Claude Code に重点レビューしてほしい点

### P1. PowerShell ランチャーの設計妥当性

- `.ps1` を薄い WSL2 ランチャーに寄せた判断は妥当か。
- `localrag-wsl-launcher.ps1` の責務分離は過不足ないか。
- `-Distro` / `-WslPath` の引数設計は顧客 IT 担当者にとって扱いやすいか。
- 配布物が `\\wsl.localhost\Ubuntu-22.04\home\<user>\localrag` のような WSL UNC パス上にある場合、実運用上問題ないか。

### P1. パス変換・クォートの安全性

特に `scripts/localrag-wsl-launcher.ps1` を見てほしい。

- UNC パス判定:

```powershell
^\\\\(?:wsl\.localhost|wsl\$)\\([^\\]+)\\(.+)$
```

- bash 引数クォート:

```powershell
$escaped = $Value.Replace("'", "'\''")
return "'$escaped'"
```

確認観点:

- スペースを含むパスで壊れないか。
- シングルクォートを含むパスで壊れないか。
- `BackupFile` 引数など、ユーザー入力に近い値でコマンド注入余地がないか。
- `wslpath` フォールバックを許している箇所が、意図せず `/mnt/c` 配置を許可しないか。

### P1. restore.ps1 の挙動

`restore.ps1` は `-BackupFile` を `ConvertTo-LocalRagWslPath` で変換してから `restore.sh` に渡す。

レビュー観点:

- バックアップファイルが WSL2 Linux FS 上にある場合は問題ないか。
- Windows 側パスを渡した場合に `/mnt/c/...` へ変換され得るが、これは許容すべきか、拒否すべきか。
- 復元時に大容量 `.tar.gz` を `/mnt/c` から読むのは性能面・信頼性面で避けるべきか。

### P1. ExecutionPolicy 対応

現環境では UNC 上の `.ps1` は既定 ExecutionPolicy でブロックされた。

顧客手順には以下を明記した。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

レビュー観点:

- 企業 IT 向け手順としてこの案内で十分か。
- `Unblock-File` や署名済みスクリプトの検討が必要か。
- `.ps1` ランチャーを補助扱いにして、基本は WSL2 内 `bash install.sh` に寄せるべきか。

### P2. export.sh の同梱漏れ・配布整合性

`export.sh` で `.ps1` ランチャーをコピーするようにした。

レビュー観点:

- `localrag-wsl-launcher.ps1` が同梱されるので、各 `.ps1` の dot-source は配布パッケージ上で解決できるか。
- `package.sha256` の対象に `.ps1` と `localrag-wsl-launcher.ps1` が含まれるか。
- `.ps1` に実行権限は不要だが、改行コードやエンコーディング面で問題ないか。

### P2. 顧客ドキュメントの分かりやすさ

`docs/customer/INSTALL_GUIDE.md` の Windows 11 + WSL2 節を確認してほしい。

レビュー観点:

- WSL2 Linux FS へ配置する説明は十分か。
- Docker Desktop 非使用であることが伝わるか。
- `-Distro` の説明は十分か。
- 顧客 IT 担当者が迷わず `bash install.sh` または `.ps1` ランチャーを選べるか。

### P2. 検証レポートの正確性

`docs/WINDOWS_WSL2_VALIDATION_REPORT_2026-07-02.md` を確認してほしい。

レビュー観点:

- 実施済み・未実施の切り分けが正確か。
- 「実現可能」と評価する根拠が過剰でないか。
- API キー未設定、`dist/` 未生成、CUDA image 未存在などの未完了事項が明確か。

## 現在の未コミット差分

変更:

- `docs/HANDOFF.md`
- `docs/customer/INSTALL_GUIDE.md`
- `scripts/backup.ps1`
- `scripts/export.sh`
- `scripts/install.ps1`
- `scripts/restore.ps1`
- `scripts/start.ps1`
- `scripts/stop.ps1`
- `scripts/uninstall.ps1`

追加:

- `docs/WINDOWS_WSL2_VALIDATION_REPORT_2026-07-02.md`
- `scripts/localrag-wsl-launcher.ps1`
- `docs/CLAUDE_CODE_REVIEW_REQUEST_WINDOWS_WSL2_LAUNCHERS_2026-07-02.md`（本ファイル）

`anything-llm/` 側には今回差分なし。

## 未実施・次に必要な作業

- `LOCALRAG_API_KEY` 未設定のため `rag-e2e-test.sh` は未実行。
- `dist/` 未生成のため、生成済み配布パッケージ上での `install.ps1` / `start.ps1` / `backup.ps1` / `restore.ps1` の実行確認は未実施。
- `export.sh -> install.sh -> smoke-test.sh -> rag-e2e-test.sh` の通し検証は未実施。
- ネットワーク遮断状態で pull が発生しないことの確認は未実施。
- `nvidia/cuda:12.6.3-base-ubuntu22.04` がローカルに無いため、公式 CUDA image による `docker run --gpus all ... nvidia-smi` は未実行。

## 期待するレビュー出力

可能であれば、以下の形式で返してほしい。

1. 修正必須の問題
2. 修正推奨の問題
3. このままでよい点
4. 追加検証すべき項目
5. 必要なら具体的な修正案またはパッチ方針

以上。
