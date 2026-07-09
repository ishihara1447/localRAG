# Windows Native Phase 4 設計メモ（サービス化・配布バンドル・preflight）

作成日: 2026-07-09（Claude Code）
前提: PoC合格（`docs/WINDOWS_NATIVE_POC_RESULT_2026-07-09.md`、RAG E2E 11/11 PASS）

## Go判断（J-1）

**Windows native方式を顧客配布の本命としてPhase 4に進む — Go。**

根拠:
- native依存（lancedb/sharp/prisma）のWindows prebuilt解決・frontend build・server/collector起動・GPU認識（RTX 5070 Ti, CUDA）・オフラインモデル投入・RAG E2E 11/11 PASSまで、PoC合格条件をすべて満たした
- 判明した課題4件はいずれも設計・実装で解決可能な性質（原理的なブロッカーではない）

課題対応状況:

| # | PoC課題 | 対応 |
|---|---|---|
| 1 | PowerShell 5.1で日本語parser error | **対応済み**: `rag-e2e-test.ps1`をUTF-8 BOM付き化（5.1互換）。配布物の.ps1はすべてBOM付きを規約とする |
| 2 | hotdirが`C:\collector\hotdir`に誤解決 | **対応済み**: fork `fd67e830`で`COLLECTOR_HOTDIR_PATH` env追加（server/collector共有）。envテンプレも更新済み |
| 3 | 11434がWSL relayと競合 | Phase 4で対応: LocalRAG専用Ollamaを専用ポートでサービス管理 + preflight検出（下記） |
| 4 | 顧客PCでyarn installさせられない | Phase 4で対応: ビルド済み成果物の同梱方式（下記） |

---

## 設計1: プロセス管理（server / collector / Ollama の3プロセス）

### 比較

| 方式 | 長所 | 短所 |
|---|---|---|
| **WinSW（Windows Service化）** | MIT license・単一exe・XML設定・ログローテーション内蔵・自動起動/再起動ポリシーあり・.NET同梱環境で追加依存なし | サービス登録に管理者権限が必要 |
| NSSM | 実績豊富・堅牢 | 最終リリースが古い（2017）・ライセンスはPublic Domain相当だが保守停滞 |
| Electron/Tauriのtrayアプリ | 顧客体験が最良（常駐アイコン・GUI起動停止） | 新規実装コストが大きい・アップデート機構も自前 |
| 起動bat/タスクスケジューラ | 実装最小 | 再起動耐性・ログ・停止管理が弱く製品品質に届かない |

### 推奨: **WinSW でWindows Service 3本**（LocalRAG-Server / LocalRAG-Collector / LocalRAG-Ollama）

- インストールは管理者権限前提（士業向けにはITエンジニア/インストーラーが1回だけ実行する想定で許容）
- 各サービスのenv・ログパス・再起動ポリシーをXMLで固定 → 構成が宣言的でサポートしやすい
- trayアプリは将来のUX改善（v2以降）として保留。サービス化と排他ではない

### Ollama の扱い

- **既存のOllama for Windowsインストールに依存しない**。LocalRAG専用のollama実行ファイル（公式配布の`ollama-windows-amd64.zip`スタンドアロン版）を配布物に同梱し、専用サービスとして起動する:
  - `OLLAMA_HOST=127.0.0.1:11435`（既定。11434は顧客環境の既存Ollama/WSL relayと衝突しうるため使わない）
  - `OLLAMA_MODELS=C:\ProgramData\LocalRAG\models`（配布物からコピー）
  - `OLLAMA_KEEP_ALIVE=24h`
- 顧客が別途Ollamaを使っていても干渉しない（プロセス・ポート・モデルディレクトリすべて分離）

## 設計2: 配布物のバンドル構成（顧客PCでビルドさせない）

ビルドマシン（実Windows機 or GitHub Actions `windows-latest`）で以下を生成し、zipに固める:

```
LocalRAG-win64-vX.Y.Z/
├── install.ps1               # UTF-8 BOM。preflight → 展開 → サービス登録 → smoke test
├── uninstall.ps1 / start.ps1 / stop.ps1 / backup.ps1 / restore.ps1
├── runtime/
│   ├── node/                 # Node.js LTS Windowsポータブル版（node.exe一式）
│   └── ollama/               # ollama-windows-amd64 スタンドアロン一式
├── app/
│   ├── server/               # ソース + Windowsでyarn install済みnode_modules
│   │   └── public/           # ビルド済みfrontend（dist）
│   ├── collector/            # 同上（puppeteer/Chromiumなし = PUPPETEER_SKIP_DOWNLOAD）
│   └── prisma/               # windows用query engine（binaryTargets対応済み）
├── models/                   # llm-jp-4-8b-thinking GGUF + mxbai-embed-large（blob形式）
├── winsw/                    # WinSW.exe + LocalRAG-{Server,Collector,Ollama}.xml
├── checksums/                # sha256（Docker版export.shと同じ3種構成）
├── LICENSES/ + NOTICE        # AnythingLLM/Ollama/llm-jp/mxbai/WinSW(MIT)を追加
└── docs/                     # INSTALL/OPERATIONS/SECURITY/TROUBLESHOOTING（Windows native版）
```

- 配置先: プログラム本体 `C:\Program Files\LocalRAG`、データ `C:\ProgramData\LocalRAG\{storage,hotdir,models,logs}`
  - hotdirは`COLLECTOR_HOTDIR_PATH`で明示指定（課題#2の恒久対応を活用）
- installerツールは当面 **zip + install.ps1**（Docker版install.shと同じ思想・検証資産を再利用）。
  パイロット顧客で問題なければ、その後Inno Setupでexe化を検討（見た目の安心感が要るとき）
- モデル（~5-8GB）を含めた総サイズはDocker版（9.3GB）と同等の見込み

## 設計3: preflight仕様（install.ps1冒頭で実行）

| チェック | 合格条件 | 失敗時 |
|---|---|---|
| OS | Windows 11 (10.0.22000+) | 中止 |
| 管理者権限 | 昇格済み | 中止（サービス登録に必要） |
| GPU | `nvidia-smi`が成功しNVIDIA GPU検出 | 中止（要件明示） |
| VRAM | 16GB以上（`nvidia-smi --query-gpu=memory.total`） | 警告（低VRAM動作は仮説D検証後に基準化） |
| ポート | 3001（または設定値）・8888・11435のowner processなし | 中止し占有プロセス名を表示（wslrelay.exe検出時は専用メッセージ） |
| ディスク | 空き20GB以上 | 中止 |
| PowerShell | 5.1以上（BOM付きps1で両対応済み） | — |
| 既存インストール | `C:\ProgramData\LocalRAG`の有無 | 更新モード or 中止を選択 |

## Phase 4 タスク分解（担当明示）

| # | タスク | 担当 |
|---|---|---|
| 4-1 | WinSW設定XML 3本 + サービス登録/解除のps1実装 | Claude Code（WSL側で作成、BOM付き） |
| 4-2 | `export-windows.ps1`（ビルドマシンで配布zip生成。export.shのWindows native版） | Claude Code（設計・スクリプト）→ Codex（実機でビルド実行） |
| 4-3 | install.ps1 + preflight実装 | Claude Code |
| 4-4 | uninstall/start/stop/backup/restore ps1実装 | Claude Code |
| 4-5 | 実機での通しインストール検証（真っさら状態→サービス3本→E2E 11/11） | Codex |
| 4-6 | 完全オフライン（ネットワーク遮断）検証 | Codex |
| 4-7 | 顧客向けdocs（INSTALL/OPERATIONS/SECURITY/TROUBLESHOOTING）Windows native版 | Claude Code |
| 4-8 | LICENSES更新（WinSW追加）・SBOM | Claude Code |

依存関係: 4-1〜4-4はClaude Codeが先行可能 → 4-5/4-6はCodexが配布zip生成後に実施。
既存のWSL2+Docker方式・スクリプト群は引き続き無変更で温存（保険）。

## 未決事項（着手前にユーザー確認不要、実装中に判断して事後報告）

- Node portable版のバージョン固定（LTS 22.x系を想定、PoCはv24で成功しているため問題は出にくい）
- サービスのログローテーション量（WinSW既定値ベースで開始）
- 更新（バージョンアップ）手順の設計はv1配布後に回す（backup→uninstall→install→restoreで代替可能）
