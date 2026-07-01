# Claude Code へのレビュー指摘と修正依頼

作成日: 2026-07-02  
対象: LocalRAG オフライン配布パッケージ化対応  
参照順: `AGENTS.md` → `docs/HANDOFF.md` → `docs/OFFLINE_DISTRIBUTION_HARDENING_PLAN.md` → 本ファイル

---

## 1. 結論

前回の修正は方向性としては合っているが、**意図通りには完了していない**。

特に、顧客配布可否を左右する P0/P1 の中核が未完。

最重要の未達:

- 公式 `mintplexlabs/anythingllm:latest` がまだ使われている。
- `anything-llm/` 側の外部 LLM provider allowlist 改修が、実行 image に反映されていない。
- `package.sha256` 生成が壊れている。
- checksum 検証が強制ではなく、欠落時にスキップされる。
- `versions.lock` に `unknown` が残り得る。
- `rag-e2e-test.sh` が export パッケージに同梱されない。
- backup 処理に不具合がある。
- unrelated な実行権限変更が残っている。

この状態では、まだ顧客配布用パッケージとして合格にしない。

---

## 2. 現在確認された差分

親リポジトリ:

```text
 M runtime/docker-compose.yml
 M scripts/export.sh
 M scripts/install.sh
 M scripts/smoke-test.sh
 M scripts/uninstall.sh
?? AGENTS.md
?? docs/OFFLINE_DISTRIBUTION_HARDENING_PLAN.md
?? fixtures/
?? scripts/backup.sh
?? scripts/rag-e2e-test.sh
?? scripts/restore.sh
?? scripts/start.sh
?? scripts/stop.sh
```

`anything-llm/` 側:

```text
 M docker/docker-entrypoint.sh
 M server/utils/agents/aibitat/plugins/create-files/docx/test-themes.js
```

ただし `anything-llm/` 側は内容変更なしで、実行権限のみ変化している。

---

## 3. 必ず直すべき指摘

### P0-1. 公式 `latest` image が残っている

該当:

- `runtime/docker-compose.yml`
- `scripts/export.sh`

現状:

```text
image: mintplexlabs/anythingllm:latest
ANYTHINGLLM_IMAGE="mintplexlabs/anythingllm:latest"
```

問題:

- `anything-llm/` に実装済みの allowlist 改修が配布 image に入らない。
- 公式 `latest` は再現性がなく、顧客配布に不適。
- `docs/OFFLINE_DISTRIBUTION_HARDENING_PLAN.md` の P0 完了条件を満たしていない。

修正方針:

- `anything-llm/` からカスタム image をビルドする。
- 例:

```bash
cd /home/ishihara1447/projects/localRAG/anything-llm
docker build --network=host -t localrag-anythingllm:1.0.0 -f docker/Dockerfile .
```

- `runtime/docker-compose.yml` を独自 image に差し替える。

```yaml
image: localrag-anythingllm:1.0.0
```

- `scripts/export.sh` の既定 image も独自 image にする。
- 顧客配布用 compose から `mintplexlabs/anythingllm:latest` を排除する。

完了条件:

- `runtime/docker-compose.yml` に `mintplexlabs/anythingllm:latest` が残っていない。
- `scripts/export.sh` の既定値に `mintplexlabs/anythingllm:latest` が残っていない。
- カスタム image 起動後、外部 cloud provider が API 側で拒否される。

---

### P1-1. `package.sha256` 生成が壊れている

該当:

```bash
scripts/export.sh
```

現状の問題箇所:

```bash
find . -type f ... -print0 | sort -z | xargs -0 sha256_cmd > "checksums/package.sha256"
```

問題:

- `sha256_cmd` は shell function。
- `xargs` は shell function を直接実行できない。
- さらに `|| true` で失敗を握りつぶしている。
- 空または未生成の `package.sha256` を成功扱いする恐れがある。

修正方針:

- `xargs sha256_cmd` を使わない。
- `while read` 形式で function を呼ぶか、OS 別に実体コマンドを変数化する。
- 失敗時に `exit` する。
- `package.sha256` が空なら失敗する。

例:

```bash
(
  cd "$OUTPUT_DIR"
  find . -type f \
    ! -path './checksums/*' \
    ! -name 'export.log' \
    -print0 \
    | sort -z \
    | while IFS= read -r -d '' f; do
        sha256_cmd "$f"
      done > "checksums/package.sha256"
)

[[ -s "$OUTPUT_DIR/checksums/package.sha256" ]] || {
  log ERROR "package.sha256 の生成に失敗しました"
  exit 1
}
```

完了条件:

- `package.sha256` が確実に生成される。
- 生成失敗時に export が失敗する。
- `|| true` で握りつぶさない。

---

### P1-2. checksum 検証が強制になっていない

該当:

```bash
scripts/install.sh
```

現状:

```text
checksum ファイルが見つからないため検証をスキップ
```

問題:

- 顧客配布パッケージで checksum 欠落を許すべきではない。
- 真正性検証が任意になっている。

修正方針:

- 新レイアウトの以下を必須にする。

```text
checksums/images.sha256
checksums/ollama-models.sha256
checksums/package.sha256
```

- 旧レイアウト後方互換は、開発用途だけに限定するか削除する。
- 顧客配布 install では checksum 欠落時に停止する。

完了条件:

- checksum ファイル欠落時に `install.sh` が失敗する。
- checksum 不一致時に `install.sh` が失敗する。
- 「検証をスキップ」という正常系ログが残らない。

---

### P1-3. `versions.lock` に `unknown` が残り得る

該当:

```bash
scripts/export.sh
```

現状:

```bash
GIT_COMMIT="$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo 'unknown')"
ANYTHINGLLM_DIGEST=$(docker inspect ... || echo "unknown")
OLLAMA_DIGEST=$(docker inspect ... || echo "unknown")
```

問題:

- `unknown` のまま配布物を作れてしまう。
- 監査・再現性の観点で不合格。

修正方針:

- `unknown` になったら export を失敗させる。
- image digest が取得できない場合は止める。
- Git commit が取得できない場合も、理由を明示して止めるか、明示的な `--allow-unknown-git` のような例外指定を要求する。

完了条件:

- `versions.lock` に `unknown` が残らない。
- `unknown` 発生時に export が失敗する。

---

### P2-1. `rag-e2e-test.sh` が配布物に同梱されない

該当:

```bash
scripts/export.sh
```

現状:

```bash
for s in install.sh uninstall.sh smoke-test.sh start.sh stop.sh backup.sh restore.sh; do
```

問題:

- `fixtures/` はコピーされるが、RAG E2E テスト本体がコピーされない。
- 顧客先で「文書投入 → embedding → RAG 回答 → 出典 → 文書外質問」を検証できない。

修正方針:

- `rag-e2e-test.sh` をコピー対象に追加する。
- もしくは `smoke-test.sh` から `rag-e2e-test.sh` を呼べるようにする。

完了条件:

- export されたパッケージ直下に `rag-e2e-test.sh` が存在する。
- `fixtures/test-policy.txt` とセットで動作する。

---

### P2-2. backup の `versions.lock` 同梱処理が不正

該当:

```bash
scripts/backup.sh
```

現状:

```bash
tar czf "$BACKUP_FILE" -C "$SCRIPT_DIR" anythingllm-storage
[[ -f "$SCRIPT_DIR/versions.lock" ]] && \
  tar rf "${BACKUP_FILE%.gz}" -C "$SCRIPT_DIR" versions.lock 2>/dev/null || true
```

問題:

- `.tar.gz` 作成後に、別名の `.tar` へ追記しようとしている。
- バックアップ本体に `versions.lock` が入らない可能性が高い。
- 余計な `.tar` ファイルが残る恐れがある。

修正方針:

- tar 作成時にまとめて含める。

例:

```bash
BACKUP_ITEMS=(anythingllm-storage)
[[ -f "$SCRIPT_DIR/versions.lock" ]] && BACKUP_ITEMS+=(versions.lock)
tar czf "$BACKUP_FILE" -C "$SCRIPT_DIR" "${BACKUP_ITEMS[@]}"
```

完了条件:

- `tar tzf backups/localrag-backup-*.tar.gz` で `versions.lock` が確認できる。
- 余計な `.tar` ファイルが生成されない。

---

### P2-3. unrelated な実行権限変更を戻す

該当:

親リポジトリ:

```text
scripts/export.sh
scripts/install.sh
scripts/smoke-test.sh
scripts/uninstall.sh
```

`anything-llm/`:

```text
docker/docker-entrypoint.sh
server/utils/agents/aibitat/plugins/create-files/docx/test-themes.js
```

問題:

- 内容変更ではなく `100755 => 100644` の mode change。
- 今回の修正目的と無関係。
- entrypoint や shell script の実行に悪影響が出る。

修正方針:

```bash
chmod +x scripts/export.sh scripts/install.sh scripts/smoke-test.sh scripts/uninstall.sh
chmod +x scripts/start.sh scripts/stop.sh scripts/backup.sh scripts/restore.sh scripts/rag-e2e-test.sh

cd anything-llm
chmod +x docker/docker-entrypoint.sh
chmod +x server/utils/agents/aibitat/plugins/create-files/docx/test-themes.js
```

完了条件:

- `git diff --summary` に意図しない mode change が残らない。
- 新規スクリプトも実行可能になっている。

---

## 4. ドキュメントと実装の食い違い

`docs/PROJECT_STATUS.md` には、以下が完了済みのように書かれている。

- checksum 強制検証
- ロード後の image 実在確認
- アーキテクチャ検証
- LICENSES / NOTICE 雛形

しかし、現状の実装では確認できない、または未完。

対応:

- 実装を先に完了させる。
- 完了していない項目は `PROJECT_STATUS.md` で「未完」「次作業」に戻す。
- ドキュメントだけを先に進めない。

---

## 5. 追加で確認したこと

構文チェックは通過:

```bash
bash -n scripts/export.sh
bash -n scripts/install.sh
bash -n scripts/backup.sh
bash -n scripts/restore.sh
bash -n scripts/rag-e2e-test.sh
```

compose 設定チェックも通過:

```bash
cd runtime
docker compose config --quiet
```

ただし、構文が通ることと、顧客配布品質を満たすことは別。

---

## 6. 修正後に実行する検証

### 6.1 静的確認

```bash
git status --short --branch
git diff --stat
git diff --summary
git diff --check

rg -n "mintplexlabs/anythingllm:latest|latest|unknown|checksum ファイルが見つからないため検証をスキップ|xargs -0 sha256_cmd" runtime scripts docs
```

期待:

- 顧客配布用 compose / export から `mintplexlabs/anythingllm:latest` が消えている。
- `versions.lock` 生成で `unknown` を許していない。
- checksum 欠落をスキップしない。
- `xargs -0 sha256_cmd` が残っていない。
- 意図しない mode change がない。

### 6.2 構文確認

```bash
for f in scripts/*.sh; do
  bash -n "$f"
done
```

### 6.3 compose 確認

```bash
cd runtime
docker compose config --quiet
```

### 6.4 カスタム image 起動確認

```bash
cd /home/ishihara1447/projects/localRAG/runtime
docker compose up -d
docker compose ps
curl -s http://localhost:3001/api/ping
docker compose logs --tail=100 anythingllm
```

### 6.5 export 生成物確認

ネットワークと時間が許す場合:

```bash
bash scripts/export.sh --version 1.0.0 --output ./dist/localrag-1.0.0

test -f dist/localrag-1.0.0/checksums/images.sha256
test -f dist/localrag-1.0.0/checksums/ollama-models.sha256
test -f dist/localrag-1.0.0/checksums/package.sha256
test -f dist/localrag-1.0.0/rag-e2e-test.sh

grep -q unknown dist/localrag-1.0.0/versions.lock && exit 1 || true
```

---

## 7. 優先順位

この順番で直すこと。

1. カスタム AnythingLLM image 化と `latest` 排除。
2. `package.sha256` 生成修正。
3. checksum 欠落時の install fail 化。
4. `versions.lock` の `unknown` 禁止。
5. `rag-e2e-test.sh` の export 同梱。
6. `backup.sh` の `versions.lock` 同梱修正。
7. 実行権限 mode change の復旧。
8. `docs/PROJECT_STATUS.md` / `docs/HANDOFF.md` を実装状態に合わせて更新。

---

## 8. 完了判定

以下を満たしたら、この指摘対応は完了。

- [ ] `runtime/docker-compose.yml` が `localrag-anythingllm:<version>` を使う。
- [ ] `scripts/export.sh` の既定 image が公式 `latest` ではない。
- [ ] `scripts/export.sh` から `xargs -0 sha256_cmd` と `|| true` による握りつぶしが消えている。
- [ ] `scripts/install.sh` が checksum 欠落時に失敗する。
- [ ] `versions.lock` に `unknown` が残らない。
- [ ] export パッケージに `rag-e2e-test.sh` が入る。
- [ ] backup `.tar.gz` に `versions.lock` が正しく入る。
- [ ] `git diff --summary` に不要な mode change が残らない。
- [ ] `bash -n scripts/*.sh` 相当が通る。
- [ ] `docker compose config --quiet` が通る。
- [ ] `docs/PROJECT_STATUS.md` と `docs/HANDOFF.md` が実装状態と矛盾しない。

