# 未処置の欠陥一覧（2026-08-06 調査）

作成: 2026-08-06 / 担当: Claude Code
出典: サブエージェント2面の調査（インストーラ系／実行時・製品挙動系）で計31件。
うち14件は v1.2.13 で修正済み（`docs/WORKLOG.md` 2026-08-06 13:00 のエントリ）。
**本書は残る17件。** 次のサイクルで着手する。

🔴 一覧の各項目は**該当行を確認して記載**しているが、v1.2.13 では手を入れていない。
着手時はまず現物を再確認すること（コードが動いている可能性がある）。

---

## 1. 顧客影響が大きい（次版で着手したい）

### 1-1. 旧モデルの blob が残り続け、C: が枯渇する

`install.ps1` はモデルを `/E`（追加のみ）でコピーし、`uninstall.ps1` の keep-data は
`C:\ProgramData\LocalRAG` を丸ごと残す。**削除する箇所がどこにもない。**

実測（2026-08-06、稼働機の `C:\ProgramData\LocalRAG\models` = 14GB）:

| blob | サイズ | 現行版で必要か |
|---|---|---|
| gemma4:12b | 7.38 GB | **不要**（granite4.1 へ差替済） |
| bge-m3 | 1.16 GB | **不要**（granite-embedding へ差替済） |
| granite4.1:8b | 5.35 GB | 必要 |
| granite-embedding:278m | 0.56 GB | 必要 |

現行版が必要とするのは約6GBなのに14GB占有＝**8GBが死蔵**。
`manifests\registry.ollama.ai\library\` にも `bge-m3` / `gemma4` が残る。

`install.ps1` の空き容量チェックは12GB要求だが、「既存モデルを残したまま追加する」量を
考慮していない。数回のアップグレードで C: が枯渇し、次の導入が止まる。

**対処案**: 同梱モデル以外の manifest を削除し、どの manifest からも参照されない blob を
削除する。Ollama の blob は共有されうるので、**参照カウントを取ってから消すこと**。
安易な削除は現行モデルを壊す。

### 1-2. Shift_JIS / CP932 の .txt・.csv が文字化けのまま取り込まれ、原本が削除される

`collector/processSingleFile/convert/asTxt.js` がエンコーディング決め打ち:

```js
content = fs.readFileSync(fullFilePath, "utf8");
...
if (!content?.length) {   // 文字化け文字列は「長さあり」なので素通りする
```

CP932 の日本語を UTF-8 として読むと非空の U+FFFD 列になり、空チェックを通過して
`trashFile(fullFilePath)`（**原本削除**）と `[SUCCESS]` に至る。
collector にエンコーディング判定は1箇所も無い。

対象は `.txt/.md/.csv/.json/.html` ほか。**Excel が既定で吐く日本語CSVが直撃する。**
UTF-8 BOM の除去も無いため、BOM付きCSVは先頭に U+FEFF が残る。

**対処案**: バイト列から判定して decode する（`jschardet` + `iconv-lite` 等）。
判定に失敗したら取り込まず、原本も消さずにエラーを返す。

### 1-3. スキャンPDF の大半が無言で脱落する

`asPDF/index.js` は `docs.length === 0` のときしか OCR に落ちない。
`PDFLoader` はページを飛ばすのが `content.items.length === 0` のときだけで、
**items はあるが str が全部空**（日本語PDFの ToUnicode 欠落）のページは
`pageContent: ""` として push される。

より頻度が高いのは、**表紙1ページだけテキスト層がある300ページのスキャン行政PDF**。
`docs.length === 1` のため OCR は起動せず、**299ページが無言で切り捨てられ `success: true`**。
`jpn.traineddata` は同梱済みなのに使われない。

**対処案**: ページ単位で「テキストが実質空か」を判定し、空ページだけ OCR に回す。
全体が空でなくても OCR を併用する。

---

## 2. 設定・UI の不整合

### 2-1. UI の「Accuracy Optimized」を選ぶと検索チューニングが丸ごと無効化される

`VectorSearchMode` の `rerank` を選ぶと `lance/index.js` の排他分岐により
`LANCE_HYBRID_SEARCH` / `LANCE_HYBRID_RERANK` / `LANCE_HYBRID_CANDIDATE_LIMIT` が
**全部無視され**、dense-only + リランクの別経路になる。

UI の説明文は "your responses will be more accurate and relevant" で、
**顧客には「精度が上がる」と読める**。実際には測定してきた改善が消える。

`WORKSPACE_DEFAULT_VECTOR_SEARCH_MODE` はコードにあるがテンプレートで固定していない。

**対処案**: テンプレートで `default` に固定し、UI から選択肢を消すか、
説明文を実態に合わせる。**固定する場合は protectedKeys に先に入れること**（追加済み）。

### 2-2. `/ext/*` データコネクタ6経路が外部通信できる

`DISABLE_WEB_SCRAPING=true` が塞ぐのは2経路だけ。以下は無ガード:

| 経路 | 宛先 |
|---|---|
| `/ext/github-repo` | api.github.com |
| `/ext/gitlab-repo` | gitlab.com |
| `/ext/youtube-transcript` | youtube.com |
| `/ext/confluence` | 任意URL＋**`NODE_TLS_REJECT_UNAUTHORIZED="0"` をプロセス全体に設定** |
| `/ext/drupalwiki`, `/ext/paperless-ngx` | 任意URL |

LLM/embedder/vectorDB はバックエンドで allowlist 化されているのに、
**文書取り込み経路だけ穴が残っている。** Confluence の TLS 検証無効化は
成功パスでしか復元されない。

**対処案**: `productProfile` にコネクタの allowlist を設け、無効な経路は
サーバー側で 403 にする。フロントのタブも出さない。

### 2-3. 起動時チェックがファイル存在しか見ず、`preload()` が呼ばれていない

`verifyBundledAssets.js` は `fs.existsSync` だけ。`NativeEmbeddingReranker.preload()` は
用意されているのにどこからも呼ばれない。AVX2非対応CPU・破損ONNXでは
**起動時は正常に見え、初回質問で初めて失敗する**。
`install.ps1` のプリフライトにも CPU/AVX2 のチェックが無い。

**対処案**: 起動時に `preload()` を呼ぶ。`install.ps1` に AVX2 判定を足す。

---

## 3. インストーラの堅牢性

### 3-1. サービス削除保留でアップグレードが無限ループする

`uninstall.ps1` はサービスが残っていても警告のみで**終了コード0**。
`Setup.exe` は0を成功と見なして先へ進み、`install.ps1` が
「先にアンインストールを実行してください」で停止する。
**いまアンインストールしたばかりなのに、である。** 再起動が必要とはどこにも出ない。

`Setup.exe` の `finally` は意図的にボタンを再有効化しないため、
顧客はウィンドウを閉じて開き直し、同じ所で失敗し続ける。

発火条件は日常的（services.msc やタスクマネージャでサービスを開いていると
SCM が削除保留にする）。

**対処案**: uninstall 側で削除保留を検出して専用の終了コードを返し、
Setup 側で「再起動してから再実行してください」と案内する。

### 3-2. `-Force` による上書きアップグレードが成立しない

ポート確認が既存インストール確認**より前**にあるため、稼働中の環境に `-Force` をかけると
自分自身のサービスに当たって停止する。案内どおり別ポートを指定すると
**同じマシンに二重のインストールが生まれる。**
コピー前にサービスを停止する処理も無い。

**対処案**: 既存インストールの確認を先に行い、`-Force` のときは
自分のサービスを停止してからポート確認をやり直す。

### 3-3. `-Force` 失敗時のロールバックが旧インストールのサービスを消して「元に戻しました」と表示する

`Invoke-Rollback` のステップ1は `$script:servicesTouched` だけを見ており
`$script:preExisting` を見ていない。ステップ4はファイル削除を回避するのに、
サービス登録解除は実行済み。

その状態で `"環境を元に戻しました。もう一度インストールを実行できます。"` と表示する。
実際には動いていた製品が起動不能になっている。

**対処案**: ステップ1にも `$preExisting` のガードを入れる。

### 3-4. サービス登録のスキップにより、別フォルダへの再インストールが旧ツリーを起動して「成功」と報告する

`register-services.ps1` は「サービスが既にある」とスキップするが、
SCM の ImagePath は旧インストールのまま。`start` は旧バイナリを起動し、
ping は応答を得るので `=== Install complete ===` と表示される。
**顧客は更新したつもりで旧版を使い続ける。**

**対処案**: 既存サービスの ImagePath を比較し、違えば登録し直すか明示的に失敗させる。

### 3-5. `Install-OTE-RAG.cmd` が成功を「失敗」と表示する

`install.ps1` の `exit 3`（ping タイムアウト＝成功扱い）を cmd 側が失敗として表示する。
初回モデル読み込みが120秒を超えるのは想定内で、
`install.ps1` が「完了しました」と出した直後に cmd が上書きする。

**対処案**: cmd 側で 0 と 3 を成功として扱う。

### 3-6. 失敗のたびに `C:\OTR\<日時>` に約12GB が残る

`Setup.exe` は失敗時に展開先を「調査用」として意図的に残すが、掃除するコードが無い。
3回失敗すれば約36GB が積み上がる。
`install.ps1` の12GB事前チェックは Setup 経由では**展開後**に走るため実質機能しない。

**対処案**: 起動時に古い `C:\OTR\*` を消す。空き容量チェックを展開前に移す。

---

## 4. 軽微（実害はあるが優先度は低い）

| # | 内容 |
|---|---|
| 4-1 | Web UI の「Collector停止」は依存関係で必ず失敗するのに `success: true` を返す |
| 4-2 | `.env.production` は実行時に一度も読まれない。`.env` と乖離したまま誰も気づかない。生成をやめるか位置づけを明示する |
| 4-3 | `getGitVersion` が毎起動で `git rev-parse HEAD` を exec し、配布物では必ず失敗してログに出る |
| 4-4 | 埋め込みのバッチサイズが1。1文書1,756チャンクで1,756往復・ログ1,756行 |
| 4-5 | DOCX の段落が区切り無しで連結され、日本語では段落境界が消える |
| 4-6 | ログにファイル名が平文で残る（本文は残らない）。保守にログを送る運用なら文書名は伝わる |

---

## 調査で「問題なし」と確認できたもの（再調査しないため記録）

- ログへの顧客文書本文の漏洩: **無し**
- 認証情報（JWT / SIG_KEY / APIキー / パスワード）の漏洩: **無し**
- テレメトリ（PostHog）: 正しく無効
- huggingface.co / CDN への実通信: 無し。オフライン破りは Ollama と modelMap の2件のみ（v1.2.13 で修正）
- GPU/VRAM: フルGPUオフロード、CPU転落もOOMも無し
- 埋め込みのトークン切り捨て: 無し（ただし bge-m3 での測定。granite-embedding は未検証）
- セパレータによる句点の消失: 無し（`keepSeparator` が既定 true）
- `sc.exe` へのコマンドインジェクション: 無し
- .ps1 の CP932 誤読: 無し（全て UTF-8 BOM 付き）
