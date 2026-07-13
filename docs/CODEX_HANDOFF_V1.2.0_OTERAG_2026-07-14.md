# Codex 引き継ぎメモ — OTE-RAG v1.2.0 ビルド＆実機検証（2026-07-14）

作成: Claude Code / 宛先: Codex（Windows実機担当）
この1枚で現状と作業が分かるようにまとめた。詳細手順は末尾のリンク先を参照。

---

## 1. これは何をするタスクか（ゴール）

**前回までに加えたOTE-RAG改良版（リブランド＋サービス制御UI＋デスクトップランチャー）で、Windowsに実際にインストールして、想定どおり動くかを検証する。**
そのために **v1.2.0 パッケージをWindowsでビルド → 管理者インストール → 検証** を通しで行う。**src再同期・ビルド・favicon再生成・検証まで一式をCodexに委任**（ユーザー了承済み）。

---

## 2. 現状（2026-07-14 時点）

### Linux側（WSL、開発の正）＝ 完成している
- localRAGリポジトリ: origin/mainと同期済み（クリーン）。
- fork `anything-llm`: 最新コミット `8907620d`「ブランド刷新 OTE-RAG + 日の丸ロゴ」。**forkはpushしない運用なのでWSLローカルにのみ存在**（＝Windowsへはファイルコピーで渡す）。
- コード・ロゴ・顧客資料すべてOTE-RAG化済み。

### Windows側（C:\LocalRAG）＝ 1つ前の状態で止まっている
| 対象 | 状態 |
|---|---|
| `C:\LocalRAG\windows-native`（launcher / install.ps1 / verifyランナー等） | ✅ **同期済み**。ランチャー表示は`OTE-RAG`、round2ランナー既定ZipPathは`v1.2.0`に更新済み |
| `C:\LocalRAG\src`（frontend/server） | ⚠️ **サービス制御(fork 57b5d115)までは反映済みだが、OTE-RAGリブランド(8907620d)が未反映**。index.htmlは今も「LocalRAG for ℳシステム」 |
| `C:\LocalRAG\dist` | ⚠️ **v1.0.0 と v1.1.0 のみ。v1.2.0 は未ビルド** |
| Round2検証 | 最新は 2026-07-13 の **v1.1.0 検証**（PASS）。**v1.2.0 は未検証** |

→ **ギャップは2つだけ**: (A) `C:\LocalRAG\src` にリブランド未反映、(B) v1.2.0 未ビルド・未検証。

---

## 3. Codexにやってほしいこと（順番）

### STEP 1: リブランドを `C:\LocalRAG\src` へ同期
同期元（WSL fork のワーキングツリー、`8907620d` 反映済み）:
```
\\wsl$\Ubuntu-22.04\home\ishihara1447\projects\fukugyo\repos\localRAG\anything-llm
```
`8907620d` で変わったのは **frontend 34ファイル + server 3ファイル**。**node_modules は上書きしないこと**（Windows用prebuiltを壊さないため）。以下を同期すれば十分:
- `frontend\src\`（配下すべて。ロゴSVG3点 `frontend/src/media/logo/localrag-*.svg` 含む）
- `frontend\index.html`
- `server\utils\boot\MetaGenerator.js`
- `server\utils\localServices\index.js`
- `server\models\systemSettings.js`

確認: 同期後 `C:\LocalRAG\src\frontend\index.html` の `<title>` が `OTE-RAG` になっていること。

### STEP 2: favicon（日の丸アイコン）を再生成
WSLではsharpのlinuxネイティブバイナリが無く生成できなかった。**Windows側（sharp動作）で** `localrag-icon.svg` から `frontend\public\favicon.png` を再生成する。スニペットは詳細ドキュメント Part A に記載。

### STEP 3: v1.2.0 をビルド
`yarn install`（server/collector/frontend）→ prisma windows generate → `yarn build`（frontend）→ `server\public` へコピー → `export-windows.ps1 -Version 1.2.0`。
- モデルは v1.1.0 と同じ（`qwen3:8b` + `bge-m3`、変更なし）。
- 生成物: `C:\LocalRAG\dist\LocalRAG-win64-v1.2.0.zip`。

### STEP 4: 実機検証（管理者）
```powershell
cd C:\Temp\localrag-round2
powershell -NoProfile -ExecutionPolicy Bypass -File .\round2-admin-verify.ps1 -ZipPath C:\LocalRAG\dist\LocalRAG-win64-v1.2.0.zip
```
（ランナー既定は既にv1.2.0。未ビルドなら「zip not found」で止まる＝旧版誤検証を防止する仕組みにしてある。）

**v1.2.0で新たに確認する項目（前回v1.1.0検証には無い）**:
1. インストール後、全ユーザーデスクトップに `OTE-RAG` ショートカット（`LocalRAG.lnk`）が作成される。
2. ショートカット→ランチャー(`LocalRAG.html`)がサーバー正常時にアプリへ自動遷移／停止時に日本語案内。
3. **Web UIからのサービス制御**（右上ピル→パネルでOllama/Collectorを起動停止。sc.exe実制御はWindows実機でのみ検証可能）。
4. Ollama停止でVRAM解放・入力欄上に警告バナー、再起動で復帰。
5. Server自身は自己停止対象に出ないこと。
6. 見た目が **OTE-RAG（日の丸アイコン）** になっていること（ブラウザタブ・サイドバー・ログイン・オンボーディング）。
7. 既存のE2E11項目・backup/stop/start・uninstallは回帰PASS。

### STEP 5: 報告
`docs/WINDOWS_NATIVE_VERIFY_V1.2.0_RESULT_2026-07-XX.md` に結果を記載（v1.1.0レポートのテンプレに上記1〜7を追加した形式）。

---

## 4. 注意（温存すべき技術識別子）

リブランドは**ユーザー可視の表示テキストのみ**。以下は実装・スクリプトと一致させる必要があるため**変更していない／しないこと**:
- Windowsサービス名: `LocalRAG-Server` / `LocalRAG-Collector` / `LocalRAG-Ollama`
- パス: `C:\LocalRAG*`, `C:\ProgramData\LocalRAG*`
- 配布zip名: `LocalRAG-win64-vX.Y.Z.zip`、import識別子 `LocalRAGIcon`、アセット名 `localrag-*.svg`
- install.ps1の実エラー文言「LocalRAG services already exist」

---

## 5. 詳細ドキュメント

- ビルド/検証の詳細手順（Part A/B/C・favicon再生成スニペット付き）: `docs/CODEX_WINDOWS_NATIVE_BUILD_V1.2.0_2026-07-13.md`
- リブランドの全体像・温存識別子: `docs/HANDOFF.md` 冒頭「【リブランド 2026-07-13】」
- 前回(v1.1.0)検証結果: `docs/WINDOWS_NATIVE_VERIFY_ROUND2_RESULT_2026-07-13.md`（v1.1.0を検証したもの。v1.2.0検証の比較基準）
