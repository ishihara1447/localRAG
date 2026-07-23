# OTE-RAG アンインストーラ / インストール失敗回復 / 上書き再インストール レビュー
調査日: 2026-07-24 / 担当: researcherサブエージェント

## サマリー
- 自己昇格(UAC)ダブルクリック・データ既定保全・両ショートカット削除・sc.exeフォールバックなど土台は良好だが、**「プログラムと機能(ARP)」への登録が皆無**で非エンジニア顧客が正規の削除導線を持たない。
- 最大の弱点は**上書き再インストールの回復動線**: install.ps1が上書き拒否 → 失敗後にファイル/サービスが半端に残る → 手動でアンインストーラを探すしかない（＝今回の実障害）。
- アンインストーラのべき等性は概ね良いが、**実行中プロセス(ollama.exe/node.exe)の明示killと削除完了待ちが無く**、孤立サービス・ファイルロックで中途半端に残るリスク。

## 良い点
- 自己昇格ダブルクリック（`%~dp0`でcwd非依存）／データ既定保全＋`-RemoveData`明示削除／両ショートカット削除／sc.exeフォールバック／checksum検証／日時付きログ。

## 不足・リスク・改善案（優先度付き）

### P0
**1. 上書き再インストールの回復ループ** — install.ps1が失敗すると app/サービスが残り、再実行が必ず`"uninstall first"`で再失敗。非エンジニアは詰む。Setupは既に昇格済みなので**失敗時に「クリーンアップして再試行」ボタン→uninstall.ps1自動実行→再有効化**でGUI内完結が理想。「Closeのみ」にするなら、閉じた後の手順（デスクトップの「OTE-RAG アンインストール」→再Setup）を明示メッセージで案内。加えてinstall.ps1自体に失敗時ロールバックを。

**2. ARP（プログラムと機能 / 設定→アプリ）未登録** — 唯一の削除導線がショートカット。標準の場所に出ない＝非エンジニアが削除できずサポート問い合わせ/放置。→ install時に `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OTE-RAG`（キー名は英数字）に DisplayName/DisplayVersion/Publisher/InstallLocation/DisplayIcon/EstimatedSize/NoModify=1/NoRepair=1、`UninstallString="<InstallRoot>\Uninstall-OTE-RAG.cmd"`、QuietUninstallString。uninstall時にキー削除。

**3. アンインストーラが実行中プロセスをkillせず削除完了を待たない** — `sc.exe delete`はハンドル残存で削除保留、ollama.exe/node.exeロックでInstallRoot削除が黙って失敗→中途半端に残る→次のインストールも拒否。→(a)サービス停止後にInstallRoot/DataRoot配下のollama.exe/node.exeをtaskkill、(b)`sc delete`後に消滅待ちループ、(c)残存検証してログ明示。

### P1
4. install.ps1に失敗時ロールバック（partial install cleanup）が無い → try/finallyで失敗時に自動クリーンアップ（登録サービスのunregister・app削除・storage保全）。少なくとも失敗メッセージに「Uninstall-OTE-RAG.cmd実行後に再インストール」を明記。
5. ping失敗が「インストール失敗」と誤判定（実際は導入完了・起動遅延の可能性）→ 区別可能な終了コード/メッセージ（導入完了だが起動未確認）にしSetup側で出し分け。
6. `-Force`上書きが`robocopy /E`で旧ファイル残置（アップグレード腐敗）→ stop→backup→app purge（storage除外）→新規コピー→migrate→start。当面`/MIR`(storage/hotdir除外)。
7. choiceのY/N既定が破壊的側（Y=全データ削除が先頭）→ 保持側を既定/推奨に、`-RemoveData`は二段確認（"DELETE"入力等）。

### P2
8. 自己削除が未実装（コメント虚偽）→ デタッチした遅延`rmdir`で親フォルダ自己削除、またはコメント修正。
9. 保全バックアップ`uninstalled-<日時>`とログが無限蓄積 → 世代上限/削除案内。
10. スタートメニュー未登録 → デスクトップ＋Startメニュー（起動＋アンインストール）。
11. `C:\OTR\<日時>`一時展開とInstallerLogsがアンインストールで残る → 完全削除時は掃除対象に。
12. cmdがuninstall.ps1の終了コードを見ない（失敗でも「完了」表示）→ `%errorlevel%`判定で出し分け＋ログ案内。

## 主要出典
- [Configuring Add/Remove Programs — Microsoft Learn](https://learn.microsoft.com/en-us/windows/win32/msi/configuring-add-remove-programs-with-windows-installer)
- [Uninstall registry key — Microsoft Learn](https://learn.microsoft.com/en-us/windows/win32/msi/uninstall-registry-key)
- [Add uninstall info to Add/Remove Programs — NSIS](https://nsis.sourceforge.io/Add_uninstall_information_to_Add/Remove_Programs)
- [Generic PowerShell uninstall script — RobzTech](https://robztech.com/post/generic-powershell-uninstall-script)
- [Cleaning up after an incomplete uninstall — Broadcom KB](https://knowledge.broadcom.com/external/article/367425/cleaning-up-after-an-incomplete-uninstal.html)
- [Cleanup software installation — IBM Docs](https://www.ibm.com/docs/ssw_aix_72/install/HT_insgdrf_cleanup_software.html)
- [Remove orphaned apps from Add/Remove — Petri](https://petri.com/remove_orphaned_apps_from_the_add_remove_applet_in_control_panel/)
- [レジストリのUninstall(JP) — barorin&](https://barorin-to.com/posts/windows-registry-uninstall-app/) / [INASOFT(JP)](https://www.inasoft.org/webhelp/rnsf7/HLP000220.html) / [Lifeboat(JP)](https://www.lifeboat.jp/newblog2/?p=10474)

## 要追加調査
- Setup.csの「失敗時Install無効化」変更の反映状況（レビュー時のファイルには未反映に見えた＝要確認）。
- winsw/register-services.ps1・unregister-services.ps1の実装（プロセスkill・削除完了待ち・べき等性）。
- ARP起動時のcmd→powershell RunAs昇格の実機挙動。
- 未署名によるUAC「発行元不明」警告（署名は別トラック）。
