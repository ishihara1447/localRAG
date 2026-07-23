# OTE-RAG Installer 再レビュー (Round1修正後)
調査日: 2026-07-24 / 担当: researcherサブエージェント(再レビュー)

## 総評
前回最大のP0(失敗時ロールバック不在)は正しく解消。preflight/checksumはexit即時・成果物生成後のみrollback arm、exit 3はprocess終了でcatch(rollback)を貫通しない、という境界設計が的確。日本語化・ARP登録・.env UTF-8・Ollama xmlも解消。**installerコア堅牢性は収束レベル(署名除く)。** 残るは非致命のP1×3＋P2群。

## ① 前回指摘の解消状況
| 前回 | 状態 |
|---|---|
| P0-1 ロールバック/原子性 | ✅ body try/catch＋Invoke-Rollback(逆順)＋servicesTouchedガード |
| P0-3 ローマ字/英語メッセージ | ✅ ほぼ(WARN系に英語残存→P2-3) |
| P1-6 半成功を失敗表示 | ✅ ping timeout→exit3、Setup.csが成功系扱い |
| P1-8 .env破損 | ✅ UTF8(BOMなし) |
| Ollama xml旧モデル名 | ✅ gemma4/bge-m3 |
| ARP登録(新規good) | ✅ 追加 |

## ② 残るP1
- **P1-A(新規/UX)**: exit 3でもSetup.csが生URLを`Process.Start`で自動起動→サーバ未応答の接続エラーページが開き、ダイアログ案内と矛盾。→ startupTimedOut時はブラウザ自動起動をスキップ、または`InstallRoot\LocalRAG.html`(サーバdown時に案内できる自作ランチャー)を開く。低工数。
- **P1-B(前回P1-4)**: 多重起動防止(Mutex)なし。rollback導入で競合(2つのInvoke-Rollbackが同じサービス/InstallRootを奪い合う)危険度が上昇。→`Mutex(true,"Global\\OTE-RAG-Setup")`。
- **P1-C(前回P1-7)**: モデル~9GBは常にC:、展開tempもC:固定。preflightのディスク20GB確認はInstallRootドライブのみ。→C:(ProgramData＋temp)の空きもpreflightで確認。

## ③ 新規不具合/リグレッション
- **P1-A**(上記, exit3ブラウザ自動起動) = 今回exit3導入に伴う実質新規バグ。最優先。
- **P2-1**: QuietUninstallStringが非昇格でuninstall.ps1直接→管理者チェックで失敗。ARPボタンは自己昇格cmdなので実害限定。→Quietも自己昇格cmd(サイレント引数)へ。
- **P2-2**: ARP EstimatedSizeがモデル~9GB(ProgramData)を含まず過少表示。cosmetic。
- **P2-3**: 顧客可視WARNに英語残存(VRAM/ショートカット/ARP失敗)。
- **P2-4**: rollbackのstorage退避はデータ保全(good)だが、退避先が自動復帰しないためリトライ後は空storage→顧客「文書消えた」誤認。→失敗メッセージに退避先を明示。
- **P2-5**: Invoke-Rollbackがunregister直後にInstallRoot削除→WinSW非同期でプロセスがファイル保持しロック部分削除の可能性(uninstaller再レビューのR-1と同根)。→rollbackにもプロセスkill+待機。
- 前回P1-5(キャンセル/進捗粒度)未着手。rollback導入で最悪シナリオは緩和、P2へ格下げ可。

## 結論
失敗時対処は解消・実装妥当。installerコアは収束(署名除く)。費用対効果順の残タスク:
1. P1-A exit3時ブラウザ自動起動抑制(ランチャーHTMLへ) — 今回導入分の新規バグ
2. P1-B Mutex多重起動防止 — rollbackで競合リスク上昇
3. P1-C preflightにC:空き容量チェック
4. P2群(rollbackにプロセスkill=P2-5/R-1、storage退避先明示、英語WARN日本語化、EstimatedSizeにmodels、QuietUninstall昇格)
