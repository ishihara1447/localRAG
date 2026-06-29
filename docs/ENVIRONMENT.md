# 開発環境メモ

確認日: 2026-06-29 / ホスト: TAYUGURO (WSL2)

| 項目 | 値 | 備考 |
|---|---|---|
| OS | Ubuntu 22.04.5 LTS / WSL2 (kernel 6.6.87.2) | 計画書の推奨どおり |
| Node | v22.22.2 | 要件 >=18 を満たす |
| npm | 10.9.7 | |
| Docker | 29.4.2 | |
| Docker Compose | v5.1.3 | |
| GPU | NVIDIA GeForce RTX 5070 Ti / VRAM 16,303 MiB | Blackwell世代 |
| Yarn | 1.22.22 | `~/.npm-global/bin` に導入（sudo不要）、PATH を .bashrc に追記済 |

## 確定した方針

- **llm-jp の実行方式 = vLLM(OpenAI互換API) + FP8 量子化に確定**（ユーザー選択）。
  - 8.59B を **bf16 でロードすると約17GB で 16GB VRAM に収まらない**ため量子化必須（当初「bf16で収まる」は誤り）。
  - Blackwell はFP8ネイティブ。vLLM `--quantization fp8`（オンライン量子化、重みFP8≈8.6GB）で残りをKVキャッシュに回す。`--max-model-len` は VRAM に合わせ当面 8192。
  - 初回は HF から bf16 重み ≈17GB を DL してから FP8 化する（DL重い）。GGUF/Ollama は保険。
- GPU: ドライバ591.86 / CUDA 13.1 / Docker に nvidia ランタイム有り（`nvidia-container-cli` 1.19.0）→ コンテナで GPU 利用可。
- 同一 compose ネットワークなら AnythingLLM → vLLM は `http://vllm:8000/v1`。ホスト直起動の vLLM へは `http://host.docker.internal:8000/v1`。

## 注意

- **Yarn は classic(1.22.22)**。`corepack enable` は `/usr/bin` への symlink で `EACCES` だったため、npm prefix を `~/.npm-global` に向けて導入。AnythingLLM の `yarn setup` 等は 1.x で動く想定。berry が要る場合は別途対応。
- **RTX 5070 Ti は Blackwell(sm_120)世代**。vLLM / PyTorch / CUDA は Blackwell 対応の新しめのバージョンが必要。動かない場合は CUDA 12.8+ 対応の nightly/最新版を使う。
- **ネットワーク: github.com への到達が不安定（重要）**
  - host の `git clone`(github) は成功するが、**大きめのバイナリDLは遅くタイムアウト**しやすい（sharp の libvips tarball DL がタイムアウト → server/collector の sharp ビルド失敗）。
  - **Docker ビルドコンテナ内では github.com の DNS 解決自体が失敗**（`curl: (6) Could not resolve host: github.com`。一方 archive.ubuntu.com は解決OK）。このため `anything-llm/docker` のソースビルド（Dockerfile が github から yarn/uv 等を取得）が通らない。
  - 暫定対応: **公式プレビルトイメージ `mintplexlabs/anythingllm` で起動**（`runtime/docker-compose.yml`）。pull は Docker Hub 経由で github を使わない。
  - 恒久対応（Phase 2 のカスタムビルド前に必要）: Docker Desktop の daemon.json に `"dns": ["8.8.8.8","1.1.1.1"]` を設定して再起動 / WSL の DNS 設定見直し。dev モードの sharp は `sudo apt install -y libvips-dev`（要 sudo）でソースビルド可能にする手もある。
