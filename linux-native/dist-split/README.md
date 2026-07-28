# OTE-RAG（Linux版）分割ファイルの受け取りと結合

配布物は約12GBあり、GitHub Releases の1アセット上限（2GiB）を超えるため、
約1.77GiB ずつに分割してアップロードしています。

このディレクトリには次のものが入っています。

| ファイル | 内容 |
|---|---|
| `ote-rag-linux-x64-vX.Y.Z.tar.gz.001` 〜 | 分割された配布物 |
| `MANIFEST.txt` | 元ファイルと各パートの SHA-256、元サイズ |
| `join.sh` | 結合＋検証スクリプト（Linux 用） |

## 手順

1. **すべてのパートと `MANIFEST.txt` `join.sh` を同じディレクトリへ置く**
   （1つでも欠けると結合できません。パート数は `MANIFEST.txt` に書いてあります）

2. **結合する**

   ```bash
   bash join.sh
   ```

   `join.sh` は次を自動で行います。

   - パート数の確認
   - 各パートの SHA-256 検証（壊れているパートだけを特定できます）
   - 連結
   - 復元後のファイル全体の SHA-256 検証

   途中で失敗した場合は、表示されたパートだけを再ダウンロードして
   もう一度 `bash join.sh` を実行してください。

3. **展開する**

   ```bash
   tar -xzf ote-rag-linux-x64-vX.Y.Z.tar.gz
   cd ote-rag-linux-x64-vX.Y.Z
   ```

4. **導入手順は展開先の `INSTALL_GUIDE.md` を読む**
   （まず `bash survey-target.sh` で前提条件を確認します）

## 手作業で結合する場合

`join.sh` が使えない環境では、次のコマンドでも結合できます。
ただし SHA-256 の検証は自分で行ってください。

```bash
cat ote-rag-linux-x64-vX.Y.Z.tar.gz.0?? > ote-rag-linux-x64-vX.Y.Z.tar.gz
sha256sum ote-rag-linux-x64-vX.Y.Z.tar.gz   # MANIFEST.txt の「元SHA-256」と一致すること
```

Windows 端末で受け取った場合は、7-Zip で `.001` を右クリック →「展開」でも結合できます
（`.001` 連番は 7-Zip が分割書庫として認識します）。
