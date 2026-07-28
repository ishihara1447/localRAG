# OTE-RAG 分割配布の手順

配布zipは約 **10.5GB** あり、GitHub にそのまま置けない（通常push 100MB / LFS 2GB / **Releasesアセット 2GB**）。
そこで **バイト分割**して GitHub Releases に置き、受け取り側で結合する。

> **方式: 素のバイト分割 ＋ `.001` 連番の命名**
> パート名を `.001` `.002` … にすることで、**7-Zip が分割書庫として自動認識**する。
> つまり **7-Zipがあれば .001 を右クリック → 展開** で結合でき、
> **7-Zipが無くても Windows標準の `copy /b`**（同梱の `Join-OTE-RAG.cmd`）で結合できる。
> どちらの経路でも復元でき、環境に依存しない。

---

## 送り出し側（ビルドしたマシン）

### 1. 分割する

```bash
cd /home/ishihara1447/projects/fukugyo/repos/localRAG
./windows-native/dist-split/split-release.sh /mnt/c/LocalRAG/dist/OTE-RAG-win64-v1.2.6.zip
```

`dist/parts/` に以下ができる。

```
OTE-RAG-win64-v1.2.6.zip.001 〜 .006        （各約1.77GB）
MANIFEST.txt                                 （全パート＋元ファイルのSHA-256）
Join-OTE-RAG.cmd                             （結合ツール）
README.md                                    （この文書）
```

### 2. GitHub Releases へアップロード

```bash
cd /home/ishihara1447/projects/fukugyo/repos/localRAG
gh release create v1.2.6 \
  --title "OTE-RAG v1.2.6" \
  --notes-file windows-native/dist-split/RELEASE_NOTES.md \
  /mnt/c/LocalRAG/dist/parts/* \
  /mnt/c/LocalRAG/dist/OTE-RAG-Setup.exe
```

**アップロードには時間がかかる**（10.5GB。回線速度次第で数十分〜数時間）。

---

## 受け取り側（インストールするPC）

### 1. すべてダウンロードする

Releases ページから **全パート**＋ `MANIFEST.txt` ＋ `Join-OTE-RAG.cmd` ＋ `OTE-RAG-Setup.exe` を
**同じフォルダ**にダウンロードする。

`gh` が使えるなら一括で取れる。

```powershell
gh release download v1.2.6 --repo ishihara1447/localRAG --dir C:\OTE-RAG-install
```

### 2. 結合する

**方法A（推奨・7-Zipがある場合）**
`OTE-RAG-win64-v1.2.6.zip.001` を **右クリック → 7-Zip → 展開**。
7-Zip が `.001` を分割書庫として認識し、残りのパートを自動で読んで結合する。

**方法B（7-Zipが無い場合／確実に検証したい場合）**
`Join-OTE-RAG.cmd` を**ダブルクリック**するだけ。管理者権限は不要。

- 全パートを `copy /b` で連結する
- **`MANIFEST.txt` の SHA-256 と照合**して壊れていないか検証する
- 一致しなければ結合ファイルを削除して再ダウンロードを促す

> **どちらでも結果は同じ**だが、**方法Bは SHA-256 検証まで自動で行う**。
> 10GBのダウンロードは途中で壊れることがあるため、**方法Bを推奨**する。
> 方法Aを使った場合も、あとから `Join-OTE-RAG.cmd` を実行すれば検証だけ行える。

### 3. インストールする

`OTE-RAG-Setup.exe` を **右クリック → 管理者として実行**。

---

## 🔴 会社PCで起きやすい問題

| 症状 | 原因と対処 |
|---|---|
| **「WindowsによってPCが保護されました」** | Setup.exe が**未署名**（コード署名証明書が無い）。「**詳細情報**」→「**実行**」で進める |
| **管理者として実行できない** | インストールには管理者権限が必須。IT部門の許可が要る場合がある |
| ダウンロードが遅い／途中で切れる | 10.5GBある。社内プロキシで大容量DLが制限されることがある。**パート単位で再取得できる**のが分割方式の利点 |
| ウイルス対策ソフトが隔離する | 未署名exeと大量のバイナリのため誤検知しうる。IT部門に除外を依頼 |
| **ディスク容量不足** | **合計 25GB以上の空き**が要る（分割10.5 + 結合後10.5 + 展開・インストール先） |

---

## ディスク容量の目安

| 段階 | 必要量 |
|---|---|
| 分割ファイルのダウンロード | 約 10.5GB |
| 結合後のzip（分割ファイルはこの時点でまだ残っている） | 追加で約 10.5GB |
| インストール先 `C:\LocalRAGProd` | 約 11GB |
| **ピーク時の合計** | **約 32GB**（結合後に分割ファイルを消せば約 21GB に減る） |

---

## 中身（10.5GBの内訳）

| 素材 | サイズ | 備考 |
|---|---|---|
| **Ollamaモデル**（gemma4:12b + bge-m3） | **8,311MB** | 全体の79%。オフライン動作のため同梱している |
| Ollamaランタイム | 1,889MB | CUDA含む |
| リランカー（bge-reranker-v2-m3 ONNX int8） | 561MB | |
| Node ランタイム | 99MB | |

**モデルを同梱しているのは「顧客文書を外部に送らない」という製品の中核要件のため。**
インストール時にネットワークから取得する方式なら約2.2GBまで小さくできるが、オフライン保証を失う。
