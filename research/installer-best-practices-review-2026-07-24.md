# OTE-RAG Windowsインストーラ設計レビュー（ベストプラクティス突合）
調査日: 2026-07-24 / 担当: researcherサブエージェント

## サマリー（3行）
現行インストーラはpreflight・SHA-256検証・WinSWサービス化・ログ・自己昇格まで押さえた良い骨格だが、**失敗時のロールバック/原子性が皆無**で「中途半端な壊れた状態」を残しやすく、非エンジニア（士業）には自力復旧不能な袋小路になる。**未署名exeのSmartScreen対策ゼロ**は導入前に脱落する最大級の採用障壁。加えて、エラーメッセージのローマ字/英語混在、多重起動防止なし、キャンセル不可、日本語パス破損、モデルがC:固定など、非エンジニア配慮とオフライン堅牢性に複数の穴がある。

## 実装済みで良い点
- preflightが充実（管理者・OSビルド・GPU/VRAM・ディスク空き・ポート占有・既存インストール検出）
- 二重の完全性検証（GUIが外側zipのSHA-256、install.ps1が内部ファイル単位のsha256）＝エアギャップ定石
- WinSWでサービス化＋onfailure restart＋ログローテート、依存順(Ollama→Collector→Server)、専用ポート11435で衝突回避
- 自己昇格(runas)をGUI/cmd両方に実装、WorkingDirectory固定
- ログ集約＋失敗ダイアログにログパス/展開先提示
- ping疎通確認(最大120s)

## 不足・リスク・改善案（優先度付き）

### P0（導入前に致命的）
**1. 失敗時ロールバック・原子性が皆無（half-installed状態を残す）**
- install.ps1は copy→.env→shortcut→prisma migrate→サービス登録/起動→ping を直列実行。途中失敗で既コピーのapp/~9GBモデル/.env/ショートカット/一部登録済みサービスが残る。再実行するとpreflightの「app already exists」「services already exist」でFailし、-Forceもuninstall.ps1もGUIから起動できず**非エンジニアは詰む**（＝今回の実障害）。
- 改善: install.ps1をトランザクション化（このrunの成果物を記録→失敗時に逆順自動クリーンアップ、storageは保護）。または「空dirへ新規展開→成功後にrename/切替」のstaging方式で原子的切替。最低でもGUI catchで「クリーンアップして再実行しますか？」→内部で`uninstall.ps1 -Silent`相当を呼ぶ。

**2. 未署名exe / SmartScreen対策ゼロ（採用の最大障壁）**
- 士業PCで初回DL時にSmartScreen全画面警告→非エンジニアは断念しがち。2024年以降**EVでも「初回から警告バイパス」は廃止**、OV/EVとも評判蓄積方式。現推奨はAzure Trusted Signing（OV相当・安価）。
- 改善: Azure Trusted SigningかOVで署名（build→package→sign→verify順厳守、後編集は署名破壊）。暫定緩和はSHA-256掲載＋「詳細情報→実行」の日本語スクショ手順、社内allowlist(Defender/Intune/WDAC)登録依頼。

**3. エラー/例外メッセージがローマ字・英語混在**
- 「Setup.exe no yokoni ... o hitotsu dake oite kudasai.」等ローマ字、install.ps1のFailは英語、SHA mismatchも英語。
- 改善: 顧客可視メッセージを自然な日本語に統一。各エラーに「①何が起きたか ②どうすればよいか ③サポート/ログ場所」の3点。技術詳細はログへ分離。

### P1（品質・信頼性に大きく影響）
**4. 多重起動防止なし** — Setup.exeにMutexなし。連打/2回起動で同時にサービス登録/robocopy/prisma競合。→`Mutex(true,"Global\\OTE-RAG-Setup")`＋install.ps1側ロックファイル。

**5. キャンセル手段なし＋長時間の不定進捗（フリーズ誤認）** — Marquee固定で~9GBコピー中ずっと不定、中断不能。「固まった」→電源断→half-install誘発。→キャンセルボタン（安全ロールバック連動）＋ステップ名/進捗/ETA。

**6. 「半成功」を「失敗」と誤表示** — ping 120s未応答でexit1だがサービスは起動済みが多い（初回モデルロードで遅いだけ）。GUIは全面「失敗」表示→顧客はアンインストールしがち。→終了コード段階化(0成功/3導入完了だが起動確認timeout/1失敗)＋「初回はモデル読込に数分」案内＋ping延長/バックグラウンド化。

**7. モデルがC:\ProgramData固定** — `-InstallRoot D:\`でもモデル~9GBは常にC:、展開tempもC:\OTR固定。preflightの20GB確認はInstallRootドライブのみ。→preflightでInstallRootドライブとC:を両方チェック。可能なら`-DataRoot`で格納先選択可(OLLAMA_MODELSは環境変数化済み)。

**8. 日本語/非ASCIIパスで.env破損** — `Render-Template -Encoding ascii`。日本語InstallRootでINSTALL_ROOT差込がascii化し文字化け→起動失敗。→.envをUTF-8(BOMなし)化、または非ASCII/空白を警告/拒否。

**9. -Force上書き時のデータ自動バックアップなし** — storageはbackup.ps1手動時のみ保護→顧客文書消失リスク。→上書き/アップグレード時はstorage自動タイムスタンプ退避。GUIに修復/アップグレードの明示フロー。

### P2（堅牢性・保守性）
10. サービス起動の部分失敗にロールバックなし（逆順stop/uninstall、WinSW多段onfailure検討）
11. サービス定義の記述ドリフト（LocalRAG-Ollama.xmlのdescriptionが「llm-jp/mxbai」と古い→gemma4/bge-m3へ。versions.lock突合CI）
12. `<depend>`は起動順であり準備完了ではない（Collector/Ollamaのヘルスチェック追加で初回timeout低減）
13. 冪等性・修復(repair)モードの明示化（GUI起動時に既存検出→新規/修復/アップグレード/アンインストール提示）
14. tar.exe/curl.exe依存の前提をpreflightで先に確認
15. アンインストールの完全性（C:\OTR tempや孤立物の掃除口）

## 主要出典
- [Code signing options — Microsoft Learn](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/code-signing-options)（EV即バイパス2024廃止、Azure Trusted Signing推奨、企業はDefender/Intune/WDAC/EDRも未署名ブロック）
- [Rollback Installation — Microsoft Learn](https://learn.microsoft.com/en-us/windows/win32/msi/rollback-installation)（MSIは失敗時自動ロールバックが既定）
- [Using MSI Rollback Actions — Revenera](https://www.revenera.com/blog/software-installation/i-take-it-all-back-using-windows-installer-msi-rollback-actions/)
- [Windows Installer Best Practices — Microsoft Learn](https://learn.microsoft.com/en-us/windows/win32/msi/windows-installer-best-practices) / [JP版](https://learn.microsoft.com/ja-jp/windows/win32/msi/windows-installer-best-practices)
- [Air-gapped deployment best practices — corvusintell](https://corvusintell.com/blog/secure-cloud/air-gapped-deployment-defense/) / [Elastic Air-gapped install](https://www.elastic.co/guide/en/elastic-stack/current/air-gapped-install.html)
- [WinSW User Guide — DeepWiki](https://deepwiki.com/winsw/winsw/3-user-guide)
- [UAC Self Elevation — Microsoft Q&A](https://learn.microsoft.com/en-us/answers/questions/918783/uac-self-elevation) / [Using Windows Installer with UAC](https://learn.microsoft.com/en-us/windows/win32/msi/using-windows-installer-with-uac)
- [ITmedia: インストーラ比較(JP)](https://atmarkit.itmedia.co.jp/fdotnet/vblab/compareinstaller/compareinstaller_01.html) / [UACのしくみ(JP)](https://learn.microsoft.com/ja-jp/windows/security/application-security/application-control/user-account-control/how-it-works)

## 要追加調査
- install.ps1途中失敗後の再実行挙動（実機再現）
- Azure Trusted Signingの日本の個人/法人での取得要件・年額
- LocalRAG-Collector.xmlのドリフト有無
- 実配布経路（USB/DL）でのMark-of-the-Web有無とSmartScreen初回体験
