# OTE-RAG 設定メニューの顧客向け整理 — 実装報告

実施日: 2026-07-27
実施: Claude Code
指示書: `docs/CLAUDE_CODE_REQUEST_SETTINGS_MENU_IMPLEMENTATION_2026-07-27.md`（Codex作成）
対象fork: `anything-llm/`（コミットせず、作業ツリーに残している）

---

## 0. 実装結果サマリー

```text
## 実装結果
- Step 1 許可値の厳密化:            PASS（製品ポリシー部分はユーザー承認済み。§2.3）
- Step 2 SettingsSidebar整理:      PASS
- Step 3 直接URL guard:            PASS（必要性を独自検証。§4 に根拠）
- Step 4 Agent/Community/外部機能:  PARTIAL（§5 で新規のギャップを1件発見）
- Windows配布物反映:               Claude Code対象外（Codexへ引き継ぎ）
```

**git commit / push は行っていない。** dev環境（localhost:3001）は設定変更しておらず、稼働継続（`/api/ping` = 200 を実測）。

---

## 1. 🔴 最初に読むこと: Codex指示書の妥当性検証

指示書を鵜呑みにせず、主張が事実か・判断の性質が何かを確認した。

### 1.1 事実確認できた主張

| 指示書の主張 | 検証方法 | 結果 |
|---|---|---|
| §3.1 「設定サイドバーが未整理」 | `SettingsSidebar/index.jsx` と `MenuOption/index.jsx` を実読 | **正しい。** 上流の `flex: true` は「単一ユーザーなら誰でも見える」意味であり（`MenuOption/index.jsx` の `if (flex && !!user && ...)` は user が null だと素通り）、単一ユーザー運用の配布版では Community Hub / Telegram / Scheduled Jobs / Browser Extension / Mobile App / Agent Skills / Model Router が全て表示される状態だった |
| §3.2 「許可リストが実際のWindows同梱構成より広い」 | `windows-native/config/server.env.template` を実読 | **正しい。** 配布 env は `LLM_PROVIDER=ollama` / `EMBEDDING_ENGINE=ollama` / `EMBEDDING_MODEL_PREF=bge-m3:latest` / `VECTOR_DB=lancedb` のみ。許可リストの `localai` 等は同梱実体がない |
| §6「export が古いbundleを検出しない」 | `windows-native/export-windows.ps1` L63-66 を実読 | **正しい。** `Test-Path server\public\index.html` の**存在確認のみ**で、タイムスタンプ・内容の新しさは一切見ていない |

### 1.2 指示書が区別していなかった論点（重要）

指示書 §4.1 は「許可値を `ollama` だけに絞れ」と一括で指示しているが、**除外対象には性質の異なる2種類が混在している**。

| 除外対象 | 性質 | 判定 |
|---|---|---|
| `generic-openai` | 接続先URLが任意。社内サーバーにもOpenAIにも向けられる。「顧客文書を外部送信しない」という製品の中核的な約束と直接矛盾 | **安全性の修正。除外は正当** |
| `native`（embedding） | 未同梱。初回利用時にHugging Faceから取得するため完全オフライン動作が未検証。2026-07-26のP0バグ（オンボーディング完了だけで `EmbeddingEngine="native"` が送信され顧客の埋め込みが壊れた）と同じ穴 | **安全性の修正。除外は正当** |
| `localai` / `lmstudio` / `litellm` / `lemonade` / `koboldcpp` / `textgenwebui` / `docker-model-runner` / `privatemode` | いずれもローカル/自己ホスト型で、それ自体は外部送信しない。動かないのは「同梱していない」から | **製品ポリシーの変更 → ユーザー承認済み（2026-07-27「隠しましょう」）**（§2.3参照） |

この区別は 2026-07-26 の仕分け（`docs/CODEX_REQUEST_TRIAGE_2026-07-26.md`）で既に「(b) 後回し／既存方針を勝手に狭めない」と分類していた論点であり、Codex指示書はこれを区別せずに一括指示していた。

**対応**: Claude Code側が「安全性の修正」と「製品ポリシーの変更」が混在していることを指摘し、後者についてユーザー判断を仰いだ。**2026-07-27に「隠しましょう」との承認**を得たため、実装は指示書どおり `ollama` のみに絞った。ただし**承認が下りたことと除外理由が違うことは別問題**なので、**コード上で2種類を別々の定数として明示的に分離**し、戻す手順を記載している（§2.1）。経緯は §10 の意思決定ログを参照。

### 1.3 指示書の記述が実態と違っていた点

`litellm` を指示書は「ローカル系」に含めているが、LiteLLM は**任意のバックエンドへ中継するプロキシ**であり、設定次第でクラウドへ転送され得る。`generic-openai` と同じリスク特性を持つ。分類上は「未同梱」側に置いたが、**戻す場合は generic-openai と同等の注意が必要**である旨をコードコメントに明記した。

---

## 2. Step 1: 許可値をWindows同梱構成へ合わせる

### 2.1 除外理由を2分類に分離（コード構造）

`frontend/src/utils/productProfile.js` と `server/utils/helpers/productProfile.js` の両方に、同じ分類でコメントと定数を置いた。

```text
(A) EXCLUDED_FOR_SAFETY_*   — 安全性のため恒久的に除外。戻さない
    LLM       : generic-openai
    Embedding : native, generic-openai

(B) NOT_BUNDLED_*           — 未同梱のため現時点で不許可。ユーザー承認で戻せる
    LLM       : localai, lmstudio, koboldcpp, textgenwebui, litellm,
                docker-model-runner, privatemode, lemonade
    Embedding : localai, lmstudio, litellm, lemonade

→ 結果としての許可値
    ALLOWED_LLM_PROVIDERS       = { ollama }
    ALLOWED_EMBEDDING_ENGINES   = { ollama }
    ALLOWED_VECTOR_DBS          = { lancedb }
```

**(A) と (B) を混同しないこと。(A) は同梱しても戻さない。**

**(B) を戻す手順**（将来これらを同梱・検証した場合）:

1. `server/utils/helpers/productProfile.js` の `ALLOWED_LLM_PROVIDERS`（または `ALLOWED_EMBEDDING_ENGINES`）に値を追加
2. `frontend/src/utils/productProfile.js` の `DISTRIBUTABLE_LLM_PROVIDER_VALUES`（または `DISTRIBUTABLE_EMBEDDING_ENGINE_VALUES`）に**同じ値**を追加（2箇所必須）
3. frontend を再build して `server/public` へ反映

上流(AnythingLLM)の provider 定義・実装は**一切削除していない**ので、上記2行の追加だけで復活する。テスト `server/__tests__/utils/helpers/productProfile.test.js` に、(A) と (B) が交わらないこと・(A) が絶対に許可値へ入らないことを検証するケースを追加済み。

### 2.2 `native` の扱い（既存顧客のブリック回避）

`native` を単純に起動時エラーにすると、**2026-07-26以前のP0バグで `EMBEDDING_ENGINE=native` が書き込まれた既存顧客環境が、更新後に設定画面にすら到達できず復旧不能になる**。

そこで以下の非対称な扱いにした。

- **保存（`updateENV` の validator）**: `native` を拒否 → UIからもAPIからも二度と `native` にできない
- **起動（`getEmbeddingEngineSelection`）**: `LEGACY_TOLERATED_EMBEDDING_ENGINES` として**起動は通すが黄色い警告ログを出す** → 顧客は設定画面からOllamaへ戻せる

外部送信の可能性がある `generic-openai` 等は、この許容リストに入れていない（起動時エラーのまま）。

### 2.3 製品ポリシーの判断（ユーザー承認済み・2026-07-27）

**以下は安全性の修正ではなく製品ポリシーの決定であり、Claude Code が判断の性質を明示してユーザーに諮り、承認を得たうえで実施した。**

> **LLM / embedding の許可値から `localai` / `lmstudio` / `litellm` / `lemonade` / `koboldcpp` / `textgenwebui` / `docker-model-runner` / `privatemode` を外した。**
> これは「LM Studio や LocalAI を自分で立てている利用者を対象顧客から外す」という判断に相当する。
> **ユーザー判断: 「隠しましょう」（2026-07-27）** → 承認済み。
> 承認の理由づけは「現状の配布形態（Setup.exe 一発でOllama同梱）で同梱していないものを見せない」であり、
> **安全性の問題があるからではない**。将来これらを同梱・検証すれば戻せる。手順は §2.1 の2行追加のみ。

同様に**モデルルーター（`anythingllm-router`）の無効化**も、「配布物が gemma4:12b 単一モデルのためルーティング先が存在しない」という事実に基づく製品判断。複数モデル同梱に方針変更する場合は `MODEL_ROUTER_ENABLED = true` に戻す。

なお `generic-openai`（LLM・embedding）と `native`（embedding）の除外は**これとは別の「安全性の修正」**であり、同梱状況やユーザーの好みに関わらず戻さない。コード上も別定数（`EXCLUDED_FOR_SAFETY_*`）に分離してある。

### 2.4 既定値が壊れていないことの確認（実測）

```text
$ node -e "...require('./utils/helpers/productProfile')"
LLM allowed: [ 'ollama' ]
EMB allowed: [ 'ollama' ]
VDB allowed: [ 'lancedb' ]
legacy emb: [ 'native' ]
defaults: {
  LLM_PROVIDER: 'ollama',
  LLM_MODEL: 'gemma4:12b',
  EMBEDDING_ENGINE: 'ollama',
  EMBEDDING_MODEL: 'bge-m3:latest',
  VECTOR_DB: 'lancedb'
}
```

`windows-native/config/server.env.template` は**変更していない**（`gemma4:12b` / `bge-m3:latest` / `lancedb` はそのまま）。

### 2.5 `native` へ戻る経路を塞いだ箇所

指示書 §7「初回オンボーディング完了後にembeddingが `native` へ変わらない」に対応し、UI側のフォールバック既定値も潰した。

| 箇所 | 変更前 | 変更後 |
|---|---|---|
| `OnboardingFlow/Steps/LLMPreference/index.jsx` | `settings?.EmbeddingEngine \|\| "native"` | `settings?.EmbeddingEngine \|\| DEFAULT_EMBEDDING_ENGINE`（= `"ollama"`） |
| `GeneralSettings/EmbeddingPreference/index.jsx` | `_settings?.EmbeddingEngine \|\| "native"` | 同上 |

これで「設定未保存の状態でオンボーディングを完了する」経路からも `native` が送信されない。仮に送信されてもサーバー側 validator が拒否する（二重防御）。

---

## 3. Step 2: SettingsSidebar の表示allowlist

### 3.1 実装方式

上流の項目定義は削除せず、`frontend/src/utils/productProfile.js` に `CUSTOMER_SETTINGS_FEATURES`（機能キー → boolean）を追加し、`SettingsSidebar/index.jsx` の各項目に `hidden: hideUnless("<key>")` を付けた。

`MenuOption/index.jsx` は**変更不要**だった。既に

- `if (hidden) return null;`（親・子の両方に効く）
- `if (hasChildren && !hasVisibleChildren) return null;`（子が全部消えた親カテゴリも消える）

を備えていたため、`hidden` を渡すだけで指示書 §5 Step 2 の確認項目「非対応の子項目がすべて消えた親カテゴリも消える」を満たす。

### 3.2 結果（実測）

```text
$ node --input-type=module -e "import('.../productProfile.js') ..."
ENABLED : llm, embedder, vectorDatabase, textSplitting, workspaces,
          defaultSystemPrompt, interface, chat, eventLogs, apiKeys, security
DISABLED: transcription, voiceSpeech, modelRouter, users, invites, workspaceChats,
          branding, systemPromptVariables, embedChatWidgets, scheduledJobs,
          browserExtension, mobileApp, agentSkills, communityHub, telegram,
          experimentalFeatures
```

指示書 §4.2 のallowlistとの照合:

| 指示書の分類 | 項目 | 実装 |
|---|---|---|
| 表示する | LLM / 埋め込みエンジン / ベクターDB / テキスト分割 | ✅ 表示 |
| 表示する | ワークスペース / 既定のシステムプロンプト | ✅ 表示 |
| 表示する | UI設定 / チャット | ✅ 表示 |
| 表示する | イベントログ / APIキー | ✅ 表示 |
| 表示する | セキュリティ | ✅ 表示（上流の「多要素時は非表示」ロジックは温存） |
| 条件確認後 | 文字起こし / 音声とスピーチ / システムプロンプト変数 / ワークスペースチャット | ✅ 非表示 |
| 非表示 | Model Router / Users / Invites / Agent Skills / Community Hub / Telegram / Chat Embed / Scheduled Jobs / Browser Extension / Mobile App / Experimental Features | ✅ 全て非表示 |

指示書に列挙のない `ブランディング` は、§4.2 の「カスタマイズ = UI設定・チャット」に含まれないため非表示にした（白ラベル設定は配布元の管理範囲との判断。戻すのは `branding: true` の1行）。

親カテゴリのうち **「Community Hub」「チャンネル(Telegram)」「Agent Skills」「Experimental Features」はカテゴリごと消える**。「管理」「ツール」「カスタマイズ」「AIプロバイダー」は残った子項目とともに表示される。

**上流の定義は1つも削除していない。**

---

## 4. Step 3: 直接URLのguard — 必要性の独自検証

### 4.1 「バックエンドが既に拒否しているから不要」ではないことの確認

サーバー側の製品プロファイルが守っているのは **LLM / embedding / VectorDB の3つだけ**。それ以外の非対応画面は、URLを直接開けば**完全に機能する**。実測で確認した具体例:

| 画面 | URL直打ちで何ができてしまうか | バックエンド拒否 |
|---|---|---|
| `/settings/audio-preference` | **TTSプロバイダーに `openai` / `elevenlabs` / `generic-openai` を保存できる**（`supportedTTSProvider` の許可値に含まれている） | **なし** |
| `/settings/transcription-preference` | **STTプロバイダーに `openai` / `deepgram` / `groq` を保存できる**（`supportedSTTProvider` の許可値） | **なし** |
| `/settings/agents` | Web scraping / SQL Agent / MCP 等のエージェントスキルを有効化できる | 一部のみ（§5参照） |
| `/settings/community-hub/*` | Hub アカウント連携・インポート画面が開ける | ダウンロードのみ拒否 |
| `/settings/scheduled-jobs` | 定期実行ジョブを作成できる | なし |

**したがって Step 3 は「多層防御の飾り」ではなく、実際に塞がっていない設定経路を塞ぐもの。過剰実装ではないと判断し、実装した。**

特に **TTS/STT の外部プロバイダー保存はサーバー側で一切拒否されていない**（§5.2 の新規発見）。この画面をUIから隠すだけでは不十分だが、少なくともURL guard がないと「隠したつもりで開ける」状態になる。

### 4.2 実装方式

`frontend/src/components/PrivateRoute/index.jsx` に集約した。`main.jsx` のルート定義は**1行も変更していない**。

理由: 全ての `/settings/*` ルートは `AdminRoute` / `ManagerRoute` / `SingleUserRoute` / `PrivateRoute` のいずれかを経由する。guard をこの4つに入れれば、**ルート追加時に guard を付け忘れる事故が構造的に起きない**。main.jsx の各エントリに個別ラッパーを足す方式だと付け忘れが起きる。

判定は `findRestrictedSettingsRoute(pathname)`（productProfile.js、サイドバーと同じ表を参照）。該当時は上流コンポーネントの代わりに日本語の案内画面 `FeatureUnavailableNotice` を描画する。

`<Navigate>` による無言リダイレクトにしなかったのは、指示書 §4.3 が「日本語で理由を表示」を求めているため。顧客が「壊れている」と誤解せず、サポート問い合わせ時に状況を説明できる。

表示文言:
> **この配布版では利用できません**
> お探しの設定画面は、本製品（OTE-RAG Windows版）には含まれていません。本製品はお使いのパソコンの中だけで動作し、インターネット上のサービスへ文書を送信しない構成にしているため、外部連携や未同梱の機能に関する設定画面は無効にしています。
> ご利用可能な設定は、左側のメニューに表示されている項目のみです。
> ［設定画面へ戻る］［ホームへ戻る］

### 4.3 guard の実測結果

```text
BLOCKED  /settings/agents
BLOCKED  /settings/agents/builder/abc     ← 前方一致で子ルートも塞ぐ
BLOCKED  /settings/community-hub/trending
BLOCKED  /settings/scheduled-jobs/1/runs
BLOCKED  /settings/external-connections/telegram
BLOCKED  /settings/beta-features
BLOCKED  /settings/audio-preference
BLOCKED  /settings/model-routers/3
BLOCKED  /settings/users
allowed  /settings/llm-preference
allowed  /settings/workspaces
allowed  /settings/security
allowed  /settings/event-logs
allowed  /settings/api-keys
allowed  /settings/embedding-preference
allowed  /settings/text-splitter-preference
allowed  /settings/vector-database
allowed  /settings/default-system-prompt
allowed  /settings/interface
allowed  /settings/chat
allowed  /settings/privacy
allowed  /workspace/foo                   ← ワークスペース・チャットは回帰なし
allowed  /
```

**回帰なし**: ワークスペース、資料取込（workspace配下）、チャット、必要な管理画面（LLM/embedder/VectorDB/チャンク/ワークスペース/既定プロンプト/UI/チャット/イベントログ/APIキー/セキュリティ/プライバシー）はすべて `allowed`。

### 4.4 guard の限界（正直な記載）

**これはフロントエンドの guard であり、API を直接叩く経路は塞がない。** `curl` で `/api/system/update-env` に `SpeechToTextProvider: "openai"` を送れば、現状は保存できてしまう（§5.2）。真の防御はサーバー側にあるべきで、これは未達項目である。

---

## 5. Step 4: Agent / Community Hub / 外部機能のバックエンド確認

新規実装ではなく**実測による確認**を行った。

### 5.1 確認できた（既存の無効化が残っている）

| 項目 | 確認方法 | 結果 |
|---|---|---|
| エージェント既定スキル | `server/utils/agents/defaults.js` L15 | `DEFAULT_SKILLS = [AgentPlugins.memory.name]` のみ。**Web scraping / Web browsing は既定に含まれない** ✅ |
| Filesystem / Create Files Agent | `plugins/filesystem/lib.js` の `isToolAvailable()` | `NODE_ENV=development` 以外では `ANYTHING_LLM_RUNTIME === "docker"` を要求。Windows配布 env は `NODE_ENV=production` かつ `ANYTHING_LLM_RUNTIME` **未設定** → **利用不可** ✅ |
| Community Hub バンドルDL | `utils/middleware/communityHubDownloadsEnabled.js` | `COMMUNITY_HUB_BUNDLE_DOWNLOADS_ENABLED` が env に**無い**場合は 422 で拒否。配布 env テンプレートに未設定 → **既定無効を維持** ✅ |
| Scheduled Jobs の Agent Tool 自動承認 | `utils/helpers/agents.js` L12 | `AGENT_AUTO_APPROVED_SKILLS` が env に無ければ常に false。配布 env に未設定 → **自動承認されない** ✅ |
| Telemetry / Swagger | `server.env.template` L57-58 | `DISABLE_TELEMETRY=true` / `DISABLE_SWAGGER_DOCS=true` ✅ |
| 埋め込みモデルのオフライン強制 | `server.env.template` L63 | `HF_HUB_OFFLINE=1` ✅（= `native` embedder が事実上動かない裏付けでもある） |

### 5.2 🔴 新規発見のギャップ（未達）

**TTS / STT プロバイダーはサーバー側で外部送信を拒否していない。**

```js
// server/utils/helpers/updateENV.js
function supportedTTSProvider(input = "") {
  const validSelection = ["native","openai","elevenlabs","piper_local",
                          "generic-openai","kokoro"].includes(input);
  ...
}
function supportedSTTProvider(input = "") {   // ※関数名は supportedSTTProvider 系
  const validSelection = ["native","openai","lemonade","deepgram","groq",
                          "generic-openai"].includes(input);
  ...
}
```

`TextToSpeechProvider` / `SpeechToTextProvider` の `checks` はこの関数のみで、**製品プロファイル（`ALLOWED_*`）を参照していない**。つまり API/env を直接編集すれば OpenAI / ElevenLabs / Deepgram / Groq へ音声データを送る設定を保存できる。

- 本作業では**UIの非表示とURL guard までを実施**（音声・文字起こしメニューは非表示、URLも塞いだ）
- **サーバー側の allowlist 化は未実施**。指示書 §4.1 の許可範囲表には TTS/STT の記載がなく、スコープに含まれていなかったため、勝手に方針を決めず**次アクションとして提起**する
- 推奨: `productProfile.js` に `ALLOWED_TTS_PROVIDERS` / `ALLOWED_STT_PROVIDERS` を追加し、同梱・検証が済むまで `native` のみ、または「音声機能そのものを配布版で無効」とする

### 5.3 確認したが本作業では手を付けていない点

- **ワークスペース設定内の「Agent Configuration」タブ**（`/workspace/:slug/settings/agent-config`）は残っている。指示書 §4.4 は「Agent Skillsの**設定メニュー**を非表示」と書いており、対象を設定サイドバーと解釈した。ワークスペース単位のエージェント設定を隠すかは製品判断が必要
- **任意MCPサーバー**: 設定UIは Agent Skills 画面配下のため非表示・guard済み。MCP設定ファイルが存在しなければサーバーは何も読み込まない（配布物に同梱なし）

---

## 6. Step 5: テスト結果（すべて実測）

### 6.1 変更ファイル一覧

**フロントエンド**

| ファイル | 内容 |
|---|---|
| `frontend/src/utils/productProfile.js` | (A)(B)分類の定数追加、許可値を ollama/ollama/lancedb へ、`MODEL_ROUTER_ENABLED`、既定値定数、`CUSTOMER_SETTINGS_FEATURES`、`RESTRICTED_SETTINGS_ROUTES`、`findRestrictedSettingsRoute()` |
| `frontend/src/components/SettingsSidebar/index.jsx` | `hideUnless()` ヘルパー追加、全メニュー項目に `hidden` を付与 |
| `frontend/src/components/PrivateRoute/index.jsx` | `useRestrictedFeature()` / `FeatureUnavailableNotice` 追加、4つのRouteコンポーネントに guard を適用 |
| `frontend/src/pages/GeneralSettings/LLMPreference/index.jsx` | `DISTRIBUTABLE_ALL_LLM_PROVIDERS` からモデルルーターを条件付き除外 |
| `frontend/src/pages/GeneralSettings/EmbeddingPreference/index.jsx` | 表示既定値のフォールバックを `native` → `ollama` |
| `frontend/src/pages/OnboardingFlow/Steps/LLMPreference/index.jsx` | 送信値のフォールバックを `native` → `ollama` |

**サーバー**

| ファイル | 内容 |
|---|---|
| `server/utils/helpers/productProfile.js` | (A)(B)分類、許可値の厳格化、`LEGACY_TOLERATED_EMBEDDING_ENGINES`、`PRODUCT_DEFAULTS` |
| `server/utils/helpers/index.js` | `getEmbeddingEngineSelection()` に legacy `native` の警告付き通過を追加 |
| `server/utils/helpers/updateENV.js` | validator 3つ（`supportedLLM` / `supportedEmbeddingModel` / `supportedVectorDB`）をテスト用に export（ロジック変更なし） |
| `server/__tests__/utils/helpers/productProfile.test.js` | **新規**。39ケース |

**触っていないファイル（他作業のため厳守した）**: `collector/processSingleFile/convert/asPDF/PDFLoader/index.js`、`server/utils/vectorDbProviders/lance/index.js`、`scripts/complex-eval.py`、`scripts/_eval_common.py`。`git status` で未変更のまま残っていることを確認済み。

### 6.2 テスト結果

| 項目 | 結果 |
|---|---|
| **frontend lint** | **PASS**（変更6ファイルは `npx eslint` でエラー0）。リポジトリ全体では6ファイルにprettierエラーが残るが、**すべて未変更の上流ファイル**（`EmbeddingSelection/GenericOpenAiOptions`, `Footer`, `LLMSelection/OllamaLLMOptions`, `locales/en/common.js`, `Admin/ExperimentalFeatures` ×2）で**本作業の前から存在** |
| **frontend test** | **N/A**。このリポジトリに frontend 用テストランナーは存在しない（`frontend/package.json` に `test` スクリプトなし、jsdom/babel設定なし）。代替として productProfile のロジックを node で直接実行し実測（§3.2・§4.3） |
| **frontend build** | **PASS**。`yarn build` → `✓ built in 31.14s` / `dist/index.js` 2,514.19 kB (gzip 807.48 kB)。postbuild で `index.html` → `_index.html` へリネーム済み |
| **server lint** | **PASS**（変更3ファイルはエラー0）。全体では11エラーが残るが、`lance/index.js`（**別作業の未コミット変更**）と `lance/sentenceCushion.js`（未変更・既存）のみ |
| **server test（`npx jest`）** | 26 suites / 248 tests。**243 passed, 5 failed**。失敗の内訳は下記のとおり**すべて本作業前から存在** |
| **`git diff --check`** | **PASS**（exit 0、空白エラーなし） |
| **RAG E2E** | **未実施**。製品コードのRAG経路（検索・生成・collector）に一切触れていないため。Windows実機での回帰確認はCodex側へ引き継ぎ（§7） |

**テスト失敗5件の内訳（本作業前と同一）**

| 失敗 | 原因 | 本作業との関係 |
|---|---|---|
| `lance/hybridSearch.test.js` › uses a reserved sidecar table name | FTSテーブル名の版数ずれ（既知） | 無関係（事前に同じ失敗を実測） |
| `lance/index.test.js` › fuses BM25 with dense results... | 同上 | 無関係 |
| `WhisperProviders/ffmpeg` × 3 | 実行環境に ffmpeg バイナリが無い | 無関係（環境要因） |

**新たな失敗は増えていない。** 本作業前のベースラインは `204 passed, 5 failed`、作業後は `243 passed, 5 failed`（+39は新規追加テスト）。

### 6.3 追加したテスト（指示書 §7「必須テスト」への対応）

`server/__tests__/utils/helpers/productProfile.test.js`（39ケース、全PASS）

- productProfile の許可値テスト（ollama / ollama / lancedb に固定）
- **(A)安全性除外と(B)未同梱除外が交わらないこと**、(A)が絶対に許可値に入らないこと
- `updateENV` の validator が不許可 LLM 9種 / embedding 10種 / VectorDB 6種を拒否すること
- 起動時 guard: 不許可の VectorDB / LLM / embedding が env 経由でも throw すること
- legacy `native` は throw せず警告のみで起動すること（既存顧客のブリック回避の回帰テスト）

未対応: 「SettingsSidebarの単一ユーザー表示テスト」「非対応ルートのguardテスト」は**自動テスト未作成**（frontend テストランナーが無いため）。ロジック部分は node 実行で実測済み（§3.2・§4.3）だが、Reactコンポーネントとしての描画テストは未達。

---

## 7. 指示書の項目別 達成状況

| 指示書の項目 | 状態 |
|---|---|
| §4.1 製品プロファイルをWindows顧客版に固定 | ✅ 達成（ただし §2.3 のユーザー承認待ち事項あり） |
| §4.1 上流の定義を削除しない | ✅ 達成（provider定義・ルート・コンポーネントすべて温存） |
| §4.1 `native` を未検証のまま許可値に残さない | ✅ 達成（保存不可。起動のみ警告付き許容、理由は §2.2） |
| §4.2 サイドバーallowlist | ✅ 達成（§3.2 で照合） |
| §4.3 直接URLでも迂回できない | 🟡 **フロントエンドは達成**。API直叩きは未達（§4.4・§5.2） |
| §4.4 Agent Skills を顧客向けに非表示 | ✅ 達成（メニュー非表示＋URL guard）。Docker前提の Filesystem/Create Files が利用不可であることも実測確認 |
| §4.4 Web scraping/browsing を既定有効にしない | ✅ 確認済み（`DEFAULT_SKILLS` は memory のみ） |
| §4.4 Gmail / Calendar / Outlook 非表示 | ✅ Agent Skills画面ごと非表示 |
| §4.4 Scheduled Jobs が Agent Tool を自動承認しない | ✅ 確認済み（`AGENT_AUTO_APPROVED_SKILLS` 未設定） |
| §4.5 Community Hub のDL無効化を解除しない | ✅ 確認済み（middleware・env とも変更なし） |
| §5 Step1〜Step5 | ✅ 全ステップ実施 |
| §6 Windows配布物の受け入れ条件 | ⏭ Codexへ引き継ぎ（`docs/CODEX_REQUEST_WINDOWS_BUILD_SETTINGS_MENU_2026-07-27.md`） |
| §7 必須テスト | 🟡 サーバー側は達成。frontend のコンポーネントテストは未達（ランナー不在） |
| §8 やってはいけないこと | ✅ 全て遵守（定義の一括削除なし / コミット・プッシュなし / 他作業の未コミット変更に触れず） |

---

## 8. 未解決事項

1. **🔴 TTS/STT のサーバー側 allowlist が未実装**（§5.2）。API/env 直接編集で OpenAI / ElevenLabs / Deepgram / Groq へ音声を送る設定が保存できる。指示書のスコープ外だったため未実施、次アクションとして提起
2. **フロントエンドのURL guard はAPI直叩きを塞がない**（§4.4）。UIから隠した機能のうち、サーバー側でも無効なのは Community Hub DL / Docker専用Agent / Agent自動承認のみ
3. **frontend のコンポーネントテストが書けない**（テストランナー不在）。導入するかは別途判断
4. **音声・文字起こしの「条件確認」自体は未実施**。Whisper同梱・ネットワーク遮断下の動作・ブラウザSpeechRecognitionの外部依存・ローカルTTS同梱は未検証のまま。現状は非表示で正しい
5. **ワークスペース単位のAgent Configurationタブは残置**（§5.3）
6. **Windows配布物への反映は未実施**（Claude Code対象外）

---

## 9. Codexへの引き継ぎ

`docs/CODEX_REQUEST_WINDOWS_BUILD_SETTINGS_MENU_2026-07-27.md` を作成した。要点:

- frontend を build して `server\public` へコピーした**後**、**タイムスタンプ確認が必須**。`export-windows.ps1` L63-66 は `server\public\index.html` の**存在しか見ておらず、ビルドが古いかを検出しない**（2026-07-14の「ソースにはあるのに配布物に入っていなかった」事故の原因）
- 指示書 §6 の受け入れ条件8項目をそのまま検証項目として転記済み
- 本作業で発見した TTS/STT のギャップ（§5.2）も申し送り済み

---

## 10. 意思決定ログ

マルチエージェント運用のため、**どの主体がどの判断をしたか**を残す。

| 日付 | 判断・出来事 | 主体 | 内容 |
|---|---|---|---|
| 2026-07-26 | 仕分け | **Claude Code** | `docs/CODEX_REQUEST_TRIAGE_2026-07-26.md` で「LLMをOllamaだけに絞る」を **(b) 後回し** に分類。理由:「安全性ではなく製品ポリシーの変更（LM Studio利用者を切る判断）。既存方針を勝手に狭めない」 |
| 2026-07-27 | 作業指示書の作成 | **Codex** | `CLAUDE_CODE_REQUEST_SETTINGS_MENU_IMPLEMENTATION_2026-07-27.md` §4.1 で許可値を `ollama` のみに絞るよう指示。**「安全性の修正」と「製品ポリシーの変更」を区別せず一括で指示していた**（`generic-openai`／`native` と `localai`／`lmstudio`／`litellm`／`lemonade` を同列に扱っていた） |
| 2026-07-27 | 指示書の妥当性検証 | **Claude Code** | 指示書の主張3点を実コード・実env・実スクリプトで検証（§1.1、すべて事実と確認）。あわせて **§4.1 に2種類の判断が混在していることを指摘**し、後者はユーザー判断が必要としてエスカレーション |
| 2026-07-27 | **製品ポリシーの決定** | **ユーザー** | **「隠しましょう」** — `localai` / `lmstudio` / `litellm` / `lemonade`（および `koboldcpp` / `textgenwebui` / `docker-model-runner` / `privatemode`）を顧客向けに非表示とすることを承認 |
| 2026-07-27 | 安全性の修正（ユーザー判断を要さない） | **Claude Code** | `generic-openai`（外部送信リスク）と `native` embedding（未同梱・オフライン未検証・2026-07-26のP0バグ再発防止）を恒久除外。これは製品の中核的な約束に直結するため、判断の性質が上記とは異なる |
| 2026-07-27 | 実装方針 | **Claude Code** | 承認が下りたあとも**除外理由(A)(B)をコード上で別定数に分離**（`EXCLUDED_FOR_SAFETY_*` / `NOT_BUNDLED_*`）。承認されたことと除外理由が違うことは別問題であり、将来の担当が「なぜ除外されているか」「戻してよいか」を判断できる必要があるため |
| 2026-07-27 | 既存顧客のブリック回避 | **Claude Code** | `native` を保存不可としつつ**起動時のみ警告付きで許容**する非対称設計を採用（§2.2）。指示書には無い判断だが、2026-07-26以前のP0バグで `EMBEDDING_ENGINE=native` が書き込まれた既存環境が更新後に復旧不能になるため |
| 2026-07-27 | Step 3 の必要性検証 | **Claude Code** | 「バックエンドが既に拒否しているならURL guardは不要では」という問いに対し、**TTS/STT・Agent Skills・Scheduled Jobs はサーバー側で一切拒否されていない**ことを実測（§4.1）。過剰実装ではないと判断し実装した |
| 2026-07-27 | 新規ギャップの発見 | **Claude Code** | TTS/STT プロバイダーが製品プロファイルを参照しておらず、API経由で OpenAI / ElevenLabs / Deepgram / Groq を保存可能であることを発見（§5.2）。指示書のスコープ外のため**実装せず提起にとどめた** |

**Codexの指示書は有用だったが、仕様の正しさを保証するものではなかった。** 事実確認できた主張（§1.1）と、判断の性質が混在していた箇所（§1.2）と、記述が実態と違っていた箇所（§1.3 = `litellm` をローカル系に分類）が併存していた。今後もCodex指示書は「検証対象の入力」として扱う。
