# OTE-RAG アンインストーラ / 回復動線 再レビュー (Round1修正後)
調査日: 2026-07-24 / 担当: researcherサブエージェント(再レビュー)

## ① 前回指摘の解消状況（全て解消）
| 前回指摘 | 状態 |
|---|---|
| P0-1 上書き回復ループ | ✅ install.ps1がbody全体をtry/catch、失敗時Invoke-Rollback(サービス解除+ショートカット+ARP+InstallRoot削除、storageは退避)。Setup.csは失敗時ボタン再有効化せず「自動で元に戻した/閉じて再実行」。 |
| P0-2 ARP未登録 | ✅ HKLMにDisplayName/Version/Publisher/InstallLocation/DisplayIcon/UninstallString(引用符)/QuietUninstallString/NoModify/NoRepair/EstimatedSize。uninstall/rollbackで削除。キー名英数字。 |
| P0-3 プロセスkill/削除待ち | ✅ uninstall.ps1にStop-LocalRagProcesses(パス限定)＋sc delete後30秒消滅待ち＋残存Warn。 |
| P1-7 破壊的既定 | ✅ cmd完全削除に二段確認＋終了コード判定でメッセージ出し分け。 |
| P2-8 虚偽コメント | ✅ 実態に修正。 |
| P1-5 ping誤判定 | ✅ exit3(成功系)、Setup.csが成功扱い、ロールバックされない。 |

## ② 残るP0/P1
**P0: なし。**

**P1-A**: `Invoke-Rollback`が`$InstallRoot`を無条件`Remove-Item`するため、`-Force`上書き失敗時に既存の正常インストールごと破壊しうる。現状Setupは-Force未使用で通常非発火だが、将来アップグレードで-Force使用時の時限爆弾。→ `-Force`(既存あり)時はrollbackのInstallRoot全削除を抑制(preExistingフラグ)、または開始前に既存を退避して失敗時復元。

**P1-B**: EstimatedSizeがInstallRoot実測でmodels(数GB, $DataRoot)を含まず過小表示。QuietUninstallStringはuninstall.ps1直接(昇格ラッパー非経由)＋データ保持既定で、企業一括削除の期待と食い違う可能性。→ サイズにmodels加算 or QuietUninstallに-RemoveData/ドキュメント化。

**P1-C**: `-Force`上書きが`robocopy /E`でstale file残留(アップグレード正当経路の課題、回復ループとは別)。→ backup→旧app purge(storage除外)→新規コピー、当面/MIR(storage/hotdir除外)。

## ③ 新たな不具合 / リグレッション
**R-1(中〜高, P1相当)**: `Invoke-Rollback`がサービス解除後・InstallRoot削除前に**プロセスkill+サービス消滅待ちをしていない**。サービス登録直後(起動済ollama/node)に失敗するとファイルロックで`Remove-Item ... -SilentlyContinue`が部分削除で終わる→次回installのプリフライトで`InstallRoot\app`検出→**回復ループ再発**。→ rollbackにもkill+待機を(uninstall.ps1の1b相当を関数化して共用)。**P0-3修正の穴埋めで優先度高め。**

**R-2(低)**: cmd二段確認のerrorlevel判定順序(2=Nを先に判定)は正しい。問題なし。

**R-3(低)**: exit3成功扱いの副作用で「本当の起動失敗」も成功表示になる。回復はアンインストール→再インストールで可能。ping失敗時に`Get-Service LocalRAG-*`のRunning/Stoppedをログ出力するとサポート切り分けが楽(任意)。

**R-4(低)**: uninstall.ps1の`Move-Item $storage`は`ErrorActionPreference=Stop`下でロック時に例外→以降の削除が中断。R-1と同根。主要削除ステップを個別try/catchで包むと最後まで走る。

## 総括
uninstaller/回復動線は署名を除きほぼ収束。優先順:
1. **R-1**(rollbackにプロセスkill+待機) — 回復ループ再発の穴埋め、実質必須。
2. **P1-A**(rollbackが-Force時に既存環境を巻き込む) — ガード追加(安価)。
3. **R-4**(uninstall削除の個別try/catch) — 堅牢性。
4. P1-B/R-3/P1-C — 品質・アップグレード課題(低優先/別トラック)。
