# Windows Native オフラインインストール 作業計画（ルーズ版）

作成日: 2026-07-09（Claude Code）
背景: `CLAUDE_CODE_MEMO_WINDOWS_NATIVE_DISTRIBUTION_2026-07-09.md`（Codex提案）を受け、Claude Codeが技術的実現可能性を独自検証した上で作成。士業ヒアリング（コア仮説検証）は本計画のスコープから**意図的に除外**し、技術トラックを先行させる方針（ユーザー判断）。

## 前提・方針

- **目標**: Docker / WSL2なしで、真っさらなWindows 11（GPU搭載機）にLocalRAGをオフラインインストールできる状態を作る。
- **現行のWSL2+Docker方式（A）は一切変更しない**。保険として温存。
- **担当分担の原則**:
  - Claude Code = このリポジトリ（WSL2/Linux環境）で完結するコード変更・設計・スクリプト作成・ドキュメント統合
  - Codex = 実際にWindows機（ホスト側ネイティブ環境）での実行・確認が必要な作業
- npm系ネイティブ依存（`@lancedb/lancedb` / `sharp` / `prisma` / `@xenova/transformers`）はWindows向けprebuiltバイナリが公式配布されているため、**実Windows機で`npm install`/`yarn`すれば解決する**（コンパイラ導入は不要）。WSL2上でのクロスビルドは過去に`sharp`が失敗した実績があるため試みない（`WORK_PLAN.md` Phase1参照）。
- `puppeteer`（Webリンク取り込み専用、PDF/DOCX処理には不使用）はWindows native版では**機能ごと無効化し配布物から除外する**方向で検討（最も壊れやすく重いネイティブ依存を早期に消す）。

---

## Phase 0: コード側の下準備（Claude Code）

実機作業の前に、WSL2側で完結する変更を先に済ませる。

| # | タスク | 担当 |
|---|---|---|
| 0-1 | Webリンク取り込み機能（`processLink`, `WebsiteDepth`）を無効化するフィーチャーフラグをforkに実装し、`puppeteer`を実行時に読み込まないようにする | Claude Code |
| 0-2 | `server/prisma/schema.prisma` に `binaryTargets = ["native", "windows"]` を追加 | Claude Code |
| 0-3 | Windows native起動用の最小`.env`テンプレート（`server/.env.windows.example`）を作成 | Claude Code |
| 0-4 | `BARE_METAL.md`の手順をWindows向けに読み替えた実行チェックリスト（PowerShellコマンド列挙）を作成し、Codexに渡す | Claude Code |
| 0-5 | `rag-e2e-test.sh`のWindows PowerShell移植版（`rag-e2e-test.ps1`）を作成 | Claude Code |

**完了条件**: 0-1〜0-5がコミット済みで、Codexが実機作業をそのまま開始できる状態。

---

## Phase 1: Windows native起動確認（Codex）

Docker/WSL2を使わず、実Windows機上でサーバーが立ち上がるかだけを確認する。installerは作らない。

| # | タスク | 担当 |
|---|---|---|
| 1-1 | Node.js v18+ / Yarn（Corepack経由）を実機に導入 | Codex |
| 1-2 | `frontend`をbuildし`server/public`に配置 | Codex |
| 1-3 | `server` / `collector`で`yarn`実行 → `@lancedb/lancedb-win32-x64-msvc` / `@img/sharp-win32-x64`等のprebuiltが正しく解決されるか確認 | Codex |
| 1-4 | `prisma generate` / `prisma migrate deploy`を実機で実行 | Codex |
| 1-5 | `server`・`collector`を`node index.js`でプロセス起動、`http://localhost:3001`にアクセスできるか確認 | Codex |
| 1-6 | puppeteer無効化後もエラーなく起動することを確認（欠落モジュール等のエラーが出ないか） | Codex |

**完了条件**: Docker/WSLなしでAnythingLLM画面がブラウザで開く。
**ブロッカー時**: Codexから結果・エラーログをClaude Codeに共有 → Claude Codeがforkコードを修正 → Codexが再試行。

---

## Phase 2: Ollama Windows native + オフラインモデル投入（Codex主導、一部Claude Code）

| # | タスク | 担当 |
|---|---|---|
| 2-1 | Ollama for Windowsをインストールし`127.0.0.1:11434`で起動確認 | Codex |
| 2-2 | 現行WSL2側`.ollama/models`（`llm-jp-4-8b-thinking`, `mxbai-embed-large`のblob一式）をWindowsの`%USERPROFILE%\.ollama\models`にコピーし、`ollama pull`なしでモデル認識するか確認 | Codex |
| 2-3 | `ollama run <model>`で応答確認（GPU使用の有無・速度も記録） | Codex |
| 2-4 | AnythingLLM(Windows native)からOllama(Windows native)への接続設定値（`LLM_PROVIDER`, `OLLAMA_BASE_PATH`等）を用意 | Claude Code（設定値を用意） → Codex（実機投入） |

**完了条件**: Windows native版AnythingLLMからWindows native版Ollamaに接続できる。

---

## Phase 3: RAG E2E検証（Codex実行、Claude Codeがレビュー）

| # | タスク | 担当 |
|---|---|---|
| 3-1 | Phase0で作成した`rag-e2e-test.ps1`を実機で実行 | Codex |
| 3-2 | 外部provider拒否・Swagger無効・出典必須プロンプトがDocker版と同等に効くか確認 | Codex実行 → Claude Codeが結果照合 |
| 3-3 | 日本語CIDフォントPDF・DOCX・TXTの取り込み〜質問応答が通るか確認（既存fixturesを使用） | Codex |
| 3-4 | 結果ログをClaude Codeに共有、Docker版との差分有無を整理 | Codex → Claude Code |

**完了条件（PoC合格ライン）**: Docker版と同等のRAG e2e（6ステップ）がWindows native上でタイムアウトなく通る。

---

## PoC judge（Claude Code）

Phase 1〜3の結果をもとに、Windows native方式を本命として継続するか判断する。

| # | タスク | 担当 |
|---|---|---|
| J-1 | Phase1〜3の結果を`docs/HANDOFF.md`に統合、Go/No-Go判断を記録 | Claude Code |
| J-2 | No-Goの場合、代替案（機能縮小 or A方式継続）を整理 | Claude Code |

---

## Phase 4: サービス化・配布パッケージ設計（PoC合格後のみ着手）

まだ着手しない。PoCが通った場合のみ以下に進む。

| # | タスク | 担当 |
|---|---|---|
| 4-1 | プロセス管理方式（NSSM/WinSWによるWindows Service化 / Electron・Tauriのtrayアプリ / 単純起動bat＋タスクトレイなし）の比較メモ作成 | Claude Code |
| 4-2 | 選定方式を実機に導入し、自動起動・ログ・再起動耐性を確認 | Codex |
| 4-3 | installer（Inno Setup / MSI等）の雛形スクリプト作成 | Claude Code（雛形） → Codex（実機ビルド・実行確認） |
| 4-4 | アンインストール・更新・バックアップ手順の設計 | Claude Code（設計） → Codex（実機検証） |
| 4-5 | 完全オフライン（ネットワーク遮断）状態での通し検証 | Codex |

---

## Phase 5: ドキュメント統合

| # | タスク | 担当 |
|---|---|---|
| 5-1 | 結果を`docs/HANDOFF.md` / `CLAUDE.md`に反映 | Claude Code |
| 5-2 | fukugyoハブ側 `STATUS.md` / `PROJECTS.md`に配布方式変更を反映 | Claude Code |

---

## 未解決の判断ポイント（Phase4着手前に決める）

- サービス化はWindows Service方式かtrayアプリ方式か（保守コスト・顧客体験のトレードオフ）
- installerツールの選定（Inno Setup / WiX / 単純zip配布のいずれか）
- 顧客PCのGPUドライバ・CUDA前提をinstallerがどこまで面倒を見るか

## 依存関係の要点

- Phase 0（コード変更）が終わらないとPhase 1は開始できない
- Phase 1が通らない限りPhase 2〜3、Phase 4には進まない
- Phase 4はPoC合格（Phase 1〜3）が前提。現時点では着手しない
