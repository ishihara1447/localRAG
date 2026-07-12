# 会社PCへの配布・導入手順（GitHub Release + 分割方式）

配布zip（`LocalRAG-win64-v1.1.0.zip`、約8.3GB）は、単一のモデルblobが5.2GBあり
**GitHubの通常git（1ファイル100MB）にもGit LFS（1ファイル2GB）にも収まらない**。
そのため zip を 2GB 未満に分割して **GitHub Release のアセットとして添付**し、
会社PCでダウンロード→結合→インストールする。

- リポジトリ（このスクリプト群・小さい）: `git@github.com:ishihara1447/localRAG.git`
- 大きいバイナリ（分割zip）: GitHub Release `v1.1.0-demo` のアセット

## 配布物の構成（Releaseアセット）

| ファイル | 内容 |
|---|---|
| `LocalRAG-win64-v1.1.0.zip.part00` 〜 `part04` | 分割された配布zip（各 約1.9GB、計5本） |
| `LocalRAG-win64-v1.1.0.zip.sha256` | 結合後のzip全体のSHA256（改ざん・破損検知用） |

## 会社PC側の手順

### 前提（満たさないと動かない）
- **NVIDIA GPU（RTX 5070 Ti / VRAM 16GB級）+ 最新ドライバ** ← 必須。無いとインストーラが停止する
- Windows 11（または Win10 21H2+）、空きディスク約30GB、管理者権限
- ポート 3001 / 8888 / 11435 が空いていること

### 手順
1. **スクリプトを取得**（どちらか）
   - `git clone https://github.com/ishihara1447/localRAG.git` して `localRAG\windows-native\deploy\` を使う
   - または Release ページから `deploy` 配下2ファイル（`Join-And-Install.cmd` / `join-and-install.ps1`）と `..\verify\install-demo.ps1` を手動ダウンロード
2. **分割zipをダウンロード**（どちらか）
   - Releaseページで `part00`〜`part04` と `.sha256` をブラウザで1つずつダウンロード（`gh`不要）
   - または `gh release download v1.1.0-demo -R ishihara1447/localRAG -p "LocalRAG-win64-v1.1.0.zip.*"`
3. **結合＋インストール**
   - `Join-And-Install.cmd` をダブルクリック → UAC承認
   - 分割zipを手順1と別フォルダ（例: ダウンロード）に置いた場合は
     `Join-And-Install.cmd -PartsDir C:\Users\<自分>\Downloads` のように指定
   - スクリプトが: パート結合 → SHA256検証 → 展開 → インストール（サービス3本をRunningで常駐）
4. **動作確認**: ブラウザで `http://localhost:3001` を開き、ワークスペース作成→文書アップロード→日本語で質問

### 後片付け（アプリを消す）
```powershell
cd C:\LocalRAG
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

## GPU要件について（重要）

インストーラ（`install.ps1`）は冒頭で **`nvidia-smi` の有無と VRAM 16GB を強制チェック**する。
- NVIDIA GPUが無い → その場で停止（回避不可）
- VRAMが16GB未満 → 警告して停止（`-Force`で続行はできるが低速）

これは本製品の中核リスク「**仮説D: 対象事務所は本当にこのクラスのGPUを持っているか**」に直結する。
一般的なオフィスPC（内蔵GPUのみ）では動かない。会社PCがこの要件を満たすことを事前に確認すること。

## 開発機側（配布物の作り方・メモ）

```bash
# 1. 8.3GB zip を 1900MiB ずつ分割し、全体のSHA256を出す
cd /mnt/c/LocalRAG/dist
sha256sum LocalRAG-win64-v1.1.0.zip > LocalRAG-win64-v1.1.0.zip.sha256
split -b 1900m -d LocalRAG-win64-v1.1.0.zip LocalRAG-win64-v1.1.0.zip.part

# 2. GitHub Release を作成し、パート5本＋.sha256 を添付（要 gh 認証）
gh release create v1.1.0-demo -R ishihara1447/localRAG \
  --title "LocalRAG v1.1.0 (demo build)" --notes "Round2 PASS build. See windows-native/deploy/README.md." \
  /mnt/c/LocalRAG/dist/LocalRAG-win64-v1.1.0.zip.part* \
  /mnt/c/LocalRAG/dist/LocalRAG-win64-v1.1.0.zip.sha256
```
