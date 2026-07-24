# OTE-RAG v1.2.4 新機能レビュー(旧版自動アンインストール＋ショートカット導線変更)
調査日: 2026-07-24 / 担当: researcherサブエージェント

## 良い点
- 旧版削除確認をbusy恒久ロック前に置き、Cancel時は画面操作可能に戻す設計は正しい。
- ARP→フォルダ検出のフォールバック順、文書データ保持の明記、自動削除不能時の手動案内。
- uninstall.ps1は非対話・keep-data既定・個別try/catch・プロセスkill+30秒待ち・StartsWith厳密化済み。
- ショートカット廃止でARP＋cmdの2経路に集約(Windows標準UXに寄せる正しい方向)。

## ① ロジックの不具合・エッジケース
**P1-1(最優先・実行可能): keep-data退避失敗→app残置→install.ps1 preflight再失敗の堂々巡り**
- 旧uninstall.ps1がstorage退避失敗(ロック)→手順5で app を意図的に残す(文書保護)＋**exit 0**。
- Setup.csは uninstallExit==0 を成功とみなし通常インストールへ。
- install.ps1 preflight が `InstallRoot\app` 残存を検出(-Force無し)→ Fail exit 1。
- 結果: 「旧版を自動削除しました」直後に「app が既に存在します」で停止=非エンジニアが詰む堂々巡り。
- 改善案②(推奨・rollback契約を乱さない): uninstall.ps1がkeep-dataでstorage退避に失敗したら**専用exitコード**を返し、Setup.cs側で「文書がロックされています。エクスプローラ/ウイルス対策を閉じて再実行してください」と具体案内して中止。案①(-Force付与)はpreExistingガードとrollback契約に影響するため非推奨。

**P2-2: uninstallerPath==null分岐の同意順序**: 確認ダイアログ(OKCancel)を出しOK後に「自動削除できない」と出るのは二度手間。確認前にnull判定して直接「手動削除が必要」を案内する方が親切(低優先)。

**P2-3: 別InstallRootの旧版検出の非対称性**: ARP検出はInstallLocationを見るので別ドライブでも消せる(良い)。フォールバックのフォルダ検出はtarget\appのみ→ARP未登録かつ別ドライブの旧版は検出漏れ→preflightが最終的に止める(サイレント破壊なし)。実害小・P2。

## ② 非エンジニアUX
**P2-4: 旧版アンインストール中の進捗表示なし**: RunProcessAsync(uninstall.ps1)中ProgressBarがBlocks(0)のまま。数十秒〜数分無反応に見える。→実行直前にMarquee化、完了後Blocks/0に戻す(低工数・体感改善大)。

**P2-5: 退避先パス`uninstalled-<日付>`表記**: 実際は時刻付き。概念説明として許容。退避が複数回で増える点は将来メモ。

## ③ 既存機能との干渉
- Mutex/exit3: 影響なし。
- rollback: 旧版削除はinstall.ps1の外(Setup.cs)で完結しrollback対象外。案①(-Force)採用時はpreExistingガードと衝突リスク→案②推奨の根拠。
- preflight: P1-1がまさに干渉点。

## 結論
**未収束。実行可能な修正1件(P1-1)。** keep-data退避失敗時の後続preflight堂々巡りを、案②(uninstall.ps1が専用exit＋Setup.cs具体案内)で解消すれば収束(署名スコープ外)。P2群は次回一括で可。
