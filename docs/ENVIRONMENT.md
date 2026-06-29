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

- **llm-jp の実行方式 = vLLM(OpenAI互換API)を第一候補に確定**。VRAM 16GB あり、8.59B モデルは fp16/bf16 でも十分収まる見込み。量子化GGUFは性能・互換の保険として残す。
- AnythingLLM(Docker)からホストの vLLM へは `http://host.docker.internal:8000/v1` で接続。

## 注意

- **Yarn は classic(1.22.22)**。`corepack enable` は `/usr/bin` への symlink で `EACCES` だったため、npm prefix を `~/.npm-global` に向けて導入。AnythingLLM の `yarn setup` 等は 1.x で動く想定。berry が要る場合は別途対応。
- **RTX 5070 Ti は Blackwell(sm_120)世代**。vLLM / PyTorch / CUDA は Blackwell 対応の新しめのバージョンが必要。動かない場合は CUDA 12.8+ 対応の nightly/最新版を使う。
- **dev モードの `sharp` ネイティブビルドが WSL で失敗**（server・collector）。libvips プレビルトの GitHub ダウンロードがタイムアウト→ソースビルドにフォールバックして失敗。frontend・env生成・prisma(DB作成/seed)は成功。
  - 当面は **Docker 版で起動**（コンテナ内でネイティブ依存を解決するため回避できる。配布の本命も Docker）。
  - dev モードを使う場合の解決策候補: `sudo apt install -y libvips-dev`（要 sudo）/ libvips tarball を手動 curl で取得して配置 / プレビルトDLのリトライ。
