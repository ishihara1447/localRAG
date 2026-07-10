# Round 2 検証ランナー（管理者権限で1回だけ実行）

Windows native配布パッケージの通しインストール検証（依頼書 `docs/CODEX_WINDOWS_NATIVE_VERIFY_ROUND2_2026-07-10.md` のPart B）を、
**人手の判断を挟まず一気に実行する**ためのスクリプト。管理者権限（UAC昇格）が必要なため、
そこだけは人間が実行する必要がある（Codex/Claude Codeはプログラムから昇格できない）。

## ファイル

- `Run-Round2-Verify.cmd` — ダブルクリックするとUAC昇格して下のps1を実行するランチャー。
- `round2-admin-verify.ps1` — 検証本体（tar展開→install→疎通/ログ→APIキー→GPU状態→E2E→backup/stop/start→uninstall→片付け）。

## 使い方（ユーザー作業）

1. このフォルダを **Cドライブ上の場所**にコピーする（例: `C:\Temp\localrag-round2\`）。
   ※WSLの `\\wsl.localhost\...` 上のままだと、既定のPowerShell実行ポリシーで `.ps1` がブロックされるため。
   ※配布zip本体（`C:\LocalRAG\dist\LocalRAG-win64-v1.0.0.zip`）は既にビルド済みのものを使う。
2. `Run-Round2-Verify.cmd` を**ダブルクリック**する。UACの確認が出たら「はい」を押す。
3. 20〜60分ほどかかる（checksum検証とモデルロードで長い沈黙があるが正常）。完了すると `pause` で止まる。

## 結果の在りか（実行後、Claude Codeに渡すもの）

- `C:\Temp\localrag-round2-logs\round2-admin-<日時>.summary.json` — 各ステップのOK/NG判定（これが一番重要）
- `C:\Temp\localrag-round2-logs\round2-admin-<日時>.transcript.txt` — 全出力の記録
- `C:\Temp\localrag-round2-logs\service-logs-<日時>\` — 3サービスのログのコピー

これらを共有してもらえれば、Claude Code側で合否を判定し、必要な修正を行う。

## オプション

- 既定ポートは3005（3001はWSL relayが使用中のため）。変える場合: `Run-Round2-Verify.cmd -ServerPort 3006`
- 検証後もデータ（`C:\ProgramData\LocalRAG`）を残したい場合: `Run-Round2-Verify.cmd -KeepProgramData`
- 再起動耐性（B2-6）はランナーではSKIPする。確認したい場合は手動でWindowsを再起動し、
  `Get-Service LocalRAG-*` が全てRunning・`http://localhost:3005/api/ping` が通ることを確認する。
