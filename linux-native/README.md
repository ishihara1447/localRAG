# linux-native — OTE-RAG Linux オフライン配布物（開発者向け）

RHEL 9 / Docker / NVIDIA GPU / 完全オフライン環境向けの配布物を作るための資材一式。

> **導入先の担当者が読むのは `INSTALL_GUIDE.md`。** このファイルは開発者向けで、
> パッケージ構成・ビルド方法・各ファイルの役割を説明する。導入手順はここには書かない。

Windows 版（`windows-native/`, v1.2.7）は独立して残してある。両者は同じ fork ソースから作るが、
**配布形態が違うだけで設定値の意味は同じ**になるように移植してある（差分は
`docs/LINUX_DISTRIBUTION_2026-07-28.md` を参照）。

---

## 1. 設計の前提

- 開発環境そのものが Linux + Docker + GPU で、`runtime/docker-compose.yml` で全評価を通している。
  **動作実績のあるその構成をそのまま持ち出す**のが基本方針。
- 導入先は **RHEL 9 / Docker / NVIDIA GPU 導入済み / 完全オフライン**。
- Windows 版のような独自のプロセス管理（WinSW サービス）は作らない。
  Docker Compose + systemd で置き換える。

### Windows 版との対応

| 役割 | Windows 版 | Linux 版 |
|---|---|---|
| プロセス管理 | WinSW（3サービス） | Docker Compose + systemd（`ote-rag.service`） |
| Node ランタイム | 同梱（portable node） | Docker イメージに内包 |
| Ollama | 同梱（ollama.exe） | Docker イメージ `ollama/ollama:0.30.11` |
| 設定 | `app\server\.env` / `app\collector\.env` | `config/server.env` / `config/collector.env`（compose の `env_file`） |
| モデル配置 | `C:\ProgramData\LocalRAG\models` | `<データ領域>/ollama-models/models` |
| リランカー配置 | `app\server\storage\models\...` | `<データ領域>/anythingllm-storage/models/...` |
| 整合性検証 | `checksums/package.sha256` + `install.ps1` | `checksums/package.sha256` + `install.sh`（`sha256sum -c`） |
| 分割転送 | `windows-native/dist-split/`（`Join-OTE-RAG.cmd`） | `linux-native/dist-split/`（`join.sh`） |

---

## 2. ディレクトリ構成

```
linux-native/
├── README.md              ← このファイル（開発者向け）
├── INSTALL_GUIDE.md       導入先担当者向けの手順書（配布物にも同梱される）
├── survey-target.sh       導入先の環境調査スクリプト（🔴 改変禁止・配布物のトップに同梱）
├── build-linux.sh         配布物のビルド（開発機で実行）
├── verify-image.sh        ビルドしたイメージの中身と fork ソースの SHA-256 一致検証
├── verify-package.sh      同梱物の網羅性検証（参照されているのに無いファイルを検出）
├── dist-split/            GitHub Release へ分割アップロードするための道具
│   ├── split-release.sh   1.77GiB ずつに分割し MANIFEST.txt を作る
│   ├── join.sh            受け取り側で結合＋SHA-256検証
│   └── README.md          受け取り側の手順
└── package/               配布物に入るスクリプトと設定のテンプレート
    ├── install.sh
    ├── uninstall.sh
    ├── start.sh
    ├── stop.sh
    ├── docker-compose.yml     SELinux ラベル(:z)対応版
    ├── config/
    │   ├── server.env.template
    │   ├── collector.env.template
    │   └── ollama.env
    └── systemd/ote-rag.service
```

### ビルド後の配布物（tar.gz の中身）

```
ote-rag-linux-x64-v1.1.0/
├── install.sh / uninstall.sh / start.sh / stop.sh
├── survey-target.sh          ← 展開してすぐ見える位置（手順の最初に実行する）
├── INSTALL_GUIDE.md
├── docker-compose.yml
├── config/                   *.template と ollama.env
├── systemd/ote-rag.service
├── images/                   docker save + gzip した2イメージ
│   ├── localrag-anythingllm-1.1.0.tar.gz
│   └── ollama-0.30.11.tar.gz
├── models/ollama/models/     manifests + blobs（gemma4:12b, bge-m3:latest）
├── assets/
│   ├── reranker/onnx-community/bge-reranker-v2-m3-ONNX/   int8 のみ
│   └── tesseract/            jpn.traineddata / eng.traineddata
├── docs/MODEL_CARDS.md
├── LICENSES/ , NOTICE
├── versions.lock
└── checksums/package.sha256  全ファイルの SHA-256
```

---

## 3. ビルド方法

```bash
# 通し（イメージのビルドから）
./linux-native/build-linux.sh

# イメージが既にある場合
./linux-native/build-linux.sh --skip-build

# 出力先を変える
./linux-native/build-linux.sh --output /path/to/dist
```

出力は既定で `dist-linux/ote-rag-linux-x64-v<版数>.tar.gz`（＋ `.sha256`）。

### ビルドの流れ

1. `docker build` で `localrag-anythingllm:<版数>` を作る
2. **`verify-image.sh`**：イメージ内のファイルが fork ソースと SHA-256 一致するか検証（不一致なら中断）
3. `ollama/ollama:latest` のダイジェストが記録と一致するか確認し、`ollama/ollama:0.30.11` にタグ固定
4. `docker save | pigz` で2イメージを保存
5. Ollama モデルを **マニフェスト駆動** で blob 選別してコピー（`windows-native/export-windows.ps1` と同じ方式）
6. リランカー（int8 のみ）・OCR 言語データ・スクリプト・設定・ライセンスをコピー
7. **`verify-package.sh`**：同梱物の網羅性を検証（不足があれば中断）
8. `checksums/package.sha256` を生成
9. `tar` + `pigz -1` で `.tar.gz` 化し、SHA-256 を記録

### 🔴 WSL2 で `docker build` が DNS エラーになる場合

`curl: (6) Could not resolve host: github.com` が出るのは既知の WSL2 DNS 不調
（`docs/HANDOFF.md` [B3]）。ホスト側で名前解決した IP を `--add-host` で固定してビルドする。

```bash
docker build --network=host \
  --add-host=github.com:<IP> --add-host=api.github.com:<IP> \
  --add-host=objects.githubusercontent.com:<IP> \
  --add-host=release-assets.githubusercontent.com:<IP> \
  --add-host=codeload.github.com:<IP> --add-host=raw.githubusercontent.com:<IP> \
  --add-host=registry.npmjs.org:<IP> --add-host=astral.sh:<IP> \
  --add-host=storage.googleapis.com:<IP> --add-host=deb.nodesource.com:<IP> \
  -t localrag-anythingllm:1.1.0 -f docker/Dockerfile .
```

IP は `getent ahostsv4 <host>` で取得する。

---

## 4. 各ファイルの役割

### `package/docker-compose.yml`

`runtime/docker-compose.yml`（開発用）を配布向けにしたもの。主な違い:

| 項目 | 開発用 | 配布用 |
|---|---|---|
| バインドマウント | ラベル無し | **`:z`（SELinux 対応）** |
| 設定 | `environment:` にインライン | `env_file:`（`config/*.env`） |
| ポート公開 | `3001:3001`（全インターフェース） | `${OTE_RAG_BIND:-127.0.0.1}:${OTE_RAG_PORT:-3001}:3001` |
| コンテナ名 | `anythingllm` / `rag-ollama` | `ote-rag-app` / `ote-rag-ollama`（開発環境と衝突しない） |
| Ollama イメージ | `ollama/ollama:latest` | **`ollama/ollama:0.30.11`（タグ固定）** |
| データパス | `./ollama-models` 等の相対 | `${OTE_RAG_DATA}/...`（`.env` で指定） |

`.env`（`OTE_RAG_DATA` / `OTE_RAG_PORT` / `OTE_RAG_BIND`）は `install.sh` が生成する。
手で `docker compose` を叩くときは **必ずインストール先ディレクトリで実行する**
（`.env` は compose のプロジェクトディレクトリからしか読まれない）。

#### SELinux ラベルに `:z` を選んだ理由

- `:Z` はコンテナ専有の MCS カテゴリを付けるため、ホスト側の保守作業
  （バックアップ、`docker compose run --rm` の一時コンテナ、別コンテナからの参照）が
  すべて `Permission denied` になる。単一製品・単一テナントの本構成では利点がない。
- `:z`（共有ラベル）なら同じデータを別コンテナからも読める。
- SELinux が Disabled / Permissive の環境では `:z` は無視されるだけで害はない。

### `package/config/*.template`

**設定値の正は `windows-native/config/*.template`。** Windows 固有の項目だけを
Docker 向けに読み替えてある（`STORAGE_DIR`、`OLLAMA_BASE_PATH`、`SERVER_HOST`、
`LOCAL_SERVICE_CONTROL` の扱い）。

`install.sh` がこれを `config/server.env` / `config/collector.env` として配置し、
compose が `env_file` で読む。既存の設定と内容が違う場合はタイムスタンプ付きで退避してから更新する。

**Windows 版テンプレートに無くて Linux 版で足したもの**（開発環境の compose にはあった）:

| 変数 | 理由 |
|---|---|
| `OLLAMA_DISABLE_THINKING=true` | gemma4 の thinking 暴走による空回答対策。**コード側の既定は OFF** |
| `QUERY_REFORMULATION=true` | P1（拒否前の自動言い換え再検索）。**コード側の既定は OFF** |

→ この2つは Windows 版 v1.2.7 の配布設定に**入っていない**。詳細は
`docs/LINUX_DISTRIBUTION_2026-07-28.md` §「Windows 版との差分」。

### `package/install.sh`

前提条件の検査 → SHA-256 検証 → `docker load` → **コンテナからの GPU 実地確認** →
配置 → 設定生成 → モデル配置 → systemd 登録 → 起動 → ヘルスチェック待ち、の9ステップ。

- **完全オフライン**：`docker pull` / `ollama pull` / `dnf install` / 外部 `curl` を一切含まない
  （`verify-package.sh` の検査項目 D で機械的に確認している）
- **冪等**：再実行しても壊れない。既存の文書データ（`documents` / `lancedb` / `*.db`）は触らない
- 失敗時は日本語で原因と対処を示し、`survey-target.sh` の実行を案内する
- `--bind` に loopback 以外を指定すると、管理者パスワード未設定のまま公開される危険を
  警告し、対話で確認する（非対話なら `--yes` が必要）

### `package/systemd/ote-rag.service`

`Type=oneshot` + `RemainAfterExit=yes` で `docker compose up -d` / `stop` を呼ぶだけ。
`@INSTALL_ROOT@` / `@DOCKER@` は `install.sh` が置換する
（置換漏れは `verify-package.sh` の検査項目 E で検出する）。

compose 側にも `restart: unless-stopped` があるため二重の担保になっている。

### `verify-image.sh`

`docker create` → `docker cp` → `docker rm` で **コンテナを起動せずに** イメージ内のファイルを取り出し、
fork のソースと SHA-256 を比較する。あわせて frontend バンドルを検査する。

- `localhost:3001` が焼き込まれていないこと（`VITE_API_BASE` が dev 値のままだと起きる）
- `この配布版では利用できません`（productProfile の URL ガード文言）が含まれること

### `verify-package.sh`

「参照されているのに同梱されていないファイル」を機械的に検出する。

| 検査 | 内容 |
|---|---|
| A | `install.sh` が参照する `$PKG_ROOT` 配下のパスがすべて実在するか（ループ変数経由の分は該当行の存在をアサートしてから確認） |
| B | compose の `env_file` / 変数がそろっているか、全バインドマウントに `:z` が付いているか |
| C | compose の `image:` タグが同梱イメージ tar の `manifest.json` と一致するか、全サービスに `pull_policy: never` があるか |
| D | 同梱スクリプトに外部ネットワークへ出る処理が無いか |
| E | systemd unit のプレースホルダを `install.sh` が置換するか |
| F | `survey-target.sh` がリポジトリ版と同一（無改変）か、実行権限があるか |

---

## 5. リリース（分割アップロード）

配布物は約12GBで、GitHub Releases の1アセット上限（2GiB）を超える。

```bash
./linux-native/dist-split/split-release.sh dist-linux/ote-rag-linux-x64-v1.1.0.tar.gz
# → dist-linux/parts/ に .001 … と MANIFEST.txt, join.sh, README.md
gh release create ... dist-linux/parts/*
```

受け取り側は `join.sh` で結合＋SHA-256 検証する。方式は `windows-native/dist-split/` と同じ
（`.001` 連番なので 7-Zip でも結合できる）。

---

## 6. 未検証の事項

**`install.sh` は導入先に相当する環境で実行していない**（開発機では 166問の測定が動いており、
コンテナを起動・停止できないため）。静的検査（`bash -n` / shellcheck）と、
同梱物の網羅性検証までは実施済み。

実測できたこと／できなかったことの区別は `docs/LINUX_DISTRIBUTION_2026-07-28.md` に記載する。
