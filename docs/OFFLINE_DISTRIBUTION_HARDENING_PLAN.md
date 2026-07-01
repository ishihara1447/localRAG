# オフライン顧客配布パッケージ改善計画

作成日: 2026-06-30  
対象: `localRAG` / AnythingLLM 顧客配布パッケージ  
目的: 現在の検証用パッケージを、顧客へ安全に渡せるオフライン配布パッケージへ引き上げる。  
一次情報: `docs/anythingllm_customer_distribution_plan.md`  
開始時に読むこと: `AGENTS.md` → `docs/HANDOFF.md` → 本計画書

---

## 1. 現状評価

現在のパッケージは、オフライン配布の骨格としては有効だが、顧客配布品質には未達。

良い点:

- `runtime/docker-compose.yml` で AnythingLLM + Ollama の Docker 構成がある。
- Ollama は内部ネットワークに置かれ、ホストへ直接公開されていない。
- `pull_policy: never` により、配布先での暗黙 pull を避ける設計になっている。
- `scripts/export.sh` / `install.sh` / `smoke-test.sh` / `uninstall.sh` があり、配布パッケージ化の入口がある。
- `HF_HUB_OFFLINE=1`、`DISABLE_TELEMETRY=true` など、ローカル・オフライン運用を意識した設定がある。

重大な不足:

- 現在の compose は `mintplexlabs/anythingllm:latest` を使っており、`anything-llm/` 側のハードニング改修が実行イメージに反映されていない。
- `latest` タグ依存があり、再現性・監査性が弱い。
- Docker image の checksum はあるが、Ollama モデル群の完全な manifest / checksum がない。
- `versions.lock` は生成されるが、install 時の強制検証が弱い。
- `DISABLE_SWAGGER_DOCS`、Community Hub、Agent download、危険 Agent 無効化など、顧客配布向けのセキュリティ既定値が未完成。
- ライセンス、NOTICE、SBOM、モデルカード、第三者依存情報が配布物に入っていない。
- smoke test が API ping 中心で、RAG の実動作・出典・文書外質問の検証まで自動化されていない。
- Windows 顧客向けの PowerShell スクリプトが未整備。

結論:

```text
現状 = 社内検証用のオフライン風パッケージ
目標 = 顧客に渡せる、再現可能・検証可能・監査可能なオフライン配布パッケージ
```

---

## 2. ゴール

この計画の完了時点で、以下を満たす。

- 配布先がインターネットに接続されていなくてもインストール・起動できる。
- 配布物に含まれる Docker image、モデル、設定、スクリプトのバージョンとハッシュが固定されている。
- 改修済み AnythingLLM image が使われ、外部クラウド LLM provider がバックエンドで拒否される。
- Telemetry、Swagger docs、Community Hub download、Agent skill download、危険 Agent が既定で無効。
- 顧客文書・embedding・RAG 問い合わせが外部 API へ送信されない設計になっている。
- インストール後に、文書投入から RAG 回答まで自動 smoke test できる。
- ライセンス、NOTICE、SBOM、モデル情報、運用手順が配布物に同梱される。
- バックアップ、リストア、アンインストールの手順が安全に用意されている。

---

## 3. 絶対ルール

- 顧客文書を外部送信しない。
- OpenAI / Anthropic / Gemini など外部 LLM・embedding provider を有効化しない。
- UI 非表示だけで済ませず、バックエンド API 側で allowlist / denylist を強制する。
- Desktop 版バイナリを改造・再配布しない。
- 配布物はソースからビルドした Docker/self-hosted 版を基にする。
- `latest` タグで顧客配布しない。
- Hugging Face や GitHub から本番起動時に動的取得しない。
- `trust_remote_code` が必要なモデルは、事前レビューとコミットハッシュ固定を必須にする。
- embedding モデルを変更する場合は、全文書の再 embedding が必要であることを文書化する。
- `runtime/anythingllm-storage/` と `runtime/ollama-models/` はコミットしない。
- 未コミットの既存変更はユーザー作業として扱い、勝手に戻さない。

---

## 4. 作業順序

優先順位は以下。

```text
P0: 配布してはいけない状態を解消する
P1: オフライン再現性と真正性を固める
P2: 顧客運用に必要なスクリプトと検証を整える
P3: 法務・監査・ドキュメントを同梱する
P4: 仕上げの実機検証とリリース手順を固める
```

---

## 5. P0: カスタム AnythingLLM image 化

### 5.1 目的

現在の `mintplexlabs/anythingllm:latest` 依存をやめ、`anything-llm/` のハードニング済みコードから顧客配布用 image を作る。

### 5.2 作業

- `anything-llm/` の現在ブランチを確認する。
- `product/customer-rag-base` の改修内容を確認する。
- Docker ビルド方法を確定する。
- Docker DNS 問題を解消する。
- `localrag-anythingllm:<version>` のような独自タグで image を作る。
- `runtime/docker-compose.yml` の image を公式 `latest` から独自 image に置き換える。
- image digest を `versions.lock` に記録する。

### 5.3 注意

現在の既知問題:

- Docker build コンテナ内で `github.com` DNS 解決失敗がある。
- Phase 2 前に Docker Desktop の DNS 設定修正が必要。
- `server/collector` の `sharp` ビルド問題があるため、Docker build 側で再現するか確認する。

### 5.4 完了条件

- `docker compose up -d` で独自 AnythingLLM image が起動する。
- 起動ログまたは API 挙動で、外部 LLM provider が拒否されることを確認できる。
- compose に `mintplexlabs/anythingllm:latest` が残っていない。
- `latest` タグを顧客配布用 compose で使っていない。

### 5.5 検証例

```bash
cd runtime
docker compose up -d
docker compose ps
curl -s http://localhost:3001/api/ping
docker compose logs --tail=100 anythingllm
```

---

## 6. P0: セキュリティ既定値の明示

### 6.1 目的

顧客配布時に、危険機能や外部通信を既定で無効にする。

### 6.2 compose / env に明示する候補

必須:

```env
DISABLE_TELEMETRY=true
DISABLE_SWAGGER_DOCS=true
COMMUNITY_HUB_BUNDLE_DOWNLOADS_ENABLED=false
HF_HUB_OFFLINE=1
```

検討:

```env
EMBED_REQUIRE_ALLOWLIST=true
WORKSPACE_DELETION_PROTECTION=1
```

Agent 関連は AnythingLLM の実装を調査し、以下を満たすこと:

- Web browsing / scraping 系 Agent を既定無効。
- SQL Agent を既定無効。
- FileSystem Agent を既定無効。
- Agent Skill download を既定無効。
- 必要な場合でも管理者が明示許可したものだけ使える構成にする。

### 6.3 完了条件

- 顧客配布 compose にセキュリティ既定値が明示されている。
- Swagger docs が無効。
- Community Hub / Agent Skill download が無効。
- 外部クラウド provider を API から指定しても拒否される。

---

## 7. P1: バージョン固定と真正性検証

### 7.1 目的

配布物が「何から作られたか」「改ざんされていないか」を顧客先で確認できるようにする。

### 7.2 作業

- `versions.lock` を拡張する。
- Docker image の repo digest を記録する。
- Docker image tar の SHA-256 を記録する。
- `ollama-models/` 配下の全ファイル checksum manifest を生成する。
- LLM モデル名、digest、取得元、ライセンス、サイズを記録する。
- embedding モデル名、digest、取得元、ライセンス、サイズを記録する。
- install 時に checksum を強制検証する。
- 検証失敗時はインストールを停止する。

### 7.3 成果物

```text
versions.lock
checksums/
  images.sha256
  ollama-models.sha256
  package.sha256
```

### 7.4 完了条件

- `install.sh` が image と model の checksum を検証する。
- checksum 不一致時に停止する。
- `versions.lock` の値が `unknown` のまま残らない。

---

## 8. P1: export.sh 改善

### 8.1 目的

オンライン環境で、顧客配布用パッケージを再現可能に生成する。

### 8.2 作業

- `latest` を使わず、明示バージョン・digest を入力できるようにする。
- `--version`、`--output`、`--llm-model`、`--embed-model` のような引数を検討する。
- export 開始時に Git commit hash、AnythingLLM upstream version、localRAG version を記録する。
- Docker image save 後に checksum を作る。
- Ollama モデル取得後に file manifest を作る。
- `LICENSES/`、`NOTICE`、`SBOM`、各ガイドを同梱する。
- 最終的な package checksum を生成する。

### 8.3 完了条件

- `bash scripts/export.sh ./dist/localrag-<version>` で配布物一式が生成される。
- 生成物だけを別ディレクトリにコピーしても install できる。
- export log に使用 image、model、commit、checksum が残る。

---

## 9. P2: install.sh 改善

### 9.1 目的

顧客先で安全・明確にインストールできるようにする。

### 9.2 作業

- 必須ファイルの存在確認を強化する。
- ディスク空き容量の基準を見直す。
  - 最低: 30GB
  - 推奨: 100GB 以上
- Docker / Compose / GPU / NVIDIA runtime のチェックを分かりやすくする。
- checksum 検証を強制化する。
- 既存インストール検出時の選択肢を明確にする。
- `anythingllm-storage/` が既にある場合、上書きせず再利用する。
- インストールログに version / checksum / image digest を出す。

### 9.3 完了条件

- 前提不足時に、何を直せばよいかログで分かる。
- checksum 不一致時に停止する。
- 既存データを誤って削除しない。
- install 後に `http://localhost:3001` が起動する。

---

## 10. P2: smoke-test.sh 改善

### 10.1 目的

インストール後に、RAG とセキュリティ既定値を最低限自動確認する。

### 10.2 現状の不足

- API key がないと肝心の検証が skip される。
- 文書 upload / embedding / RAG / 出典 / 文書外質問が自動化されていない。
- 外部 provider 拒否の検証がない。

### 10.3 作業

- テスト用文書を `fixtures/` に同梱する。
- API key の取得方法を明確化する。
- 可能なら初期 API key の発行・投入手順を install log に誘導する。
- ワークスペース作成を自動化する。
- テスト文書 upload を自動化する。
- embedding 完了を待機する。
- RAG 質問を投げ、期待語句と出典有無を確認する。
- 文書外質問を投げ、「不明」系の応答を確認する。
- Swagger docs 無効、外部 provider 拒否、Ollama 内部接続を確認する。

### 10.4 テスト項目

```text
1. GET /api/ping
2. AnythingLLM -> Ollama 内部通信
3. GPU / CPU モード確認
4. ワークスペース作成
5. 文書アップロード
6. embedding 完了
7. 出典付き RAG 回答
8. 文書外質問で不明回答
9. 外部 provider 拒否
10. Swagger docs 無効
```

### 10.5 完了条件

- smoke test だけで、顧客先の基本動作可否が判断できる。
- FAIL 時に次に見るべきログが表示される。

---

## 11. P2: backup / restore / uninstall

### 11.1 目的

顧客データを安全に扱える運用スクリプトを用意する。

### 11.2 作業

追加:

```text
scripts/backup.sh
scripts/restore.sh
scripts/start.sh
scripts/stop.sh
```

Windows 顧客向け:

```text
scripts/install.ps1
scripts/start.ps1
scripts/stop.ps1
scripts/backup.ps1
scripts/restore.ps1
```

uninstall 改善:

- `rm -rf` 前に絶対パスを検証する。
- `anythingllm-storage/` 削除前に backup を促す。
- `--keep-data` を既定にするか検討する。
- モデル削除は明示オプションにする。

### 11.3 完了条件

- 顧客データを zip / tar.gz でバックアップできる。
- restore 後に `docker compose up -d` で復旧する。
- uninstall で意図しないディレクトリを削除しない。

---

## 12. P3: ライセンス / NOTICE / SBOM

### 12.1 目的

商用配布に必要な法務・監査情報を同梱する。

### 12.2 成果物

```text
LICENSES/
  AnythingLLM_LICENSE.txt
  Ollama_LICENSE.txt
  llm-jp_LICENSE.txt
  embedding_model_LICENSE.txt
  THIRD_PARTY_NOTICES.txt

NOTICE
SBOM/
  syft-json.json
  syft-spdx.json
MODEL_CARDS/
  llm-model.md
  embedding-model.md
```

### 12.3 作業

- AnythingLLM MIT license を同梱する。
- Ollama MIT license を同梱する。
- 使用 LLM のライセンスを同梱する。
- 使用 embedding model のライセンスを同梱する。
- Docker image の SBOM を生成する。
- 依存ライセンス一覧を作る。
- 量子化モデルを使う場合、変換元・変換者・改変表示・hash を記録する。

### 12.4 完了条件

- 配布物単体で、使用物とライセンスを説明できる。
- 顧客監査に対し、バージョン・依存・ライセンス・hash を提示できる。

---

## 13. P3: 顧客向けドキュメント

### 13.1 成果物

```text
README.md
INSTALL_GUIDE.md
OPERATIONS_GUIDE.md
SECURITY_GUIDE.md
TROUBLESHOOTING.md
CHANGELOG.md
```

### 13.2 各文書に書くこと

`README.md`:

- LocalRAG の概要
- できること / できないこと
- システム構成
- 起動 URL

`INSTALL_GUIDE.md`:

- 前提条件
- インストール手順
- 初期ログイン
- smoke test

`OPERATIONS_GUIDE.md`:

- 起動 / 停止 / 再起動
- バックアップ / リストア
- ログ確認
- データ保存場所

`SECURITY_GUIDE.md`:

- 外部通信方針
- 無効化している機能
- 顧客文書の保存場所
- API key 管理
- モデル・embedding 変更時の注意

`TROUBLESHOOTING.md`:

- Docker が起動しない
- GPU が見えない
- モデルがロードされない
- RAG 回答が遅い
- API key が分からない
- ポート 3001 が競合する

### 13.3 完了条件

- 非開発者でもインストールと起動確認ができる。
- 障害時に一次切り分けができる。

---

## 14. P4: 実機オフライン検証

### 14.1 目的

本当にインターネットなしで導入できることを確認する。

### 14.2 検証シナリオ

クリーン環境で実施:

```text
1. 既存 Docker image / volume / model cache を削除
2. ネットワークを切断
3. 配布パッケージだけをコピー
4. install を実行
5. smoke test を実行
6. PDF / DOCX / TXT を投入
7. RAG 回答と出典を確認
8. 文書外質問で不明回答を確認
9. backup を作成
10. uninstall --keep-data
11. restore
12. 再起動後にデータが残ることを確認
```

### 14.3 完了条件

- ネットワークなしで install が成功する。
- ネットワークなしで RAG が動く。
- 起動時に外部へ pull / download しようとしない。
- バックアップから復旧できる。

---

## 15. Claude Code 作業ガイド

### 15.1 作業開始時

必ず以下を読む。

```bash
cat AGENTS.md
cat docs/HANDOFF.md
cat docs/anythingllm_customer_distribution_plan.md
cat docs/OFFLINE_DISTRIBUTION_HARDENING_PLAN.md
```

### 15.2 最初に確認する状態

```bash
git status --short --branch
git -C anything-llm status --short --branch
docker compose -f runtime/docker-compose.yml ps
```

### 15.3 原則

- 1改修1ブランチ、または少なくとも1改修1コミットに分けられる単位で作業する。
- ユーザーが明示しない限り commit / push しない。
- 既存の未コミット変更を勝手に戻さない。
- 大容量モデル、DB、storage、logs をコミットしない。
- 変更後は必ず該当スクリプトの shellcheck 相当確認、または dry-run / smoke test を行う。

### 15.4 優先して着手するタスク

最初の Claude Code セッションでは、以下の順で進める。

1. `runtime/docker-compose.yml` のセキュリティ env を補強する。
2. `scripts/export.sh` から `latest` 固定を排除する設計にする。
3. `versions.lock` と checksum manifest の仕様を決める。
4. `install.sh` に checksum 強制検証を追加する。
5. `smoke-test.sh` に RAG 検証 fixture を追加する。

ただし、`anything-llm/` のカスタム Docker build が未解決の場合は、Docker DNS 問題の解消を先に行う。

---

## 16. 完了判定チェックリスト

P0:

- [ ] 公式 `mintplexlabs/anythingllm:latest` を顧客配布 compose で使っていない。
- [ ] 改修済み AnythingLLM image が使われている。
- [ ] 外部 LLM provider が API 側で拒否される。
- [ ] Telemetry / Swagger / Community Hub / Agent download が既定無効。

P1:

- [ ] Docker image digest が固定されている。
- [ ] Docker image tar checksum がある。
- [ ] Ollama model checksum manifest がある。
- [ ] install 時に checksum を強制検証する。
- [ ] `versions.lock` に `unknown` が残っていない。

P2:

- [ ] install / uninstall / smoke-test が顧客環境で実行できる。
- [ ] backup / restore がある。
- [ ] Windows PowerShell 版スクリプトがある、または対象外理由が明記されている。
- [ ] smoke test が RAG と出典、不明回答まで確認する。

P3:

- [ ] LICENSES が同梱されている。
- [ ] NOTICE が同梱されている。
- [ ] SBOM が同梱されている。
- [ ] INSTALL / OPERATIONS / SECURITY / TROUBLESHOOTING がある。

P4:

- [ ] 完全オフライン環境で install 成功。
- [ ] 完全オフライン環境で RAG 成功。
- [ ] 起動時に外部 download / pull が発生しない。
- [ ] backup / restore 成功。

---

## 17. 推奨ブランチ名

```text
docs/offline-distribution-plan
hardening/custom-anythingllm-image
hardening/security-default-env
feature/package-checksums
feature/offline-smoke-test
feature/backup-restore-scripts
docs/customer-guides
```

---

## 18. 最初の具体タスク案

次の作業者は、まず以下を実施する。

```text
Task 1:
  runtime/docker-compose.yml に顧客配布向けセキュリティ env を追加する。

Task 2:
  scripts/export.sh の image/model バージョン固定方式を設計し、latest 依存をなくす。

Task 3:
  checksums/ollama-models.sha256 を生成・検証する処理を export/install に追加する。

Task 4:
  smoke-test 用 fixture 文書を追加し、RAG 回答と文書外質問を検証する。

Task 5:
  LICENSES/NOTICE/SBOM の雛形を追加する。
```

各 Task は完了後、`docs/HANDOFF.md` に結果・未解決事項・次手を追記する。

