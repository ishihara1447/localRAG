# 完全オフライン インストール／起動の保証（2026-07-28）

対象: `anything-llm/`（server / collector）ソース、`windows-native/config/*.template`
担当: Claude Code（サブエージェント）
きっかけ: ユーザー要件「**完全オフラインでインストールする必要があります**」

> **⚠️ 結論を先に: 再ビルドが必要。**
> 現在ビルド中の **v1.2.6 にはこの修正は入っていない**。v1.2.6 は
> 「同梱モデルの配置が正しい限り」オフラインで動くが、**配置がずれた瞬間に黙って
> huggingface.co / cdn.anythingllm.com へ出る**（下記 §3 で実測）。さらに
> **スキャンPDFを1件アップロードすると jsdelivr CDN へ出る**（§2-2、v1.2.6 は未対策）。
> 詳細な判断材料は §7。

---

## 1. まとめ（3行）

1. リランカーが使う **`@xenova/transformers`（JS版）は `HF_HUB_OFFLINE=1` を一切見ない**。
   JS版のオフライン化は `env.allowRemoteModels = false` でしか行えず、**これまで設定していなかった**。
2. リランカー以外にも、**文書を1件アップロードしただけで外部へ出る経路が2つ**あった
   （OCR = jsdelivr CDN、音声文字起こし = huggingface.co）。どちらも未対策だった。
3. 3経路すべてを**既定で塞ぎ**、**日本語の明示的なエラーで停止**するようにした。
   `globalThis.fetch` をフックした実測で **ネットワーク試行 0 件** を確認済み（§4）。

---

## 2. ネットワークへ出る経路の全リスト

「配布構成（`windows-native/config/*.template`）のまま、顧客が普通に使ったときに到達しうるか」で分類した。

### 2-1. 🔴 対策前は未対策だった経路（今回塞いだもの）

| # | 経路 | 出先 | 発火条件 | 対策後 |
|---|---|---|---|---|
| A | **リランカー**（`bge-reranker-v2-m3-ONNX`）<br>`server/utils/EmbeddingRerankers/native/index.js` | `huggingface.co`<br>→ 失敗すると `cdn.anythingllm.com` | 同梱モデルの配置がずれている状態で**検索を1回実行**。`LANCE_HYBRID_RERANK=true` / `LANCE_SENTENCE_CUSHION=true` は既定ONなので毎クエリ通る | `env.allowRemoteModels=false` を既定化。事前にファイル実在を確認し日本語エラー |
| B | **OCR**（`tesseract.js@6.0.1`）<br>`collector/utils/OCRLoader/index.js` | `cdn.jsdelivr.net/npm/@tesseract.js-data/<lang>/...` | **テキスト層の無いPDF／画像ファイルを1件アップロード**。`asPDF` が `docs.length === 0` で自動的にOCRへ落ちる | `langPath` をローカル固定＋`gzip:false`。事前確認して日本語エラー |
| C | **ローカルWhisper**（`Xenova/whisper-small`, 約250MB）<br>`collector/utils/WhisperProviders/localWhisper.js` | `huggingface.co` | **音声ファイルを1件アップロード**。`asAudio` の既定プロバイダが `local` | `env.allowRemoteModels=false` を既定化＋事前確認して日本語エラー |
| D | **nativeエンベッダー**（`Xenova/all-MiniLM-L6-v2`）<br>`server/utils/EmbeddingEngines/native/index.js` | `huggingface.co` → `cdn.anythingllm.com` | 通常は productProfile の許可リストで到達不可。ただし **2026-07-26以前の版から更新した環境**は `EMBEDDING_ENGINE=native` が残ることがあり、`LEGACY_TOLERATED_EMBEDDING_ENGINES` で起動を通している | 同上（多層防御） |

**A・B・C は「同梱漏れ／配置ずれ／未同梱」のときに、オフライン環境で
"原因の分からないハングまたは英語エラー" になる**。これが今回の中心的な問題だった。

### 2-2. 🟢 すでに対策済みだった経路（確認のみ、変更なし）

| 経路 | 既存の対策 | 確認方法 |
|---|---|---|
| Telemetry（PostHog） | `DISABLE_TELEMETRY=true`。`models/telemetry.js:client()` が `null` を返し **PostHogクライアント自体を生成しない** | コード確認 |
| Community Hub（`hub.external.anythingllm.com`） | サーバー側で `COMMUNITY_HUB_BUNDLE_DOWNLOADS_ENABLED` 未設定＝拒否。フロントも `communityHub: false` で非表示 | `utils/middleware/communityHubDownloadsEnabled.js` |
| 外部LLM／埋め込みプロバイダ（OpenAI等 約30ホスト） | `productProfile.js`（server/frontend 2箇所）の許可リストで `ollama` / `lancedb` のみ。UI非表示だけでなく **API 側で拒否** | 2026-07-27 コミット `2e61181d` / `d6e7174d` |
| Swagger docs | `DISABLE_SWAGGER_DOCS=true` | env template |
| Web scraping（puppeteer/Chromium） | `DISABLE_WEB_SCRAPING=true`。Chromium 自体を配布物から除外 | `collector.env.template` |
| Agent Skills / Community Hub UI | `agentSkills: false` / `communityHub: false` | `frontend/src/utils/productProfile.js` |
| Telegram 連携 | `TelegramBotService.bootIfActive()` は connector 未設定なら即 return。UI も `telegram: false` | `utils/telegramBot/index.js:818` |
| Push通知 | VAPID鍵をローカル生成してファイル保存するだけ。外部送信なし | `utils/PushNotifications/index.js:201` |
| 起動時 context window 事前読込 | `LLM_PROVIDER=ollama` なので `127.0.0.1:11435` のみ | `utils/boot/eagerLoadContextWindows.js` |
| フロントエンドの静的アセット | KaTeX フォント等はビルドに同梱。外部フォント／CDN 参照なし | `frontend/dist/` |
| 配布パッケージの整合性 | `checksums/package.sha256` が**パッケージ内の全ファイル**を網羅し、`install.ps1` が展開前に検証。同梱モデルの欠落・破損はインストール時点で検出される | `export-windows.ps1:236` / `install.ps1:217` |

### 2-3. 🟡 残存（今回は変更していない。理由付き）

| 経路 | 状況 | 判断 |
|---|---|---|
| **Ollama 本体（`ollama.exe serve`）** | 配布物は WinSW から `ollama.exe serve` を直接起動しており、自動更新チェックを行う Windows トレイアプリ（`ollama app.exe`）は**インストールしない**。AnythingLLM 側から `/api/pull` を呼ぶコードも**存在しない**（grep で 0 件）。モデルは `C:\ProgramData\LocalRAG\models` に事前配置される | **ネットワークへ出ないと考えられるが、Windows実機での実測は未実施＝推測**。次のオフライン実機検証で `ollama serve` のアウトバウンドを確認すべき |
| **MCP サーバー** | `storage/plugins/anythingllm_mcp_servers.json` が存在するときのみ起動。配布物には含まれない。到達にはエージェントモード＋顧客による明示設定が必要 | 既定で不活性。設定依存のため現状維持 |
| **Piper TTS（ブラウザ側）** | `frontend/src/utils/piperTTS` が有効化されると**ブラウザから** `cdnjs.cloudflare.com`（onnxruntime-web）と `huggingface.co`（音声モデル）を取得する。ただし `voiceSpeech: false` で設定画面ごと非表示、既定でも未使用 | 到達不可のため今回は未対応。将来 TTS を有効化するなら**必ず同梱化とセットで**行うこと |
| **エージェントの Web検索／スクレイピング** | 外部検索APIキーが必要で、`agentSkills: false` により設定画面も非表示 | 設定依存。現状維持 |

---

## 3. 中心的な誤解の訂正: `HF_HUB_OFFLINE` は効かない

`windows-native/config/server.env.template` には以前から `HF_HUB_OFFLINE=1` が入っていた。
しかし **これは Python の `huggingface_hub` 用の環境変数**であり、本製品が実際に使う
**JavaScript 版 `@xenova/transformers` は、この変数をどこでも参照していない**。

JS版のオフライン制御は `env.allowRemoteModels`（既定 **`true`**）だけである。
`@xenova/transformers@2.17.2` のソースで確認した該当箇所:

- `src/env.js` — `allowRemoteModels: true`, `remoteHost: 'https://huggingface.co/'`
- `src/utils/hub.js:445` — `else if (!env.allowRemoteModels) { throw ... }`
- `src/utils/hub.js:456` — `if (options.local_files_only || !env.allowRemoteModels) { throw ... }`
- `src/utils/hub.js:468` — `response = await getFile(remoteURL);` ← **ここに到達するのが唯一のネットワーク経路**

つまり `allowRemoteModels=false` にすると **468行目に到達する前に必ず throw する**ため、
`fetch` は構造的に呼ばれ得ない。設定値の話ではなく、コードパスとして塞がれる。

`HF_HUB_OFFLINE=1` は削除せず残した（将来 Python 系ツールを同梱した場合の保険）が、
**これ単体ではオフライン化にならない**旨をテンプレートにコメントとして明記した。

---

## 4. 検証（実測）

Docker（166問ベースライン測定中）には一切触れず、**`globalThis.fetch` と
`http.request` / `https.request` を差し替えて全アウトバウンドを記録・遮断する
Node スクリプト**で実測した。`@xenova/transformers` は `getFile()` でグローバル
`fetch` を使うため（`hub.js:199`）、この方法で全経路を捕捉できる。

検証スクリプト:
`/tmp/.../scratchpad/reranker-offline-verify.mjs` / `collector-offline-verify.mjs`
（一時ファイル。リポジトリには含めていない）

### 実測結果

| # | 条件 | ネットワーク試行 | 結果 |
|---|---|---|---|
| 1 | 既定（オフライン厳格）／**同梱モデル欠落** | **0 件** | `BundledModelMissingError`、日本語メッセージで停止 |
| 2 | 既定（オフライン厳格）／**同梱モデルあり** | **0 件** | リランク成功（`score=0.9286`、2文書 189ms） |
| 3 | `RERANKER_ALLOW_REMOTE=true`／モデル欠落<br>**＝対策前 v1.2.5 / v1.2.6 の挙動** | **2 件** | `https://huggingface.co/onnx-community/bge-reranker-v2-m3-ONNX/resolve/main/config.json`<br>`https://cdn.anythingllm.com/support/models/onnx-community/bge-reranker-v2-m3-ONNX/config.json` |
| 4 | OCR／言語データ未同梱 | **0 件** | 日本語メッセージで停止（対策前は jsdelivr へ） |
| 5 | ローカルWhisper／モデル未同梱 | **0 件** | 日本語メッセージで停止（対策前は huggingface.co へ） |

**ケース3が最も重要**: これは `RERANKER_ALLOW_REMOTE=true` を明示したときの挙動だが、
コード的には**対策前の既定の挙動そのもの**である。
つまり **v1.2.6 は、同梱モデルの配置が1文字でもずれれば実際に外部へ出る**ことが実証された。

参考として素の `@xenova/transformers` でも同じ差分を確認している:

```
allowRemoteModels=TRUE,  モデル欠落 -> fetch 2件 (huggingface.co: tokenizer.json / tokenizer_config.json)
allowRemoteModels=FALSE, モデル欠落 -> fetch 0件（throw）
allowRemoteModels=FALSE, モデルあり -> fetch 0件（正常ロード）
```

### 検証の限界（正直に）

- **Windows 実機でネットワークアダプタを無効化した状態でのインストール〜起動は未実施。**
  `/mnt/c/LocalRAG/` は別担当がビルド中のため触っていない。
- **Ollama 本体（`ollama.exe serve`）のアウトバウンドは未実測**（§2-3）。
- 上記2点は、**v1.2.7 ビルド後にオフライン実機で確認すべき残タスク**。

---

## 5. 実装内容

### 新規ファイル

| ファイル | 内容 |
|---|---|
| `anything-llm/server/utils/helpers/transformersOffline.js` | `remoteModelsAllowed()` / `applyTransformersOfflinePolicy(env)` / `assertBundledModelPresent()` / `BundledModelMissingError` |
| `anything-llm/collector/utils/transformersOffline.js` | 上記の**複製**。collector は server と独立した npm パッケージで相互 require しない設計のため（`productProfile.js` の frontend/server 2重管理と同じ方針）。**片方だけ直さないこと** |
| `anything-llm/server/utils/boot/verifyBundledAssets.js` | 起動時の同梱モデル実在チェック（**非致命**、日本語警告のみ） |

### 変更ファイル

| ファイル | 変更 |
|---|---|
| `server/utils/EmbeddingRerankers/native/index.js` | `initClient()` で `env.allowRemoteModels=false` を適用 → 事前ファイル確認 → 日本語エラー。オフライン時は**代替ホストへの再帰リトライを打ち切る**。`get host()` がオフライン時に実際の読込元を返す |
| `server/utils/EmbeddingEngines/native/index.js` | `#fetchWithHost()` に同じ方針を適用。オフライン時は `#fallbackHost` へ再試行しない |
| `collector/utils/OCRLoader/index.js` | `workerOptions` getter を追加（`langPath` をローカル固定＋`gzip:false`）。`assertLanguageDataPresent()` を `ocrPDF` / `ocrImage` の先頭で呼ぶ |
| `collector/utils/WhisperProviders/localWhisper.js` | `client()` で同じ方針を適用 |
| `server/utils/boot/index.js` | `bootHTTP` / `bootSSL` の両方に `verifyBundledAssets()` を追加 |
| `windows-native/config/server.env.template` | `RERANKER_ALLOW_REMOTE=false` を追加。`HF_HUB_OFFLINE` に「Python用で効かない」旨を明記 |
| `windows-native/config/collector.env.template` | `OCR_ALLOW_REMOTE=false` / `RERANKER_ALLOW_REMOTE=false` を追加 |

### env フラグ（すべて既定 false ＝ オフライン厳格）

| 変数 | 既定 | 効果 |
|---|---|---|
| `RERANKER_ALLOW_REMOTE` | `false` | リランカー・nativeエンベッダー・ローカルWhisper（transformers.js 全体）のリモート取得 |
| `TRANSFORMERS_ALLOW_REMOTE_MODELS` | `false` | 上の別名 |
| `OCR_ALLOW_REMOTE` | `false` | tesseract.js の言語データ CDN 取得 |

**未設定でもコード側の既定が `false`** なので厳格に動く。テンプレートに明示したのは、
「意図的にオフライン固定している」ことを設定ファイル上で読み取れるようにするため。

### 顧客向けエラーメッセージ（実際の出力）

```
[OTE-RAG] 同梱モデルが見つかりません。インストールが不完全な可能性があります。

  機能        : 検索精度向上機能（リランカー）
  モデル      : onnx-community/bge-reranker-v2-m3-ONNX
  探した場所  : C:\LocalRAG\app\server\storage\models\onnx-community\bge-reranker-v2-m3-ONNX
  不足ファイル: config.json, tokenizer.json, tokenizer_config.json, onnx/model_quantized.onnx

本製品は完全オフラインで動作するため、不足しているファイルを
インターネットから自動でダウンロードすることはありません。

対処: OTE-RAG-Setup.exe を再実行してインストールし直してください。
      それでも解消しない場合は、このメッセージ全文を保守担当へお送りください。
```

transformers.js 自身の英語エラーは、探索先として実際には使っていない
`node_modules/@xenova/transformers/models/...` を表示するため、顧客も保守担当も
原因を誤解する。**先に実体を確認して、本当に探した場所を日本語で示す**ようにした。

### 副次的に見つかった問題: リランカー欠落が「静かに」精度を落とす

リランカーの呼び出し側は 2 箇所（`LanceDb.rerankFusedCandidates` と `sentenceCushion`）
あり、**どちらも例外を握りつぶして元の順序へフォールバックする**。しかも `preload()` は
どこからも呼ばれていない。つまり同梱モデルが欠けていても検索は「動いてしまい」、
**精度だけが静かに落ちて誰も気づけない**（実測差: 平均 anchor_coverage@8 0.646 → 0.723、
`docs/HYBRID_RERANK_2026-07-27.md`）。

対策として `verifyBundledAssets()` を起動時に追加し、欠落時は赤枠の日本語警告をログへ出す。
**起動は止めない**（止めると設定画面にも到達できず復旧不能になるため。呼び出し側の
フォールバック設計とも整合する）。

---

## 6. 配布物への反映確認（パス解決の追跡）

`RERANKER_MODEL_PREF` は配布テンプレートで**未設定** → コード既定
`onnx-community/bge-reranker-v2-m3-ONNX` が使われる。

```
server.env.template : STORAGE_DIR = <InstallRoot>\app\server\storage
        ↓
NativeEmbeddingReranker.cacheDir  = STORAGE_DIR + "\models"
NativeEmbeddingReranker.modelPath = cacheDir + "\onnx-community\bge-reranker-v2-m3-ONNX"
        = <InstallRoot>\app\server\storage\models\onnx-community\bge-reranker-v2-m3-ONNX
```

配布物側:

```
export-windows.ps1:111  Remove-Item  $Pkg\app\server\storage       （まず丸ごと除去）
export-windows.ps1:163  robocopy $RerankerModelDir -> $Pkg\app\server\storage\models\onnx-community\bge-reranker-v2-m3-ONNX
install.ps1:247         robocopy $PkgRoot\app /E   -> $InstallRoot\app
        = <InstallRoot>\app\server\storage\models\onnx-community\bge-reranker-v2-m3-ONNX
```

**✅ 一致している。** 現行の配置は正しく、v1.2.6 も（配置が壊れなければ）オフラインで動く。
今回の変更は「配置が壊れたときに黙ってネットワークへ出る」ことを防ぐもの。

補足:
- `transformers.js` は `FileCache`（= `cache_dir`）を**ローカルパスより先に**参照するため
  （`hub.js:420` `tryCache`）、`env.localModelPath`（`node_modules/.../models/`）が
  存在しなくても同梱モデルは正しく読める。ケース2で実証済み。
- 必要ファイルは `config.json` / `tokenizer.json` / `tokenizer_config.json` /
  `onnx/model_quantized.onnx` の 4 点（`configs.js:46`, `tokenizers.js:62-63`,
  `models.js:122` で確認）。`RERANKER_QUANTIZED=true` 固定なので `model.onnx`（fp32, 未同梱）は不要。
- **OCR 言語データ（`<STORAGE_DIR>\models\tesseract\<lang>.traineddata`）は同梱されていない。**
  今回の変更でスキャンPDFの取り込みは「OCRデータが無い」旨の日本語エラーになる（**ハングしない**）。
  想定文書（行政資料のDTP PDF、Word/Acrobat由来のヘルプPDF）はいずれもテキスト層を持つため
  通常運用に影響はないが、**顧客がスキャンPDFを投入する可能性があるなら
  `eng.traineddata` / `jpn.traineddata`（計約 15MB）を同梱すべき**。これは別途判断が必要。

---

## 7. 🔴 再ビルドの要否

### 結論: **再ビルドが必要（v1.2.7 として）**

ただし緊急度は経路ごとに違う。

| 経路 | v1.2.6 での実害 | 緊急度 |
|---|---|---|
| **B: OCR → jsdelivr CDN** | **スキャンPDF／画像を1件アップロードすると発生。** オフライン環境ではCDN接続待ちでハングし、原因が分からない | **高**。顧客が普通に踏みうる |
| **C: Whisper → huggingface.co** | 音声ファイルをアップロードすると発生。約250MBのダウンロードを試みてハング | 中。RAG用途では踏みにくい |
| **A: リランカー → huggingface.co / cdn.anythingllm.com** | **同梱モデルの配置が正常なら発生しない**（§6 で一致を確認済み）。壊れた場合のみ | 中。ただし「壊れたときに黙って外へ出る」ことが要件と直接矛盾 |
| **D: nativeエンベッダー** | 旧版からの更新環境のみ | 低 |
| 起動時チェック・日本語エラー | 障害時の切り分け時間の差 | 低（品質向上） |

### 判断材料

- **v1.2.6 をそのまま出しても、正常インストールなら動く。** §6 のパス一致は確認済みで、
  §4 ケース2 が「同梱モデルがあればネットワーク0で動く」ことを実証している。
- **ただし「完全オフラインを保証する」とは言えない。** B は正常インストールでも
  顧客の操作だけで発火する。「保証」を要件とするなら v1.2.6 は要件を満たさない。
- 変更はすべて**ソースのみ**（`server/` `collector/` `windows-native/config/`）。
  ネイティブ依存の追加・`package.json` の変更・モデルの追加は**なし**。
  → **`export-windows.ps1` の再実行だけで反映できる。** ビルド手順の変更は不要。

### 推奨

1. **v1.2.6 のビルドは完走させる**（別担当の作業を止めない）。
2. この変更を取り込んだ **v1.2.7 を続けてビルド**し、顧客配布は v1.2.7 から行う。
3. v1.2.7 のビルド後、**Windows 実機でネットワークアダプタを無効化した状態で
   インストール〜文書取り込み〜検索までを通す**（§4 の限界を潰す）。
   同時に `ollama.exe serve` のアウトバウンドを確認する（§2-3）。
4. OCR 言語データ（`eng` / `jpn`, 約15MB）を同梱するかを別途判断する（§6 補足）。

---

## 8. 検証済み・未検証の区別

| 項目 | 状態 |
|---|---|
| `allowRemoteModels=false` で fetch が呼ばれないこと | ✅ **実測**（fetch フック、ケース1/2/4/5 すべて0件） |
| 対策前は実際に huggingface.co / cdn.anythingllm.com へ出ること | ✅ **実測**（ケース3、URL2件を記録） |
| 同梱モデルがあればオフラインでリランクが成立すること | ✅ **実測**（score 0.9286、189ms） |
| OCR が jsdelivr へ出ること（対策前） | ⚠️ **コード確認のみ**（`tesseract.js/src/worker-script/index.js:130`）。tesseract のワーカーは**子プロセス**で動くため親プロセスの fetch フックでは捕捉できず、実際に発火させるとCDNから本当にダウンロードしてしまうため実行していない |
| OCR が対策後にCDNへ出ないこと | ✅ **実測**（ケース4、0件。`langPath`/`gzip` がワーカーへ渡ることも `createWorker.js:114` で確認） |
| 配布物のパス解決が一致すること | ✅ **コード追跡**（§6）。Windows実機での確認は未実施 |
| Ollama 本体がネットワークへ出ないこと | ❌ **未検証（推測）**。§2-3 の根拠は状況証拠 |
| Windows 実機でのオフライン インストール〜起動 | ❌ **未実施**（`/mnt/c/LocalRAG/` に触らない制約のため） |
| eslint | ✅ 変更ファイルすべて PASS（`server/utils/boot/index.js` の1件は**変更前から存在**する prettier 指摘。`git show HEAD:` で確認済み） |

---

## 9. 作業ログ

| 日付 | 内容 | 担当 |
|---|---|---|
| 2026-07-28 | `@xenova/transformers` のオフライン挙動を実測。`HF_HUB_OFFLINE` がJS版に効かないことを確認。リランカー／OCR／Whisper／nativeエンベッダーの4経路を既定で遮断し、日本語エラー化。起動時チェックを追加。env テンプレートを更新 | Claude Code |

**制約遵守**: Docker 未操作、`/mnt/c/LocalRAG/` 未参照、`scripts/` `fixtures/` 未変更、
git commit / push なし。一時ファイルはスクラッチパッドのみ。
