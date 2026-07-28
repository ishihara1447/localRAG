# Linux（RHEL 9 / Docker / GPU）向けオフライン配布物の新規作成 — 報告

作成日: 2026-07-28（**組み立て・検証・分割と本書の完成は 2026-07-29 00:07〜00:30**）
担当: Claude Code（サブエージェント）。**2026-07-29 に別担当が引き継ぎ、組み立て・検証・分割を完了させた**
対象: `linux-native/` 一式、`dist-linux/`（配布物）、`docs/LINUX_DISTRIBUTION_2026-07-28.md`（本書）
きっかけ: 導入先が Windows ではなく **RHEL 9 + Docker + NVIDIA GPU + 完全オフライン**であることが判明

> **⚠️ 最初に読むところ**
> - **Windows 資材（`windows-native/`, `/mnt/c/LocalRAG/`, v1.2.7）は一切変更していない。**
>   OCR 言語データを**読み取りのみ**で複製した以外、削除も改変もしていない。
> - **`install.sh` は実行して検証していない。** 開発機は WSL2 であり RHEL 9 ではなく、
>   また `anythingllm` / `rag-ollama` コンテナが稼働中で停止できないため。
>   **何を実測し、何が未検証かは §6 で明確に分けた。**
> - **導入先の調査結果（`survey.txt`）がまだ届いていない。** 本配布物は
>   **「本物の Docker Engine ＋ nvidia-container-toolkit あり」を前提に作られている。**
>   前提が外れた場合に何を作り直すことになるかは **§7** に明記した。
> - 本書で「推測」と書いた箇所は実測していない。断定はしていない。

---

## 0. 結論（4行）

1. `linux-native/` に **RHEL 9 向けオフライン配布物一式**を新規作成し、**組み立て・検証・分割まで完了した**。
   中核は SELinux ラベル `:z` 対応の compose、9段階の前提条件検査を持つ `install.sh`、
   ビルド時に走る2つの機械検証（イメージ内容の SHA-256 一致／同梱物の網羅性）。
2. **現行ソース（fork HEAD `48c68662`）から新イメージ `localrag-anythingllm:1.1.0` をビルド**し、
   イメージ内のファイルが fork のソースと SHA-256 一致することを実測で確認した。
   既存の `1.0.7`（5日前ビルド）にはオフライン強制・設定メニューガード・
   チャンク単位リランクが**入っていない**ため作り直しが必要だった。
3. **Windows 版 v1.2.7 の設定に2つの欠落を発見した**（`OLLAMA_DISABLE_THINKING` /
   `QUERY_REFORMULATION`）。**どちらもコード側の既定が OFF であることをソースで実測確認**したため、
   採用済みの改善が Windows 配布では効いていない。Linux 版では入れてある。詳細 §4.2。
4. **手順書（`INSTALL_GUIDE.md`）と実装の間に不整合を1件検出した**（コンテナ名）。
   手順書はユーザー管理のため**編集していない。§8.2 に修正依頼として記載**した。

---

## 1. 成果物

すべて `dist-linux/` 配下（**§8.1.2 で `.gitignore` に追加したため git には入らない。追加前は追跡候補になっていた**）。

| 成果物 | 実測サイズ（バイト） | SHA-256 |
|---|---:|---|
| `dist-linux/ote-rag-linux-x64-v1.1.0/`（展開済みパッケージ、43ファイル） | 13,696,116,486 | — |
| `dist-linux/ote-rag-linux-x64-v1.1.0.tar.gz`（配布物本体） | **13,233,889,825** | `937c707de6c2e33888308022a7e39dabb7db5a73e541750293068c7f8b054418` |
| `dist-linux/parts/`（GitHub Release 用の7分割） | 計 13,233,889,825 | `MANIFEST.txt` 参照 |

### 1.1 パッケージのトップレベル構成

```
ote-rag-linux-x64-v1.1.0/
├── survey-target.sh          ★install.sh と同じ階層（展開してすぐ見える位置）
├── install.sh                （実行権限あり）
├── uninstall.sh / start.sh / stop.sh
├── INSTALL_GUIDE.md          導入先担当者向け手順書
├── docker-compose.yml
├── versions.lock             fork commit・イメージID・モデル構成の固定記録
├── NOTICE / LICENSES/        ライセンス表示（9ファイル）
├── config/                   server.env.template / collector.env.template / ollama.env
├── systemd/ote-rag.service
├── docs/MODEL_CARDS.md
├── checksums/package.sha256  42ファイル分（自分自身を除く全ファイル）
├── images/                   Docker イメージ2本
├── models/ollama/            gemma4:12b + bge-m3（マニフェスト駆動で blob を選別）
└── assets/                   リランカー ONNX int8 + OCR 言語データ
```

### 1.2 分割配布（7パート）

| ファイル | サイズ（バイト） |
|---|---:|
| `ote-rag-linux-x64-v1.1.0.tar.gz.001`〜`.006` | 各 1,900,000,000 |
| `ote-rag-linux-x64-v1.1.0.tar.gz.007` | 1,833,889,825 |
| `MANIFEST.txt` | 1,073 |
| `join.sh` | 3,762 |
| `README.md` | 2,040 |

分割単位 1,900,000,000 バイト（GitHub Releases の1アセット上限 2GiB に対する安全側）。

---

## 2. 同梱物の実測サイズと内訳

`du -sb --apparent-size` による実測値。**すべて実ファイルを数えた値であり、見積もりではない。**

| 区分 | 実測（バイト） | 概算 | 内訳 |
|---|---:|---:|---|
| `images/` | 4,385,532,399 | 4.08 GiB | Docker イメージ2本（gzip 済み） |
| `models/` | 8,714,219,333 | 8.12 GiB | Ollama モデル（blob 8個 + manifest 2個） |
| `assets/` | 596,076,057 | 568 MiB | リランカー + OCR 言語データ |
| `LICENSES/` | 178,433 | 174 KiB | 9ファイル |
| トップレベルの各ファイル | 68,517 | 67 KiB | install.sh, survey-target.sh, INSTALL_GUIDE.md 等 |
| `config/` | 14,928 | 15 KiB | env テンプレート3本 |
| `docs/` | 10,609 | 10 KiB | MODEL_CARDS.md |
| `systemd/` | 5,022 | 4.9 KiB | ote-rag.service |
| **合計** | **13,696,116,486** | **12.75 GiB** | 43ファイル |

### 2.1 `images/` の内訳

| ファイル | バイト | 中身 |
|---|---:|---|
| `ollama-0.30.11.tar.gz` | 3,242,018,441 | `ollama/ollama:0.30.11`（レイヤ4） |
| `localrag-anythingllm-1.1.0.tar.gz` | 1,143,509,862 | `localrag-anythingllm:1.1.0`（レイヤ20、非圧縮 3,487,531,383） |

### 2.2 `models/` の内訳（マニフェストから blob を辿って実測）

**gemma4:12b — 小計 7,556,508,396 バイト（7.04 GiB）**

| 種別 | バイト | digest |
|---|---:|---|
| model（GGUF 本体） | 7,381,382,048 | `sha256:1278394b6936…` |
| projector | 175,115,584 | `sha256:675ad6e68101…` |
| license | 10,174 | `sha256:0d542e0c8804…` |
| config | 548 | `sha256:c805f5b265d8…` |
| params | 42 | `sha256:56380ca2ab89…` |

**bge-m3:latest — 小計 1,157,672,605 バイト（1.08 GiB）**

| 種別 | バイト | digest |
|---|---:|---|
| model | 1,157,671,200 | `sha256:daec91ffb5dd…` |
| license | 1,068 | `sha256:a406579cd136…` |
| config | 337 | `sha256:0c4c9c2a325f…` |

> **選別方式**: `runtime/ollama-models/` 全体をコピーせず、**マニフェストが参照する blob だけを選んで複製**している
> （`build-linux.sh` 手順4-2）。開発機には旧モデル（qwen3, mxbai 等）の blob が残っているため、
> 全体コピーすると配布物が数十GB に膨らむ。

### 2.3 `assets/` の内訳

| ファイル | バイト | 備考 |
|---|---:|---|
| `reranker/…/onnx/model_quantized.onnx` | 570,727,094 | bge-reranker-v2-m3 ONNX **int8**。fp32 の `model.onnx` は**意図的に同梱しない** |
| `reranker/…/tokenizer.json` | 17,082,900 | |
| `tesseract/eng.traineddata` | 5,199,098 | **OCR 言語データ（英語）** |
| `tesseract/jpn.traineddata` | 3,039,374 | **OCR 言語データ（日本語）** |
| `reranker/…/config.json` ほか2ファイル | 計 2,591 | tokenizer_config / special_tokens_map / config |

> **OCR 言語データを同梱する理由**: これが無いと、スキャン PDF の取り込み時に
> tesseract.js が CDN から `*.traineddata` を取りに行き、**オフライン環境では失敗する**。
> `windows-native/assets/tesseract/` から**読み取りのみ**で複製した（Windows 資材は無変更）。

---

## 3. Windows 版との差分

| 観点 | Windows v1.2.6 / v1.2.7 | Linux v1.1.0 | 理由 |
|---|---|---|---|
| 配布形態 | `OTE-RAG-win64-v1.2.6.zip`（11,018,859,839 バイト）+ `OTE-RAG-Setup.exe`（.NET GUI） | `ote-rag-linux-x64-v1.1.0.tar.gz`（13,233,889,825 バイト）+ `install.sh`（CLI） | Linux 側に GUI インストーラは作らない。RHEL 9 サーバは CLI 前提 |
| 実行方式 | **ネイティブ**（Node ランタイム + `ollama.exe` を直接起動） | **Docker Compose**（コンテナ2本） | 導入先が Docker 前提と判明したため |
| サイズ差 | — | **約 +2.2GB** | Docker イメージ2本（4.08 GiB）を同梱する分。Windows はネイティブバイナリを直置き |
| サービス管理 | WinSW（`LocalRAG-Ollama` / `LocalRAG-Collector`） | systemd unit `ote-rag.service` + compose の `restart: unless-stopped` | |
| プロセス間通信 | `http://127.0.0.1:11435`（ホストのループバック） | `http://ollama:11434`（compose の内部ネットワーク） | コンテナ間名前解決 |
| ネットワーク分離 | なし（全部ローカルホスト） | **`rag-internal`（`internal: true`）と `rag-public` の2網に分離**。Ollama は外部到達不可 | Docker ならではの強化 |
| UI の公開範囲 | `127.0.0.1` 既定 | `127.0.0.1` 既定（`.env` の `OTE_RAG_BIND`） | **同じ**。2026-07-15 の脆弱性対応を踏襲 |
| SELinux | 該当なし | **バインドマウントに `:z`** | RHEL 9 の Enforcing 対策 |
| パス | `{{INSTALL_ROOT}}\app\...`（テンプレート置換） | `/app/...`（コンテナ内固定） | |
| `OLLAMA_DISABLE_THINKING` | **未設定（＝OFF）** | `true` | **§4.2 参照。Windows 側の欠落** |
| `QUERY_REFORMULATION` | **未設定（＝OFF）** | `true` | **§4.2 参照。Windows 側の欠落** |
| 版数 | 1.2.7 | **1.1.0** | Linux 版は独立採番の初版 |

> **版数が Windows より小さいことについて**: Linux 版は別系統の初版であり、
> Windows の 1.2.7 より機能が古いという意味ではない。**中身のソースは同じ fork HEAD `48c68662`** で、
> Linux 版のほうが §4.2 の2設定を正しく入れている分だけ設定面では進んでいる。

---

## 4. 設定値の移植

### 4.1 移植の方針

`windows-native/config/*.template` を出発点に、**パスとエンドポイントだけを Linux/Docker 向けに読み替えた**。
モデル・検索・生成に関わるパラメータは**一切変更していない**（評価済みの構成を崩さないため）。

| 項目 | Windows | Linux |
|---|---|---|
| `OLLAMA_BASE_PATH` / `EMBEDDING_BASE_PATH` | `http://127.0.0.1:11435` | `http://ollama:11434` |
| `STORAGE_DIR` | `{{INSTALL_ROOT}}\app\server\storage` | `/app/server/storage` |
| `COLLECTOR_HOTDIR_PATH` | `{{INSTALL_ROOT}}\app\collector\hotdir` | `/app/collector/hotdir` |
| `SERVER_PORT` | `{{SERVER_PORT}}`（置換） | `3001`（固定。外部公開ポートは compose 側で変える） |
| `SERVER_HOST` | （なし） | `0.0.0.0`（**コンテナ内**での待ち受け） |
| `LLM_SERVICE_NAME` / `COLLECTOR_SERVICE_NAME` / `LOCAL_SERVICE_CONTROL=winsw` | WinSW 用 | **削除**（Linux では無意味） |

> `SERVER_HOST=0.0.0.0` は**コンテナ内部の待ち受けアドレス**であり、ホストの外へ出す設定ではない。
> ホスト側の公開範囲は compose の `"${OTE_RAG_BIND:-127.0.0.1}:${OTE_RAG_PORT:-3001}:3001"` が決める。

### 4.2 🔴 Windows 版で見つかった2つの欠落

Linux 版のテンプレートを作る過程で、`windows-native/config/server.env.template` に
**採用済みの改善を有効化する設定が入っていない**ことが分かった。**コード側の既定はどちらも OFF** である。

| 設定 | コード側の既定 | 根拠（ソースで実測） | Windows v1.2.7 | Linux v1.1.0 |
|---|---|---|---|---|
| `OLLAMA_DISABLE_THINKING` | **OFF** | `server/utils/AiProviders/ollama/index.js:290,347` が `process.env.OLLAMA_DISABLE_THINKING === "true"` でのみ有効化 | **未設定** | `true` |
| `QUERY_REFORMULATION` | **OFF** | `server/utils/chats/queryReformulation.js:17` が `process.env.QUERY_REFORMULATION === "true"` を返す。同ファイル9行目のコメントにも「既定OFF」と明記 | **未設定** | `true` |

**意味**: gemma4 の thinking 抑制とクエリ再構成は、**Windows 配布版では効いていない**。
どちらもコード側で `=== "true"` の厳密比較なので、未設定なら確実に無効。

> **これは Linux 版の作業で偶然見つかった Windows 側の課題**であり、本タスクの範囲外として
> 修正していない（`windows-native/` は保全対象）。**Windows 版の次回ビルド時に対応が必要。**

---

## 5. RHEL 9 特有の落とし穴への対処

| 落とし穴 | 起きること | 対処 | 状態 |
|---|---|---|---|
| **SELinux Enforcing** | バインドマウントにラベルが無いとコンテナがモデルを読めず `Permission denied` で起動失敗 | compose の全バインドマウントに **`:z`**（共有ラベル）を付与。`:Z`（専有）は保守作業が全部弾かれるため不採用 | **実装済み。実機検証は §6.2** |
| **`docker` が podman の別名** | compose 書式・GPU の渡し方・マウントの扱いが違い、そのままでは動かない | `install.sh` が `docker --version` に `podman` が含まれるかを検査し、**日本語で理由を説明して停止**する | **実装済み（コード確認済み）** |
| **nvidia-container-toolkit 欠如** | GPU があってもコンテナから使えず **CPU 動作に転落＝実用外** | `install.sh` が4通り（`nvidia-ctk` / `nvidia-container-runtime-hook` / `/usr/bin/...` / `docker info` の Runtimes）で検出。さらに**実際に `docker run --gpus all nvidia-smi -L` を走らせて確認**する | **実装済み。実行検証は §6.2** |
| **cgroup v2** | Docker 20.10 未満では動かない | `install.sh` が `docker info` の `ServerVersion` / `CgroupVersion` を検査 | **実装済み** |
| **compose v1 しか無い** | `deploy.resources` による GPU 予約が解釈されない | `docker compose version` の成否で判定し、v1 検出時は専用メッセージ | **実装済み** |
| **オフラインなのに pull される** | 起動時にレジストリへ出て失敗 | 全サービスに **`pull_policy: never`**。イメージは `install.sh` が `docker load` | **実装済み・検証済み（§6.1）** |
| **ディスク不足** | 途中で失敗 | データ12GiB / Docker 10GiB / 配置先 1GiB を事前確認 | **実装済み** |
| **UID/GID 不一致** | コンテナが storage に書けない | `install.sh` が `anythingllm-storage` を 1000:1000、`ollama-models` を 0:0 に `chown` | **実装済み** |

---

## 6. 検証（実測できたこと／できなかったこと）

**この節が本書の要点である。「入れたつもり」を排除するために行った検証をすべて列挙する。**

### 6.1 ✅ 実測したこと（24項目・すべて PASS）

| # | 検証 | 方法 | 結果 |
|---|---|---|---|
| 1 | **イメージの中身が fork のソースと一致するか** | `verify-image.sh`。コンテナを**起動せず** `docker create` → `docker cp` で15ファイルを取り出し SHA-256 比較 | **PASS**（15/15 一致） |
| 2 | frontend バンドルに dev 値が焼き込まれていないか | 同上。`server/public/index.js`（2,794,144 バイト）を検査 | **PASS**（`localhost:3001` を含まない） |
| 3 | 設定メニュー改修がバンドル済みか | 同上。ガード文言の存在を確認 | **PASS** |
| 4 | **同梱物の網羅性**（参照されているのに無いファイルの検出） | `verify-package.sh` の A〜F 全6セクション | **PASS**（NG 0件） |
| 5 | install.sh が参照する全パスの実在 | verify-package の A に加え、**独立に `$PKG_ROOT` 参照22件を全列挙して個別確認** | **PASS**（22/22 実在） |
| 6 | compose の env_file / 変数 / image タグ | verify-package の B・C | **PASS** |
| 7 | **全バインドマウントに SELinux `:z` が付いているか** | verify-package の B | **PASS**（2/2） |
| 8 | **`pull_policy: never` が全サービスに付いているか** | verify-package の C | **PASS**（2/2） |
| 9 | **同梱スクリプトが外部ネットワークへ出ないか** | verify-package の D（`docker pull` / `ollama pull` / `dnf install` / `curl https://` 等を grep） | **PASS**（0件） |
| 10 | systemd プレースホルダを install.sh が置換するか | verify-package の E | **PASS**（`@INSTALL_ROOT@` / `@DOCKER@`） |
| 11 | `survey-target.sh` が無改変で同梱されているか | verify-package の F（リポジトリ版と `cmp`） | **PASS**（同一・実行権限あり） |
| 12 | **`docker load` が実際に成功するか** | 同梱 tar.gz 2本を**実際に `docker load`** | **PASS**（`Loaded image: localrag-anythingllm:1.1.0` / `ollama/ollama:0.30.11`、rc=0） |
| 13 | イメージ tar が破損していないか | `pigz -t` で gzip 完全性テスト | **PASS**（2/2） |
| 14 | tar 内の RepoTags が正しいか | tar から `manifest.json` を取り出して確認 | **PASS**（レイヤ20 / 4） |
| 15 | **Ollama blob が壊れていないか** | 8個すべてについて**ファイル名（＝内容ハッシュ）と実際の SHA-256 を照合** | **PASS**（不一致 0件） |
| 16 | **マニフェストが参照する blob が全部あるか** | manifest を parse して blob 実在を確認 | **PASS**（gemma4 5個 / bge-m3 3個） |
| 17 | **パッケージ内容が原本と同一か** | スクリプト・設定・リランカー・OCR・manifest の**22ファイル + LICENSES 全体**を原本と SHA-256 比較 | **PASS**（22/22 + LICENSES 完全一致） |
| 18 | `checksums/package.sha256` の正しさ | 42ファイル分を生成し `sha256sum -c` で自己検証 | **PASS**（全ファイル一致） |
| 19 | **`install.sh` の静的検査** | **shellcheck 0.10.0** | **PASS（指摘0件）** |
| 20 | 他の同梱スクリプトの静的検査 | 同上（start/stop/uninstall/build/verify×2/split/join/survey） | **PASS**（severity≧warning は**全スクリプトで0件**。info の SC2012/SC2015/SC2016/SC1003/SC1091 のみ） |
| 21 | **`--bind 0.0.0.0` の警告があるか** | `install.sh` を読んで確認 | **既に実装済み**（§6.3） |
| 22 | tarball の完全性 | `pigz -t` + `tar -tzf`。エントリ65件と主要15パスの実在確認、blob 8件 | **PASS** |
| 23 | **分割の MANIFEST が実ファイルと一致するか** | `sha256sum -c` で7パート照合 + 元SHA-256/元サイズの照合 | **PASS**（7/7 OK、MANIFEST/tarball/パート合計の3者一致） |
| 24 | **結合すると元に戻るか** | `cat parts/*.00? \| sha256sum` を元 tarball のハッシュと比較（**ラウンドトリップの実証**） | **PASS**（完全一致） |

### 6.2 ❌ 実測していないこと（＝導入先で初めて分かること）

**ここに挙げた項目は「動くはず」であって「動くと確認した」ではない。**

| # | 未検証の項目 | なぜできなかったか | 外れたときの影響 |
|---|---|---|---|
| 1 | **`install.sh` の通し実行** | 開発機は WSL2 で RHEL 9 ではない。かつ `anythingllm` / `rag-ollama` が稼働中で停止できない | 導入手順そのもの。**最大のリスク** |
| 2 | **`docker run --gpus all` による GPU 疎通**（install.sh 手順4） | 開発機に nvidia-container-toolkit 構成の検証環境が無い | GPU が使えないと CPU 転落＝実用外 |
| 3 | **SELinux `:z` が実際に効くか** | WSL2 に SELinux が無い（`getenforce` 不在） | Enforcing 環境で `Permission denied` の可能性 |
| 4 | **`docker compose up` の成功** | 稼働中コンテナに触れないため | 起動しない可能性 |
| 5 | **systemd unit の実際の登録・起動** | WSL2 の systemd 構成が導入先と異なる | 自動起動しない可能性 |
| 6 | **コンテナ間名前解決**（`http://ollama:11434`） | compose を上げていない | LLM/embedding に到達できない |
| 7 | **UID 1000 / root の chown が実環境で足りるか** | 同上 | storage に書けない可能性 |
| 8 | **オフライン実機での OCR 動作**（スキャン PDF 取り込み） | 実機が無い | 言語データの配置先が違えば CDN 取得に走る |
| 9 | **`join.sh` を導入先で実行したときの挙動** | ラウンドトリップは**ストリームで実証済み（§6.1 #24）**だが、`join.sh` スクリプト自体は実行していない | 結合手順が失敗する可能性（ロジックは shellcheck 済み） |
| 10 | **RAG の回答精度が Windows 版と同等か** | 実機評価をしていない | §4.2 の2設定が入った分、**むしろ変わる可能性がある**（未測定） |
| 11 | **podman 環境での動作** | 前提として除外している | **§7 参照。作り直しになる** |

### 6.3 `--bind 0.0.0.0` の警告について（確認結果）

**指示された「警告が無ければ追加する」については、既に実装済みであることを確認したため追加していない。**
`install.sh` の該当箇所は2つある。

1. **インストール開始前**（111〜151行）: `BIND` が `127.0.0.1` / `localhost` / `::1` 以外のとき、
   「管理者パスワード未設定で LAN 公開すると誰でも文書を閲覧・API キー取得できる」旨を明示し、
   **対話端末では `[y/N]` の確認を要求**。非対話環境では `--yes` が無い限り**エラーで停止**する
   （自動化スクリプトから事故で LAN 公開されるのを防ぐ設計）。
2. **インストール完了後**（611〜616行）: 完了バナーで再度警告し、管理者パスワード設定と
   firewalld での絞り込みを促す。

正しい手順（loopback で入れる → SSH ポート転送で開く → パスワード設定 → `.env` 変更 → firewalld）も
警告本文に含まれている。**設計として十分と判断した。**

---

## 7. 🔴 未確定の前提 — 導入先の調査結果待ち

**`survey-target.sh` の実行結果（`survey.txt`）がまだ届いていない。**
本配布物は以下の2点を**前提として作られている**。

| 前提 | 確認方法 | **外れた場合に何を作り直すか** |
|---|---|---|
| **① `docker` が本物の Docker Engine である**（podman の別名でない） | `survey.txt` の「2. コンテナ実行環境」。`docker --version` に `podman` が出るか | **作り直しの規模: 大**<br>・compose の書式（`deploy.resources` による GPU 予約は podman-compose で解釈が異なる）<br>・GPU の渡し方（`--gpus all` ではなく CDI `--device nvidia.com/gpu=all`）<br>・SELinux ラベルの既定挙動が異なる<br>・rootless 運用ならバインドマウントの UID マッピングが変わり、`install.sh` の `chown` 設計ごと見直し<br>・**なお `install.sh` はこの場合を検出して停止する**（黙って誤動作はしない） |
| **② nvidia-container-toolkit が導入済みである** | `survey.txt` の「3. GPU」。`nvidia-ctk` / `docker info` の Runtimes に nvidia があるか | **作り直しの規模: 小〜中（ただし導入先作業が重い）**<br>・**配布物自体の作り直しは不要**<br>・ただし**オフラインで RPM を依存関係ごと持ち込む作業**が別途必要<br>・持ち込めない場合、GPU が使えず **CPU 動作＝1問あたり数分で実用外**。製品として成立しない<br>・**`install.sh` は検出して停止する**（黙って CPU 転落しない） |

### 7.1 その他、調査結果で確定する項目

| 項目 | 未確定の理由 | 影響 |
|---|---|---|
| GPU の VRAM 容量 | 未調査 | `install.sh` は 16GB 未満で停止（`--force` で続行可）。gemma4:12b が載らないと CPU 転落 |
| ディスク空き容量 | 未調査 | ピークで概算 34GB（分割ファイル + tarball + 展開 + Docker イメージ）が必要 |
| ポート 3001 / 11434 の空き | 未調査 | 競合時は `--port` で回避 |
| Docker Engine のバージョン | 未調査 | 20.10 未満なら cgroup v2 環境で動かない |
| compose v2 プラグインの有無 | 未調査 | 無ければ RPM 持ち込みが必要 |
| ファイル転送手段 | 未調査 | 12.3GiB × 7分割の持ち込み方法が決まらない |

---

## 8. 🔴 引き継ぎ担当が加えた変更・検出した不整合

### 8.1 実装を変更した箇所（2件）

### 8.1.1 `systemd/ote-rag.service` のリンク切れ修正

| ファイル | 変更内容 | 理由 |
|---|---|---|
| `linux-native/package/systemd/ote-rag.service` | `Documentation=file://@INSTALL_ROOT@/README.md` → `…/INSTALL_GUIDE.md`（理由コメント付き） | **配布物に `README.md` は含まれていない**（`linux-native/README.md` は開発者向けのため意図的に非同梱）。`install.sh` が実際に `@INSTALL_ROOT@` へ配置するのは `INSTALL_GUIDE.md` であり、変更前は `systemctl status` から辿れないリンク切れになっていた。systemd の起動自体には影響しない軽微な不具合 |

> この変更後に `verify-package.sh` の E セクション（プレースホルダ置換の確認）を通過することを再検証し、
> `checksums/package.sha256` を再生成して `sha256sum -c` で全ファイル一致を確認している。
> **tarball と分割はこの修正を取り込んだ後に作成している**（修正 00:10 → tar 00:23 → 分割 00:26）。

### 8.1.2 🔴 `.gitignore` に `/dist-linux/` を追加（**コミット事故の防止**）

| ファイル | 変更内容 | 理由 |
|---|---|---|
| `.gitignore` | `/dist-linux/` を追加（36行目付近） | **`dist-linux/` は除外されていなかった。** 既存の `dist/` は末尾が違うため一致せず、`git status` に `?? dist-linux/` として**約26GB（パッケージ13GB + tarball 12.3GB + 分割12.3GB）が追跡候補として出ていた**。<br>さらに悪いことに、25行目の `models/` パターンが `dist-linux/…/models/` にだけ効くため、**「モデル8.1GB は無言で除外され、Docker イメージ4GB は commit される」という中途半端な状態**になり得た。Windows 版は出力先が `/mnt/c/LocalRAG/dist` のためこの問題が表面化していなかった |

> **`git commit` の前にこの変更が入っていることを確認してください。** 適用後は `git status` から
> `dist-linux/` が消えることを実測確認済み（`git check-ignore -v dist-linux/` → `.gitignore:36:/dist-linux/`）。

### 8.2 🔴 `INSTALL_GUIDE.md` と実装の不整合（**ユーザー管理ファイルのため未修正・要対応**）

**`linux-native/INSTALL_GUIDE.md` は編集禁止の指示があるため触っていない。以下の修正をお願いしたい。**

compose は `container_name: ote-rag-app` / `ote-rag-ollama` を指定しているが、手順書は別名を案内している。

| 箇所 | 現在の記載 | 実装（compose） | 影響 |
|---|---|---|---|
| **225行目** | 「`anythingllm` と `ollama` の2つのコンテナが動いていれば正常です」 | `ote-rag-app` / `ote-rag-ollama` | `docker ps` の表示名が違い、**利用者が「起動していない」と誤認する** |
| **300行目** | `docker logs anythingllm` でログを確認 | 同上 | **コマンドが `No such container` で失敗する** |
| **305〜306行目** | `docker logs anythingllm --tail 100` / `docker logs ollama --tail 100` | 同上 | 同上。**トラブル時に真っ先に叩くコマンドが動かない** |

**修正案**（実装側は変更不要。手順書を実装に合わせる）:

```
docker logs ote-rag-app --tail 100
docker logs ote-rag-ollama --tail 100
```

> **注意**: 開発機で稼働中の別プロジェクトのコンテナ名がまさに `anythingllm` / `rag-ollama` であるため、
> **開発機で叩くと「動いてしまう」**（別プロジェクトのログが出る）。導入先では必ず失敗する。

### 8.3 手順書の記載で確認をお願いしたい点（軽微）

| 箇所 | 記載 | 実測 | 備考 |
|---|---|---|---|
| 104行目 | 「配布物は約 14GB」 | **12.32 GiB（13,233,889,825 バイト）** | 実測に合わせるなら「約 12.5GB」「7分割」 |
| 117行目 | 分割ファイルの一覧 | **`.001`〜`.007` の7個** | 個数が確定した |
| 120行目 | 「`survey-target.sh`（**資材にも同梱されます**）」 | 資材への同梱は**実装済み・検証済み**。ただし **`dist-split/split-release.sh` は `parts/` に `survey-target.sh` を置かない** | Release へは**別途アップロードが必要**（アップロード判断はユーザー側のため未実施） |
| 8〜11行目 | 「導入資材（tarball）は**作成中**」 | **作成完了** | 資材の状態表記の更新が必要 |

---

## 9. 次にやること

1. **導入先へ `survey-target.sh` を渡し、`survey.txt` を受け取る**（§7 の前提①②の確定。**最優先**）
2. §8.2 の `INSTALL_GUIDE.md` 修正（ユーザー作業）
3. `git commit`（ユーザー作業。`linux-native/` 一式 + 本書 + **`.gitignore` の修正（§8.1.2）**。`dist-linux/` は除外済み）
4. `gh release create` で7パート + `MANIFEST.txt` + `join.sh` + `survey-target.sh` をアップロード（ユーザー判断）
5. **Windows 版の次回ビルドで §4.2 の2設定を追加**
6. 導入先での実機検証（§6.2 の11項目）

---

## 付録: 再現手順

```bash
# 配布物の再ビルド（イメージは既にある前提）
./linux-native/build-linux.sh --skip-build

# 個別に検証だけ回す
bash linux-native/verify-image.sh   localrag-anythingllm:1.1.0
bash linux-native/verify-package.sh dist-linux/ote-rag-linux-x64-v1.1.0

# 分割
bash linux-native/dist-split/split-release.sh dist-linux/ote-rag-linux-x64-v1.1.0.tar.gz
```

`versions.lock`（配布物に同梱）に、この配布物の出自が固定記録されている。

```
package_version=1.1.0
platform=linux/amd64 (RHEL 9 / Docker + NVIDIA GPU)
fork_commit=48c68662f68a9173cf8a8496bcddb784357845b3
fork_branch=product/customer-rag-base
fork_dirty=no
image_anythingllm_id=sha256:9960868882779de740028b932f70fb7728c384f50d8339d9c378740d99e24fbb
image_ollama_id=sha256:7247ccb08fbf8bd6bdadd54b56c620007016fb4d0e05888a020b9f3e2964b5f5
models=gemma4:12b, bge-m3:latest
reranker=onnx-community/bge-reranker-v2-m3-ONNX (int8, model_quantized.onnx)
ocr=tesseract jpn+eng
```
