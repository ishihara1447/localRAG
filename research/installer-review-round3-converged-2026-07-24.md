# OTE-RAG Installer 収束確認レビュー (Round3)
調査日: 2026-07-24 / 担当: researcherサブエージェント(収束確認)

## 結論
**installerは収束(スコープ外項目を除く)。** 残る実行可能なP0/P1は無し。

## ① Round2指摘の解消状況(全解消)
| 指摘 | 状態 |
|---|---|
| P1-A exit3ブラウザ | ✅ startupTimedOut時は生URLでなく`InstallRoot\LocalRAG.html`をFile.Existsガードで起動 |
| P1-B Mutex多重起動防止 | ✅ 自己昇格ブロックの後にMutex取得、!createdNewで情報ダイアログ+return、GC.KeepAlive保持 |
| P1-C C:容量チェック | ✅ InstallRoot非C:時のみsysDrive 12GB確認(C:なら二重回避) |
| P2-2 EstimatedSize | ✅ $DataRoot\models加算 |
| P2-3 英語WARN | ✅ VRAM/ショートカット/ARPを日本語化 |
| P2-4 storage退避明示 | ✅ 退避先を失敗メッセージに表示「文書は<退避先>\storageに保管(消えていません)」 |
| P2-5 rollbackプロセスkill | ✅ Stop-LocalRagProcesses(パス限定)+サービス消滅30秒待ちをInstallRoot削除前に配置 |
| -Forceガード | ✅ preExistingでrollbackがInstallRoot削除/storage退避をスキップし案内 |

## ② 残る実行可能なP0/P1
**なし。** exit境界・rollback armタイミング・preExistingガード・kill→消滅待ち→削除順序いずれも論理的に妥当。

## ③ 新規リグレッション
致命なし。将来メモ(P2以下・対応任意):
- `Stop-LocalRagProcesses`の`procPath.StartsWith($root)`は前方一致のため理論上`C:\LocalRAG`が`C:\LocalRAG2\...`に一致しうる。厳密化するなら`$root + '\'`。実害はほぼ無し。
- 失敗時GUIの`C:\OTR\<ts>`展開先は意図的残置(繰返し失敗で微量累積)。

## 総括
Round1のP0(失敗時ロールバック不在)から3ラウンドで、原子性・冪等性・非エンジニアUX(日本語化・矛盾しない完了案内)・多重起動防止・データ保全(storage退避+明示)・ロック回避まで塞ぐべき穴は全て対応。残るはスコープ外のコード署名(別トラック・要ユーザー判断)等の意思決定事項のみ。
