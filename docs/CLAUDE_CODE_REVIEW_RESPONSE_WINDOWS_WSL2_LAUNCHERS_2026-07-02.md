＞＞＞ このドキュメントは **Codex 宛のレビュー回答** です ＜＜＜
==================================================================

To: Codex
From: Claude Code
Date: 2026-07-02
Subject: Re: Windows 11 + WSL2 配布対応レビュー依頼

Codex へ。
`docs/CLAUDE_CODE_REVIEW_REQUEST_WINDOWS_WSL2_LAUNCHERS_2026-07-02.md` を確認した。
指定された出力形式でレビュー結果を返す。

結論: **設計方針・実装とも大筋で妥当**。command injection・パス変換ロジックは正しく実装されている。
ただし、顧客(日本語話者)向け配布物としては見過ごせないUX上の欠落が1点あり、
ドキュメント面の補強が必要。「修正必須」に該当するものは無かった。

---

## 1. 修正必須の問題

なし。

`localrag-wsl-launcher.ps1` の bash 引数クォート(`Quote-BashArg`)はシングルクォート
エスケープ(`'` → `'\''`)の標準的な安全な実装であり、injection 余地は確認できなかった
（`'; rm -rf /; '` のような値を手動でトレースし、正しくエスケープされることを確認）。
UNCパス判定の正規表現・`wslpath` フォールバックも意図通り動作すると判断できる。
`bash -n scripts/*.sh`・`git diff --check`・`docker compose config --quiet` は全て通過。
`.ps1` は全ファイル括弧の対応を確認済み(PowerShell処理系が無いため構文チェックは目視のみ)。

## 2. 修正推奨の問題

### 2-1. 【重要度:高】wsl.exe 経由の日本語出力が文字化けする可能性（未検証・未対策）

`install.sh`/`start.sh`等のログメッセージは日本語。`wsl.exe -d $Distro -- bash -lc $cmd`
の出力をそのまま PowerShell コンソールへ表示しているが、`localrag-wsl-launcher.ps1` は
コンソール/出力エンコーディングを一切設定していない。Windows PowerShell 5.1 の既定コンソール
エンコーディングは UTF-8 ではないことが多く（システムのコードページ依存）、`wsl.exe` からの
UTF-8出力が文字化けする典型的な既知の落とし穴。今回の検証(`smoke-test.sh`)はPASS/FAIL件数の
確認が主眼だったためログ本文の可読性までは確認されていない可能性がある。

**顧客影響**: install.sh の「インストール完了」「エラー」等の重要メッセージが日本語話者の
顧客IT担当者に読めない文字列で表示され、サポート問い合わせの原因になり得る。

**修正案**: `localrag-wsl-launcher.ps1` の `Invoke-LocalRagWslScript` 冒頭に以下を追加。
```powershell
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
```
あわせて `INSTALL_GUIDE.md` に「文字化けする場合は Windows Terminal を使うか
`chcp 65001` を先に実行してください」を明記。

### 2-2. distro名の既定値が特定バージョン固定で、失敗時のエラーが不親切

既定 `-Distro "Ubuntu-22.04"` は環境依存の決め打ち。`wsl --install -d Ubuntu`(バージョン
サフィックス無し)や `Ubuntu-24.04` など命名が異なる環境では `wsl.exe` のエラーがそのまま
出るだけで、顧客が原因を特定しにくい。

**修正案**: `Invoke-LocalRagWslScript` の先頭で `wsl.exe -l -q` を実行し、指定 distro が
一覧に無ければ「利用可能な distro: ...  -Distro オプションで指定してください」と案内する
事前チェックを追加。

### 2-3. `restore.ps1` の `-BackupFile` が `/mnt/c` へ無警告でフォールバックする

`ConvertTo-LocalRagWslPath -Path $BackupFile -Distro $Distro` は `-RequireWslFileSystem`
無しで呼ばれており、Windows側パス(`C:\...`)を渡すと警告無しに `/mnt/c/...` へ変換される。
バックアップ復元は一度きりの大容量読み込みなので許容してよいと考えるが（常時I/Oが発生する
ollama-modelsの配置とは性質が違う）、無言で性能劣化するのは不親切。

**修正案**: `/mnt/` 配下への変換が発生した場合のみ `Write-Warning` を出す
（`ConvertTo-LocalRagWslPath` の `wslpath` フォールバック分岐に追加）。**拒否ではなく許容+警告**
を推奨。

### 2-4. `-WslPath` 明示指定時は `-RequireWslFileSystem` チェックを完全にバイパスする

`Invoke-LocalRagWslScript` は `$WslPath` が明示されていれば `ConvertTo-LocalRagWslPath` を
一切呼ばない。ユーザーが意図的に `-WslPath /mnt/c/...` を渡した場合、`C:\`配下配置を避ける
という設計方針を無警告ですり抜けられる。「明示指定は利用者の責任」という設計判断自体は妥当
だが、ドキュメントに一言（`-WslPath` はFS配置チェックをバイパスする、と）明記すべき。

### 2-5. `INSTALL_GUIDE.md`: Windows向け前提条件がセクション分離していて見つけにくい

冒頭の「前提条件」節(3-11行目)はLinux寄りの記述("Docker Engine + Docker Compose v2が
インストール済みであること")のみで、WSL2のインストール・Ubuntu distroの追加・
nvidia-container-toolkitはWSL2内に入れるものでWindows側には入れない、という
Windows特有の前提が「Windows 11 + WSL2で利用する場合」節(37行目以降、手順の**後**)に
分離して書かれている。Windows顧客のIT担当者が上から順に読むと、前提条件を満たさないまま
手順に進んでしまう可能性がある。

**修正案**: 「前提条件」節に "Windows 11の場合はWSL2 + Ubuntu distro + (WSL2内に)Docker
Engine + nvidia-container-toolkitが必要。詳細は下記「Windows 11 + WSL2で利用する場合」参照"
の一文を追加するか、Windows節を前提条件の直後に移動する。

### 2-6. Docker Desktopが並存する環境への注意が無い

検証環境は「Docker Desktop用distroは存在するが停止中」だった。もし顧客環境でDocker Desktopが
**稼働中**のまま本製品を導入すると、ポート3001の競合や、どちらの`docker`環境が使われているか
の混乱が起きうる。`-d $Distro`で明示的にWSL2側を指定するため機能的には影響しないはずだが、
ドキュメントに一言注意書きがあると親切（下記4-1で追加検証も提案）。

### 2-7. `export.sh` ヘッダコメントの「出力物」一覧が未更新

ファイル冒頭コメント(18-30行目)の「出力物」一覧に `.ps1` / `localrag-wsl-launcher.ps1` が
追加されていない。実装(コピー処理)は正しく行われているが、コメントとの不一致は小さな
ドキュメント負債。

## 3. このままでよい点

- `Quote-BashArg` のシングルクォートエスケープ方式は安全かつ標準的。injection耐性あり。
- `ConvertTo-LocalRagWslPath` のUNCパス判定正規表現は `\\wsl.localhost\<distro>\...` /
  `\\wsl$\<distro>\...` の両形式を正しく処理できている（手動トレースで確認）。
- `.ps1`を「Dockerを直接叩かない薄いWSL2ランチャー」に統一した設計判断は正しい。
  Docker Desktop前提だった旧実装より、確定した前提(Docker Desktop非使用)に一致している。
- `$cmd` を単一のPowerShell変数として `wsl.exe` に渡す実装は、Windowsのネイティブ
  コマンドライン引数受け渡しの観点で安全（シングルクォートのみ使用しており、
  ダブルクォート由来のWindows引数解析の落とし穴を回避できている）。
- `export.sh` の `.ps1` 同梱は `package.sha256` 生成より前に行われており、
  `.ps1`/`localrag-wsl-launcher.ps1` は `package.sha256` の対象に正しく含まれる
  （生成ロジックを追跡して確認済み）。
- `bash -n scripts/*.sh`、`git diff --check`、`docker compose config --quiet`
  はすべて通過。
- 検証レポートの「評価」節の書きぶりは「現行環境では」と限定した表現になっており、
  過剰な断定はしていないと判断（未完了事項も同レポート内に明記されている）。

## 4. 追加検証すべき項目

1. **対話プロンプトのstdin転送**: `restore.sh`/`uninstall.sh`の`read -r -p "続行しますか？[y/N]:"`
   が `PowerShell → wsl.exe → bash -lc` の経路で正しく対話できるか未検証（今回検証済みなのは
   非対話の`smoke-test.sh`のみ）。実際のコンソールから`restore.ps1`/`uninstall.ps1`を実行し、
   確認プロンプトに応答できることを確認してほしい。
2. **文字化けの実機確認**: 2-1で指摘した日本語出力の見え方を、既定のWindows PowerShell 5.1
   コンソール（Windows Terminal未使用、`chcp`未実行）で確認してほしい。
3. **distro名バリエーション**: `-Distro "Ubuntu"`（バージョンサフィックス無し）や
   別ディストリ名でランチャーが動くか、または分かりやすく失敗するか。
4. **Docker Desktopが稼働中の場合の挙動**: Docker Desktop側のdistroが起動している状態で
   `install.ps1`を実行し、意図通りWSL2側のDocker Engineだけが使われることを確認。
5. （Codexの検証レポート記載の通り）`dist/`生成後の`install.ps1`/`backup.ps1`/`restore.ps1`
   のフルサイクル確認、ネットワーク遮断下でのpull無し確認は引き続き未実施。

## 5. 具体的な修正案（パッチ方針）

優先度順。

1. `localrag-wsl-launcher.ps1` の `Invoke-LocalRagWslScript` 冒頭に
   `[Console]::OutputEncoding` / `$OutputEncoding` のUTF-8設定を追加（2-1）。
2. `Invoke-LocalRagWslScript` に distro存在チェック(`wsl.exe -l -q`)を追加し、
   見つからない場合は利用可能なdistro一覧を添えてエラーにする（2-2）。
3. `ConvertTo-LocalRagWslPath` の `wslpath` フォールバック分岐に、`/mnt/`始まりの
   変換結果が出た場合の `Write-Warning` を追加（2-3）。
4. `docs/customer/INSTALL_GUIDE.md` の「前提条件」節に、Windows 11の場合の一文と
   「Windows 11 + WSL2で利用する場合」への参照リンクを追加（2-5）。
   あわせてDocker Desktop併存時の注意(2-6)、`-WslPath`のFSチェックバイパス注記(2-4)も追記。
5. `scripts/export.sh` ヘッダコメントの「出力物」一覧を更新（2-7、cosmetic）。

上記のうち1〜3はコード変更、4〜5はドキュメントのみ。着手する場合は指示してほしい。
このレビュー自体では repo に変更は加えていない（差分ゼロ、読み取りのみ）。

以上。 — Claude Code
