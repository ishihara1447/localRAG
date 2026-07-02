# Windows 11 + WSL2 + Docker Engine 検証レポート

作成日: 2026-07-02

## 目的

LocalRAG を Docker Desktop ではなく、Windows 11 + WSL2 Ubuntu + Docker Engine + nvidia-container-toolkit で配布・運用できるかを、現行環境で確認した。

## 確認できたこと

- WSL2: `Ubuntu-22.04` が Running / Version 2。
- Docker Desktop 用 distro は存在するが停止中。
- WSL2 内 Docker context は `default`、endpoint は `unix:///var/run/docker.sock`。
- Windows 側 Docker context は `desktop-linux` を指しており、既存の直叩き `.ps1` は純 WSL2 方針に不適。
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
- `rag-ollama` コンテナに GPU request が入っている。
  - `Driver=nvidia`
  - `Count=-1`
  - `Capabilities=[gpu]`
- `docker exec rag-ollama nvidia-smi` が成功し、コンテナ内から GPU が見える。
- LocalRAG runtime は起動済み。
  - `anythingllm`: `localrag-anythingllm:1.0.0`, healthy, `0.0.0.0:3001->3001`
  - `rag-ollama`: `ollama/ollama:latest`, healthy
  - `GET http://localhost:3001/api/ping` は `{"online":true}`
- ローカル Ollama モデルは存在。
  - `hf.co/mmnga-o/llm-jp-4-8b-thinking-gguf:Q4_K_M`
  - `llama3.1:8b`
  - `mxbai-embed-large:latest`
  - `qwen3:14b`
  - `qwen3:8b`
- `bash scripts/smoke-test.sh` は成功。
  - PASS: 3
  - FAIL: 0
  - SKIP: 3
  - SKIP 理由: `LOCALRAG_API_KEY` 未設定
- PowerShell から WSL2 内 bash を呼ぶランチャー経路で `smoke-test.sh` 実行に成功。

## 実施した修正

- `scripts/*.ps1` を Docker Desktop 前提の直接 Docker 操作から、WSL2 内の既存 bash スクリプトを呼ぶ薄いランチャーへ変更。
- 共通ヘルパー `scripts/localrag-wsl-launcher.ps1` を追加。
- `scripts/export.sh` で PowerShell ランチャーも配布パッケージに同梱するよう修正。
- `docs/customer/INSTALL_GUIDE.md` に Windows 11 + WSL2 利用手順を追記。
- 実行権限だけ落ちていた mode 差分は修正済み。

## 未完了・ブロッカー

- `LOCALRAG_API_KEY` が未設定のため、`rag-e2e-test.sh` は未実行。
- `dist/` が未生成のため、`export.sh -> install.sh -> smoke-test -> rag-e2e-test` の配布パッケージ通し検証は未実行。
- `nvidia/cuda:12.6.3-base-ubuntu22.04` はローカルに無いため、公式 CUDA image による `docker run --gpus all ... nvidia-smi` は未実行。
- PowerShell の既定 ExecutionPolicy では UNC 上の `.ps1` がブロックされた。顧客手順では `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1` を明記する必要がある。

## 次に行うべき検証

1. API キーを発行し、`LOCALRAG_API_KEY=<key> bash scripts/rag-e2e-test.sh` を実行する。
2. `bash scripts/export.sh --version <version>` で `dist/localrag-<version>` を生成する。
3. 生成パッケージを WSL2 ext4 側の別ディレクトリへコピーし、`bash install.sh` を実行する。
4. その環境で `bash smoke-test.sh` と `LOCALRAG_API_KEY=<key> bash rag-e2e-test.sh` を実行する。
5. ネットワーク遮断状態で `docker compose up -d` / `smoke-test.sh` が pull なしで通ることを確認する。
6. 土台検証用に CUDA image を事前同梱するか、オンライン基盤構築時だけ `docker run --rm --gpus all nvidia/cuda:12.6.3-base-ubuntu22.04 nvidia-smi` を実行する運用にするか決める。

## 評価

現行環境では、Windows 11 配布先を Docker Desktop ではなく WSL2 + Docker Engine に寄せる方針は実現可能と判断できる。GPU 透過、Docker Engine、Compose、nvidia-container-toolkit、LocalRAG runtime の組み合わせは成立している。

ただし、顧客配布としては「アプリはオフライン動作可能」だが、「WSL2 / Docker Engine / nvidia-container-toolkit の土台構築」は別手順として扱うのが現実的。完全オフライン土台構築まで含める場合は `.deb` 群の収集・署名・依存検証が追加で必要。
