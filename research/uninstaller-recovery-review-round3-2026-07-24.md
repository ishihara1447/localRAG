# OTE-RAG アンインストーラ / 回復動線 Round3収束確認
調査日: 2026-07-24 / 担当: researcherサブエージェント

## ① Round2指摘の解消状況
| 指摘 | 状態 |
|---|---|
| R-1 rollbackプロセスkill(最重要) | ✅ install.ps1にStop-LocalRagProcesses、Invoke-Rollbackでkill+サービス消滅30秒待ちをInstallRoot削除前に配置 |
| P1-A -Force既存環境巻き込み | ✅ preExistingでrollbackがInstallRoot削除/storage退避スキップ+案内 |
| R-4 uninstall個別try/catch | ✅ 各削除を個別try/catch化(ただし下記P1-αの副作用が新たに顕在化) |
| P1-B ARP EstimatedSize | ✅ models加算 |
| R-3 ping失敗時の状態ログ | ⚠ 未対応(任意・低) |

Mutex/exit3ランチャー/C:容量チェックも妥当でリグレッションなし。

## ② 残るP1(1件)→ Round3で修正済み
**P1-α(データ安全性・R-4修正の副作用)**: keep-data(既定)でstorageのMove-Itemがロックで失敗すると、R-4の個別try/catchでWARN継続し、後続のapp一括削除で顧客文書(app\server\storage)を削除/迷子にしうる。R-4以前はErrorActionPreference=Stopで中断→storageは物理的に残っていた。
- **修正(Round3実施)**: 退避成否を`$storagePreserved`で追跡。keep-dataで退避失敗した場合、手順5でappフォルダを削除対象から除外(return)し「文書保護のため残した/手動削除を案内」。→ サイレント文書消失を防止。

## ③ 新規リグレッション
- 上記P1-αのみ(Round3で解消)。他は検出なし。
- 参考(スコープ外): -Force失敗時、preExistingガードはInstallRoot削除は抑止するがサービス解除/ショートカット/ARP削除は実行され半端な状態が残る。-Force=アップグレード経路(/MIRアップグレードとしてスコープ外)。Setup.exeは-Force未使用のため通常非発火。アップグレード正式実装時にrollback設計を見直す前提。

## 総括
Round2主要4点は解消。P1-α(データ安全性)をRound3で修正し、uninstaller/回復動線はスコープ外項目(署名・-Force /MIRアップグレード・QuietUninstall昇格)を除き収束見込み。
（追加ハードニング: Stop-LocalRagProcessesのStartsWithを末尾区切り付きに厳密化=install.ps1/uninstall.ps1両方。）
