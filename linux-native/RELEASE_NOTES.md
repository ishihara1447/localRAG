# OTE-RAG v1.1.0 (Linux x86_64)

**完全ローカルで動く日本語RAG。** 取り込んだ文書は一切外部へ送信しません。
LLM・埋め込み・リランカー・OCR をすべて同梱しているため、**インターネットに接続していない環境で動作します。**

---

## 🔴 まず最初に: 事前調査を実行してください

**インストールの前に、必ず `survey-target.sh` を実行してください。**

```bash
bash survey-target.sh > survey.txt
```

読み取りのみで、インストールも設定変更も行いません。root 権限も不要です。

**なぜ先にやるのか**: オフライン環境では、足りない部品を後から入れるのが極めて困難です。
特に **nvidia-container-toolkit** が無いと、GPU があってもコンテナから使えず、
**CPU 動作に転落して実用に耐えません**。しかも RPM を依存関係ごと持ち込む必要があります。

調査結果によっては、**配布物そのものを作り直す必要が生じます**（`docker` が podman の別名だった場合など）。

---

## 対象環境

| 項目 | 条件 |
|---|---|
| OS | **RHEL 9 系**（RHEL / Rocky / AlmaLinux）x86_64 |
| コンテナ | **Docker**（podman は未対応。調査スクリプトが判定します） |
| GPU | **NVIDIA GPU + ドライバ + nvidia-container-toolkit** |
| ディスク空き | **ピーク時 約34GB** |
| 権限 | インストールに **root 権限**が必要 |
| ネットワーク | **不要**（ダウンロード時のみ必要） |

---

## インストール手順

**詳細は [INSTALL_GUIDE.md](https://github.com/ishihara1447/localRAG/blob/main/linux-native/INSTALL_GUIDE.md) を参照してください。** 以下は要約です。

### 1. すべてのファイルを同じディレクトリにダウンロード

- `ote-rag-linux-x64-v1.1.0.tar.gz.001` 〜 `.007`（7分割）
- `MANIFEST.txt` / `join.sh` / `survey-target.sh`

```bash
gh release download linux-v1.1.0 --repo ishihara1447/localRAG --dir ~/ote-rag-install
```

> 分割しているのは、GitHub Release の1ファイル上限が 2GB のためです。
> 途中でダウンロードが切れても、**壊れたパートだけ取り直せます。**

### 2. 結合する

```bash
bash join.sh
```

全パートを結合し、**SHA-256 で破損していないか自動検証**します。

### 3. 展開してインストール

```bash
tar xzf ote-rag-linux-x64-v1.1.0.tar.gz
cd ote-rag-linux-x64-v1.1.0
sudo ./install.sh
```

**前提条件が足りなければ、進まずに日本語で停止します。** 黙って誤動作することはありません。

### 4. 動作確認

```
http://127.0.0.1:3001
```

初回は管理者アカウントの作成画面が出ます。**必ずパスワードを設定してください。**

**GPU が使われているか必ず確認してください。**

```bash
nvidia-smi
```

質問を1回投げた直後に `ollama` が GPU メモリを使っていれば正常です。
**使用が 0 のままなら CPU 動作に転落しており、実用になりません。**

---

## 中身（12.32GiB の内訳）

| 素材 | サイズ |
|---|---|
| Ollamaモデル（gemma4:12b + bge-m3） | 8.12GiB |
| Docker イメージ（AnythingLLM + Ollama） | 4.08GiB |
| リランカー（bge-reranker-v2-m3 ONNX int8） | 570MB |
| OCR言語データ（日本語・英語） | 8.2MB |

**サイズの大半はモデルです。** インストール時にネットワークから取得すれば小さくできますが、
「顧客文書を外部に出さない・オフラインで動く」という本製品の中核要件を満たせなくなるため同梱しています。

---

## 検証済みのこと

- Docker イメージの中身が fork のソースと **SHA-256 一致**（15ファイル）
- パッケージ内 22ファイル + LICENSES が原本と **byte 一致**
- Ollama blob 8個すべて**ファイル名＝内容ハッシュ**で照合、不一致0
- **`docker load` 実行成功**
- 分割の**結合ラウンドトリップを実証**（連結の SHA-256 が元 tarball と完全一致）
- `install.sh` を **shellcheck で静的検査、指摘ゼロ**
- 外部へ出る経路が **0件**（通信をフックした実測、2026-07-28）

## 未検証のこと

**実機の RHEL 9 環境での通し実行は行っていません。** 開発環境が WSL2 のため、
`install.sh` の完走・GPU 疎通・SELinux ラベルの実効・systemd 登録は**未確認**です。
初回の導入がこれらの実証を兼ねます。

## 既知の制限

- **podman は未対応**（RHEL 9 は podman が既定なので、調査スクリプトで必ず確認してください）
- **同梱していない言語の OCR はできません**（日本語・英語のみ）。外部からの自動取得は意図的に無効化しています

---

## ライセンス

本製品は [AnythingLLM](https://github.com/Mintplex-Labs/anything-llm)（MIT）を改変したものです。
同梱する各モデル・ランタイムのライセンスは、インストール先の `LICENSES/` および `NOTICE` を参照してください。
