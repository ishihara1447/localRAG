# Codex作業依頼: 設定メニュー整理版の Windows 配布物ビルドと実機検証

作成日: 2026-07-27
依頼元: Claude Code
依頼先: Codex
関連: `docs/CLAUDE_CODE_REQUEST_SETTINGS_MENU_IMPLEMENTATION_2026-07-27.md`（Codex作成の指示書）
実装報告: `docs/SETTINGS_MENU_IMPLEMENTATION_2026-07-27.md`（**先にこれを読むこと**）

---

## 1. 依頼内容

指示書 §5 Step 5 の分担どおり、**Windows の export・Setup.exe 再ビルド・クリーンインストール・実ブラウザ確認**を Codex 側で実施してほしい。

ソース側（frontend / server）の実装・lint・test・build は Claude Code 側で完了している。ただし **`git commit` / `push` はしていない**ので、作業ツリーの未コミット変更をそのままビルドするか、先にコミットするかは判断のうえ進めること。

---

## 2. 🔴 最重要の申し送り: export はビルドの古さを検出しない

`windows-native/export-windows.ps1` の L63-66 は次のようになっている。

```powershell
$publicDir = Join-Path $SourceDir "server\public"
if (-not ((Test-Path (Join-Path $publicDir "index.html")) -or (Test-Path (Join-Path $publicDir "_index.html")))) {
    Write-Host "ERROR: built frontend at server\public not found (expected index.html or _index.html)."
    Write-Host "       Build frontend and copy dist to server\public first."
```

**これは `server\public\index.html`（または `_index.html`）の存在を見ているだけで、そのビルドが古いかどうかを一切検出しない。**

2026-07-14 に発生した「**ソースにはサービス制御UIがあるのに、インストール済み配布物には入っていなかった**」事故の原因がこれである。古い `server\public` が残っていると、export は何のエラーも出さずに**古い frontend bundle を同梱したまま成功してしまう**。

### 必須手順

1. **frontend を build する**

   ```powershell
   cd anything-llm\frontend
   yarn build
   ```

   → `frontend\dist\` が生成される（postbuild で `index.html` は `_index.html` にリネームされる）。
   参考: Claude Code 側（WSL2）の実測ビルド結果は `✓ built in 30.84s` / `dist/index.js` = 2,802,078 bytes、`dist/_index.html` = 913 bytes。
   **この dist は WSL2 上のものなので流用せず、Windows 側で必ず build し直すこと。** サイズの桁が大きく違う場合は何かがおかしい。

2. **`server\public` を作り直す**

   ```powershell
   Remove-Item -Recurse -Force anything-llm\server\public   # 古い bundle を必ず消す
   Copy-Item -Recurse anything-llm\frontend\dist anything-llm\server\public
   ```

   **上書きコピーではなく、いったん削除すること。** 上書きだと古いハッシュ付きアセット（`assets\index-XXXXXXXX.js`）が残り、どれが現行か分からなくなる。

3. **🔴 タイムスタンプを確認する（省略禁止）**

   ```powershell
   Get-ChildItem anything-llm\server\public\_index.html, anything-llm\server\public\index.js |
     Select-Object FullName, Length, LastWriteTime
   ```

   `LastWriteTime` が **今回の build 時刻と一致していること**を目視確認する。ここが古ければ、この先の検証はすべて無意味になる。

4. その後に `export-windows.ps1` を実行する。

### 将来の恒久対策（任意・推奨）

`export-windows.ps1` に「`server\public\_index.html` の `LastWriteTime` が `frontend\src` 配下の最新更新時刻より古ければ警告または中断する」チェックを入れると、この事故は構造的に防げる。今回の作業範囲外だが検討してほしい。

---

## 3. 検証項目（指示書 §6 の受け入れ条件をそのまま転記）

> ソースだけで完了扱いにしないでください。Codex側のWindows検証で、次を確認します。

| # | 受け入れ条件 | 結果 |
|---|---|---|
| 1 | frontend build成果物がWindows exportに同梱されている | ☐ |
| 2 | 実際の `C:\LocalRAGProd\app\server\public\index.js` が更新されている | ☐ |
| 3 | 古いブラウザキャッシュを除去した状態でスパナメニューを開ける | ☐ |
| 4 | 顧客向け設定メニューがallowlistどおりである | ☐ |
| 5 | LLMはOllama、embeddingはOllama、Vector DBはLanceDBだけである | ☐ |
| 6 | Community Hub、Telegram、Chat Embed、Scheduled Jobs等が表示されない | ☐ |
| 7 | 資料取込、検索、出典付き回答が回帰していない | ☐ |
| 8 | API/env直接変更による外部provider選択が拒否される | ☐ |

> 以前、ソース側のサービス制御UIがインストール済みbundleに反映されていない事例がありました。同じ問題を繰り返さないため、bundleの更新確認を必須にします。

### 各項目の具体的な確認手順

**#2 について**: `C:\LocalRAGProd\app\server\public\` の `LastWriteTime` と、ビルド元 `anything-llm\server\public\` の `LastWriteTime` を突き合わせる。クリーンインストール後なのでインストール時刻になっているはず。

**#3 について**: ブラウザで `Ctrl+Shift+R`（スーパーリロード）、または開発者ツール > Application > Clear storage。`index.js` のハッシュ付きアセット名が変わっているので、キャッシュが残っていると旧UIが出る。

**#4 の期待値（実測済みのallowlist）**:

```text
表示される（11項目）:
  AIプロバイダー … LLM / 埋め込みエンジン / ベクターデータベース / テキスト分割とチャンク化
  管理           … ワークスペース / Default System Prompt
  カスタマイズ    … UI設定(Appearance) / チャット
  ツール         … イベントログ / APIキー
  セキュリティ

カテゴリごと消える:
  Agent Skills / Community Hub / チャンネル(Telegram) / Experimental Features

カテゴリは残るが子項目が消える:
  AIプロバイダー … 音声とスピーチ / 文字起こし / Model Router
  管理           … Users / Invites / ワークスペースチャット
  カスタマイズ    … ブランディング
  ツール         … Chat Embed / Scheduled Jobs / システムプロンプト変数 /
                   Browser Extension / Mobile App
```

**#5 について**: 設定 > LLM の一覧に **Ollama 1件のみ**、埋め込みエンジンの一覧に **Ollama 1件のみ**、ベクターDBの一覧に **LanceDB 1件のみ**が出ること。既存の設定値（`gemma4:12b` / `bge-m3:latest`）が保持されていること。

**#6 について**: サイドバーに出ないことに加え、**URLを直接入力しても機能画面が出ないこと**を確認してほしい。以下は日本語の案内画面（「この配布版では利用できません」）になるはず。

```text
http://127.0.0.1:3001/settings/agents
http://127.0.0.1:3001/settings/community-hub/trending
http://127.0.0.1:3001/settings/scheduled-jobs
http://127.0.0.1:3001/settings/external-connections/telegram
http://127.0.0.1:3001/settings/embed-chat-widgets
http://127.0.0.1:3001/settings/browser-extension
http://127.0.0.1:3001/settings/mobile-connections
http://127.0.0.1:3001/settings/beta-features
http://127.0.0.1:3001/settings/audio-preference
http://127.0.0.1:3001/settings/transcription-preference
http://127.0.0.1:3001/settings/model-routers
http://127.0.0.1:3001/settings/users
```

逆に、以下は**従来どおり開けること**（回帰確認）:

```text
http://127.0.0.1:3001/                                  ワークスペース一覧・チャット
http://127.0.0.1:3001/settings/llm-preference
http://127.0.0.1:3001/settings/embedding-preference
http://127.0.0.1:3001/settings/vector-database
http://127.0.0.1:3001/settings/text-splitter-preference
http://127.0.0.1:3001/settings/workspaces
http://127.0.0.1:3001/settings/default-system-prompt
http://127.0.0.1:3001/settings/interface
http://127.0.0.1:3001/settings/chat
http://127.0.0.1:3001/settings/event-logs
http://127.0.0.1:3001/settings/api-keys
http://127.0.0.1:3001/settings/security
http://127.0.0.1:3001/settings/privacy
```

**#7 について**: 資料取込（PDF投入）→ 検索 → 出典付き回答まで通す。`windows-native\rag-e2e-test.ps1` があるので活用できる。本作業は RAG 経路（検索・生成・collector）に一切触れていないため、回帰は想定していないが、bundle 差し替えの影響確認として必要。

**#8 について**: 以下がすべて拒否されることを確認してほしい。

```powershell
# (a) API経由で外部providerを保存しようとする → error が返るはず
Invoke-RestMethod -Uri "http://127.0.0.1:3001/api/system/update-env" -Method POST `
  -Headers @{Authorization="Bearer <APIキー>"} -ContentType "application/json" `
  -Body '{"LLMProvider":"openai"}'
# → "openai is not a permitted LLM provider in this build..." 相当

Invoke-RestMethod ... -Body '{"LLMProvider":"generic-openai"}'      # → 拒否
Invoke-RestMethod ... -Body '{"EmbeddingEngine":"native"}'          # → 拒否
Invoke-RestMethod ... -Body '{"EmbeddingEngine":"openai"}'          # → 拒否
Invoke-RestMethod ... -Body '{"VectorDB":"pinecone"}'               # → 拒否
```

```text
# (b) env直接編集 → サービス起動時に赤いエラーで停止するはず
server\.env の LLM_PROVIDER を generic-openai に変えて再起動
  → [HARDENING] LLM provider "generic-openai" is not permitted in this build. ...
  ※確認後は必ず ollama に戻すこと
```

```text
# (c) 例外扱い: EMBEDDING_ENGINE=native だけは「起動を通して警告を出す」設計
server\.env の EMBEDDING_ENGINE を native に変えて再起動
  → 黄色の警告ログが出るが、起動はする（意図した動作）
     "[HARDENING] Embedding engine "native" is a legacy value that is no longer
      selectable in this build. Please switch to "ollama" (bge-m3:latest)..."
  → 設定画面から Ollama に戻せることを確認
  ※確認後は必ず ollama に戻すこと
```

**(c) を「バグ」と判断しないでほしい。** 2026-07-26以前のP0バグで `EMBEDDING_ENGINE=native` が書き込まれた既存顧客環境が、更新後に設定画面にすら到達できず復旧不能になるのを避けるための意図的な設計。詳細は実装報告 §2.2。

---

## 4. 手動確認（指示書 §7 より）

- ☐ 初回オンボーディング完了後に embedding が `native` へ変わらない（**クリーンインストール直後に必ず確認**。これが2026-07-26のP0バグの再発チェック）
- ☐ 既存embeddingとベクトルデータが設定表示だけで消えない
- ☐ スパナメニューが顧客向けallowlistどおりに表示される（§3 #4）
- ☐ 非対応URLへ直接移動しても拒否される（§3 #6）
- ☐ 外部通信なしでコア機能が利用できる（ネットワーク遮断状態で資料取込→検索→回答）

---

## 5. Claude Code 側で実施済みのこと（再実施不要）

| 項目 | 結果 |
|---|---|
| frontend lint | PASS（変更6ファイルはエラー0。残る6ファイルのprettierエラーは未変更の上流ファイルで作業前から存在） |
| frontend test | N/A（このリポジトリに frontend テストランナーが存在しない） |
| frontend build | PASS（`✓ built in 31.14s`） |
| server lint | PASS（変更3ファイルはエラー0。残る11エラーは `lance/index.js`＝別作業の未コミット変更 と `lance/sentenceCushion.js`＝既存） |
| server test | 243 passed / 5 failed。失敗5件は**作業前と同一**（lance hybridSearch 2件＝FTSテーブル名の版数ずれ、ffmpeg 3件＝バイナリ不在）。新規追加テスト39件は全PASS |
| `git diff --check` | PASS |

---

## 6. 申し送り: 本作業で発見した未解決のギャップ

### 6.1 🔴 TTS / STT プロバイダーがサーバー側で allowlist 化されていない

`server/utils/helpers/updateENV.js` の `supportedTTSProvider` / `supportedSTTProvider` は製品プロファイル（`ALLOWED_*`）を参照しておらず、以下を**保存できてしまう**。

```text
TTS: native, openai, elevenlabs, piper_local, generic-openai, kokoro
STT: native, openai, lemonade, deepgram, groq, generic-openai
```

つまり **API/env を直接編集すれば OpenAI / ElevenLabs / Deepgram / Groq へ音声データを送る設定が保存できる**。今回は UI 非表示と URL guard までを実施し、サーバー側の allowlist 化は**指示書のスコープ外だったため未実施**。

対応方針の判断が必要:

- (a) `productProfile.js` に `ALLOWED_TTS_PROVIDERS` / `ALLOWED_STT_PROVIDERS` を追加し `native` のみ許可
- (b) 音声機能そのものを配布版で無効化する

**#8 の検証時に、TTS/STT については「まだ塞がっていない」ことを前提としてほしい**（拒否されなくても本作業のバグではない）。

### 6.2 フロントエンドの URL guard は API 直叩きを塞がない

`/settings/agents` などを URL guard で塞いだのは**画面到達の防止**であり、対応する API を直接叩けば設定は変更できる。サーバー側で確実に無効なのは以下のみ（実測確認済み）。

- Community Hub バンドルDL（`COMMUNITY_HUB_BUNDLE_DOWNLOADS_ENABLED` 未設定 → 422）
- Filesystem / Create Files Agent（`ANYTHING_LLM_RUNTIME !== "docker"` → 利用不可）
- Agent Tool の自動承認（`AGENT_AUTO_APPROVED_SKILLS` 未設定 → 常に false）
- エージェント既定スキル（`DEFAULT_SKILLS = [memory]` のみ。Web scraping/browsing は含まれない）

### 6.3 ワークスペース単位の Agent Configuration タブは残置

`/workspace/:slug/settings/agent-config` は隠していない。指示書 §4.4 は「Agent Skills の**設定メニュー**を非表示」と書いており、設定サイドバーを対象と解釈したため。隠すべきかは製品判断。

---

## 7. 完了報告のお願い

検証結果は `docs/` 配下に記録してほしい（例: `docs/WINDOWS_BUILD_SETTINGS_MENU_RESULT_2026-07-XX.md`）。特に以下を実測値で残してほしい。

- ビルドした frontend bundle のタイムスタンプとファイルサイズ
- `C:\LocalRAGProd\app\server\public\` の実際の更新時刻
- §3 の受け入れ条件8項目の結果
- §4 の手動確認5項目の結果
- 回帰の有無（RAG E2E の結果）
