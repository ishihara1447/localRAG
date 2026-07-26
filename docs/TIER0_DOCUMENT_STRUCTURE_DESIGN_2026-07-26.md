# 文書構造（目次・構成）対応 設計書 — Tier 0 / Tier 1

- 作成日: 2026-07-26
- 対象: OTE-RAG（`repos/localRAG`、AnythingLLM fork）
- 目的: 「この資料の目次・構成を教えて」に正しく答えられない問題の**実現性調査と設計**
- 本作業でのコード変更: **なし**（`anything-llm/` 配下は一切未変更。`git status` で確認済み）

> **本書の読み方**
> 各節の記述には次のラベルを付けている。混同しないこと。
> - **【実証】** … このセッションで実際にコードを読んだ／スクリプトを実行して確認した事実
> - **【推測】** … コードから論理的に導いたが未実行の内容
> - **【提案】** … 設計上の選択肢・方針（意思決定が必要）

---

## 0. エグゼクティブサマリ

| 項目 | 結論 |
|------|------|
| pdfjs `getOutline()` は動くか | **【実証】動く。ただし実物の防衛白書では中身が使い物にならない**（後述） |
| しおりを信頼できるか | **No。第一データ源にしてはいけない** |
| 最有力の構造抽出源 | **本文中に印刷された「目次ページ」のテキスト**（抽出品質が非常に良い）【実証】 |
| 本文見出しの正規表現検出 | **段組みPDFでは崩壊する**（縦組み見出しが1文字ずつ改行される）【実証】。プレーンテキストの規程集では極めて有効【実証】 |
| RAG経路の数 | **2ではなく実質7箇所**。過去事故の再発リスクは想定より大きい【実証】 |
| Tier 0 の再embed | **不要**（チャンク・embeddingを変えないため） |
| Tier 1 の再embed | **必須**（chunkHeader が埋め込みテキストに入るため）+ vector-cache 全削除も必要 |
| 工数 | Tier 0 = **21〜30人時**、Tier 1 = **追加 26〜38人時** |

---

## 1. 現状のPDF処理フロー（精読結果）

### 1.1 collector 側：`asPDF`

`anything-llm/collector/processSingleFile/convert/asPDF/index.js`

```
asPdf()
 └ new PDFLoader(fullFilePath, { splitPages: true })   … index.js:18
 └ docs = await pdfLoader.load()                        … index.js:24
 └ 空なら OCRLoader にフォールバック                     … index.js:26-33
 └ 各ページを pageContent[] に積む                       … index.js:35-46
 └ content = pageContent.join("")                       … index.js:58
 └ data = { id,url,title,docAuthor,description,docSource,
            chunkSource,published,wordCount,pageContent,
            token_count_estimate }                       … index.js:59-77
 └ writeToServerDocuments({ data, ... })                … index.js:79-83
```

**【実証】重要な発見**: `data` オブジェクト（`asPDF/index.js:59-77`）は
`writeToServerDocuments`（`collector/utils/files/index.js:120-152`）でそのまま JSON として
`storage/documents/custom-documents/*.json` に書かれる。ここに**任意のフィールドを足せる**。

### 1.2 ページ境界マーカー `\f<page>\f` の仕組み（7/22実装）

これは今回の設計で**流用可否を判断すべき先行事例**なので詳細に記す。

**挿入側**（`collector/processSingleFile/convert/asPDF/index.js:39-45`）:

```js
// LocalRAG: ページ境界マーカー(\f<page>\f)を各ページ先頭に挿入する。
// \f(フォームフィード)はPDF本文テキストにほぼ出現しないため衝突しない。
if (typeof pageNumber === "number")
  pageContent.push(`\f${pageNumber}\f`);
pageContent.push(doc.pageContent);
```

**回収側**（`server/utils/vectorDbProviders/lance/index.js:577-612`）:

1. `textSplitter.splitText(pageContent)` でチャンク化（`lance/index.js:575`）— **マーカーごと分割される**
2. 各チャンクを `/\f(\d+)\f/g` でページ区間に分解（`lance/index.js:583`）
3. 「そのチャンク内で最も文字数を占めるページ」を多数決で採用
4. マーカーが1つも無いチャンクは `runningPage`（直前に確定したページ）を継承
5. `s.replace(/\f\d+\f/g, "")` でマーカーを除去したクリーンテキストを埋め込む（`lance/index.js:611`）
6. 結果を `chunkPages[]` に保持し、チャンクmetadataの `pageNumber` に格納（`lance/index.js:630`）

**設計上の含意（この手法の流用可否）**

| 観点 | 評価 |
|------|------|
| collector→server へ**行位置に紐づく情報**を運ぶ搬送路として | **流用できる**。見出し位置も「本文中の特定オフセット」なので同じ形（例 `\x1e<level>|<title>\x1e`）で運べる |
| 除去タイミング | 埋め込み**直前**に除去するので、マーカーは embedding に混入しない。＝ **Tier 0/1 どちらでもマーカー方式は embedding を汚さない**【実証：`lance/index.js:611` が `embedChunks`（`:617`）より前】 |
| 文書レベル情報（目次全体）の搬送に使えるか | **使うべきでない**。目次は「位置」ではなく「文書全体の属性」。本文に埋めるとチャンク境界計算・文字数統計（`wordCount`）を汚す |
| 制御文字の選択 | `\f` は既に使用済み。追加するなら `\x1e`(RS) / `\x1d`(GS) などPDF本文に出ない制御文字。**ただし `separators`（`server/utils/TextSplitter/index.js:191`）に含まれないため、マーカー位置でチャンクが切れる保証はない**（`\f` 方式も同じ制約で、だから「多数決」にしている） |

> **【提案】** 目次（文書レベル）は `\f` 方式ではなく **`data` オブジェクトの新フィールド**で運ぶ。
> 各チャンクへの見出し付与（Tier 1）は `\f` 方式と同じマーカー方式が最適。

### 1.3 PDFLoader

`anything-llm/collector/processSingleFile/convert/asPDF/PDFLoader/index.js`

- pdfjs-dist **legacy build** を dynamic import（`PDFLoader/index.js:130-141`）。**【実証】実インストール版は 4.4.168**
- cMaps / standard_fonts を同梱パスから読む（`PDFLoader/index.js:39-44`）＝オフライン完結
- `getDocument()` → `pdf.getMetadata()`（`:66`）→ ページごとに `page.getTextContent()`（`:71`）
- Y座標（`item.transform[5]`）が変わったら `\n` を挿入して行を作る（`:77-88`）
- `normalizeJapaneseSpacing()` で日本語の字間空白を除去（`:22-33`, 適用は `:90`）
- **【実証】`pdf.getOutline()` は呼ばれていない。`getDestination` / `getPageIndex` も未使用**
  （`grep -rn "getOutline|getDestination|getPageIndex" server/ collector/` のヒットは
   `collector/utils/extensions/DrupalWiki/DrupalWiki/index.js:70,104` のみで、これは PDF と無関係な別名メソッド）

---

## 2. `getOutline()` の実証結果

### 2.1 検証環境

- 検証スクリプト: `/tmp/claude-1000/.../scratchpad/outline-probe.mjs`（使い捨て、リポジトリ外）
- 対象PDF: **`/home/ishihara1447/projects/fukugyo/repos/localRAG/fixtures/local/R07zenpen.pdf`**
  （令和7年版 防衛白書 前編、66MB、546ページ。既存の hakusho 評価で使用中のもの）
- pdfjs: `collector/node_modules/pdfjs-dist` = **4.4.168**、`legacy/build/pdf.mjs`
- 起動オプションは `PDFLoader/index.js:56-64` と完全に同一にした

### 2.2 結果（防衛白書）

```
pdfjs version: 4.4.168
numPages: 546
open time: 95ms
getOutline time: 5ms
OUTLINE: top-level items = 42
walk+dest resolve time: 8ms
total outline nodes: 42, page-resolved: 35, maxDepth(0-based): 0
```

**【実証】技術的には完全に動く。**

- `getOutline()` は **5ms** で返る（546ページ・66MBのPDFに対して）。コストは無視できる
- 返却アイテムのキー: `action, attachment, dest, url, unsafeUrl, newWindow, setOCGState, title, color, count, bold, italic, items`
- `dest` は `[{num, gen}, {name:"FitH"}, 806]` 形式の**間接参照**。
  `pdf.getPageIndex(dest[0])` で**ページ番号に解決できる**（35/42 が解決、8ms）
- 未解決 7件は `dest` が null または壊れているアイテム（"空白ページ" など）

### 2.3 致命的な問題：**タイトルが DTP のファイル名**

【実証】実際に取れたアウトラインの中身（抜粋）:

```
[d0] p.1   防衛2025_00_本冊表紙A_sh0301
[d0] p.5   防衛2025_0-2_目次_sh0301
[d0] p.11  防衛2025_02a_特集1_sh0301
[d0] p.44  防衛2025_1-1_sh0503_注意_sh0301
[d0] p.61  防衛2025_1-3_01-04_sh0503_注意_sh0301
[d0] p.523 防衛2025_6-2_索引_sh0301
[d0] p.null 空白ページ
```

- **人間が読める見出しではなく、InDesign 等の入稿ファイル名がそのまま入っている**
- **階層がフラット（maxDepth = 0）**。章・節の入れ子構造が一切ない
- 42件中 6件が「空白ページ」という無意味なエントリ

つまり **このPDFのアウトラインをそのまま出せば「目次を教えて」への回答は
`防衛2025_1-3_01-04_sh0503_注意_sh0301` の羅列になる**。現状の「答えられない」より悪い。

### 2.4 他PDFでの結果

- `fixtures/test-expense.pdf`（1ページ） → **`getOutline()` は `null`**【実証】
- `pdf.getPageLabels()` → **`null`**（防衛白書）【実証】。
  ＝ **印刷ページ番号（p.51）と PDF物理ページ（61）の10ページのズレを PDF から直接解決する手段がない**
- `pdf.getMetadata().info.Title` → **空文字列**【実証】。Creator/Producer は "Adobe Acrobat (64-bit) 25.1.20531"

### 2.5 結論

> **【実証に基づく結論】** `getOutline()` は「取れたら儲けもの」の**補助シグナル**であって、
> 第一データ源にしてはいけない。日本の行政文書PDFはDTP入稿ワークフローの都合で
> しおりタイトルが汚染されていることが実物で確認された（n=1 だが、防衛白書という
> 本プロダクトの主要評価対象での失敗なので重い）。
>
> **採用するなら必ず「品質ゲート」を通すこと**（§4.2）。

---

## 3. フォールバック手段の実証比較

### 3.1 手段A: 本文中の「印刷された目次ページ」を読む ← **最有力**

**【実証】** 防衛白書の目次は PDF物理ページ 5〜10 にあり、`PDFLoader` と同一の抽出ロジックで
**極めてきれいに取れる**（検証スクリプト `text-probe.mjs`）:

```
第1章概観
 1 グローバルな安全保障環境��������������35
 2 インド太平洋地域における安全保障環境 ��������36
第2章ロシアによる侵略とウクライナによる防衛
 1 全般������������������������41
第3章諸外国の防衛政策など
第1節米国������������������������51
 1 安全保障・国防政策�����������������51
 2 軍事態勢����������������������56
第2節中国������������������������60
...
第10節その他の地域など（中東・アフリカを中心に） ���� 160
```

**【実証】定量結果**（目次6ページ = PDF p.5-10 に対する正規表現）:

| パターン | ヒット数 |
|---------|---------|
| `^\s*第[0-9０-９]+章` | **29** |
| `^\s*第[0-9０-９]+節` | **57** |
| 「末尾がページ番号」の目次エントリ行 | **280** |

- リーダー罫線は `U+FFFD`（`�`）として抽出される。**単純に除去できる**【実証】
- **章見出し行にはページ番号が付かない**（`第1章概観` に数字なし）。パーサはページ番号必須にしてはいけない【実証】
- 生テキスト13,107字 → 罫線除去後 9,396字 ≈ **7,200トークン**【実証、日本語1.3字/token換算】
- 章・節レベルのみに圧縮すれば ≈ 90エントリ ≈ **1,500トークン**【推測、上記実測からの外挿】

**目次ページの自動特定ヒューリスティック【提案】**
1. 先頭30ページ以内、かつ
2. ページテキストに `目次` / `CONTENTS` / `もくじ` を含む、または
3. 「リーダー罫線（`U+FFFD` 連続 / `・{3,}` / `\.{3,}`）＋末尾数字」で終わる行が**そのページの5行以上**
   → 目次ページと判定し、連続する範囲を目次ブロックとする

**リスク**: 「資料編目次」（p.522）のような**第2の目次**を拾う。連続ブロック単位で扱い、
最も長いブロックを主目次とする、などの対処が要る【提案】。

### 3.2 手段B: 本文中の見出しを正規表現で検出

**【実証】段組み・縦組みPDFでは崩壊する。**

防衛白書 PDF p.61（＝印刷 p.51、「第1節 米国」の開始ページ）の実際の抽出結果:

```
第 
1 
節 
米国
...（本文）...
諸外国の防衛政策など
第
3 
章
51 
令和7年版 
防衛白書
```

見出し「第1節 米国」は **`第` / `1` / `節` / `米国` の4行にバラける**。
これは `PDFLoader/index.js:81-87` が Y座標変化で改行を入れる実装のため、
**縦組み・大サイズの見出しは1文字ごとに別行になる**（Y座標が全部違う）。
`normalizeJapaneseSpacing()`（`:22-33`）は改行をまたぐ空白を扱わないので救済されない。

**【実証】定量結果**（PDF p.60-100 = 本文41ページ、4,267行）:

| パターン | ヒット |
|---------|-------|
| `^第[0-9０-９]+節`（連結された形） | 19（すべて柱＝running header の `第1節米国`） |
| `^第[0-9０-９]+章` | **0** |
| 行が `第` だけ / `第 N` だけ | **85**（＝崩壊した見出しの破片） |
| 行が `章` / `節` だけ | **44**（同上） |

→ **本文からの章見出し検出は 0件**。誤検出（柱の重複）は19件。
**この経路は防衛白書クラスの組版PDFでは使えない。**

### 3.3 手段C: プレーンテキスト／規程集での条文検出 ← **有効**

**【実証】** `fixtures/scale/reg-*.txt`（架空社内規程10本、士業向けの想定顧客文書に近い）に対し
`^第[0-9０-９]+条（.+）$` で検出:

| ファイル | 検出条数 |
|---------|---------|
| reg-01-shugyo-kisoku.txt | 15 |
| reg-02-chingin.txt | 15 |
| reg-03-taishokukin.txt | 15 |
| reg-04-ikuji-kaigo.txt | 14 |
| reg-05-shutcho-ryohi.txt | 15 |
| reg-06-keicho-mimaikin.txt | 15 |
| reg-07-kojin-joho.txt | 15 |
| reg-08-bunsho-kanri.txt | 13 |
| reg-09-anzen-eisei.txt | 14 |
| reg-10-harassment.txt | 13 |
| **合計** | **144（取りこぼし0、誤検出0）** |

→ **1段組みのテキスト／Word由来文書では、正規表現による見出し検出は実用的。**

### 3.4 日本語文書の見出しパターン整理【提案】

優先度順（上ほど強い＝レベルが浅い）。**行頭アンカー必須**、行末に「ページ番号」or「なし」を許容。

| Lv | パターン（正規表現の骨子） | 例 | 備考 |
|----|------------------------|-----|------|
| 1 | `^第\s*[0-9０-９一二三四五六七八九十IVXⅠ-Ⅻ]+\s*(編\|部)` | 第Ⅰ部、第1編 | 白書・分厚い規程 |
| 2 | `^第\s*[0-9０-９一二三四五六七八九十]+\s*章` | 第3章 諸外国の防衛政策 | |
| 3 | `^第\s*[0-9０-９一二三四五六七八九十]+\s*節` | 第1節 米国 | |
| 4 | `^第\s*[0-9０-９一二三四五六七八九十]+\s*款` | 第2款 | 法令 |
| 5 | `^第\s*[0-9０-９一二三四五六七八九十]+\s*条(\s*の\s*[0-9０-９]+)?` | 第12条、第12条の2 | **規程集の主役** |
| 5' | `^[0-9]+(\.[0-9]+){1,3}[\s　]` | 3.2.1 適用範囲 | ISO/社内規程・技術文書 |
| 6 | `^[０-９0-9]+\s*[．.]?\s*\S` | 1. 目的 / １ 全般 | **誤検出源。番号付き箇条書きと区別不能** |
| 7 | `^[（(][0-9０-９一二三四五六七八九十]+[）)]` | （1）、(ア) | 同上、条文の号 |
| 8 | `^[■◆●○【]\S` | ■概要、【留意点】 | 実務文書で頻出 |
| — | `^別表(第[0-9０-９]+)?` / `^附則` / `^様式第` | 別表第1、附則 | 規程集の末尾構造 |

**誤検出を抑える必須ガード【提案】**
- 見出し行は**短い**（例: 60字以下）。長い行は本文とみなす
- 見出し行は**句点「。」で終わらない**
- Lv6/Lv7 は**単独では採用しない**。上位（章・節・条）が既に1つ以上検出された文書でのみ子として採用
- 同一文字列が**3回以上出現**するものは柱（running header）とみなして除外
  （§3.2 の `第1節米国` × 19 がまさにこれ）
- 番号の**連番性チェック**: `第1条 → 第2条 → 第3条` と単調増加しない検出は捨てる。
  これが最も強力なフィルタ【提案】

---

## 4. 設計

### 4.1 全体方針

```
                     ┌─ (A) 印刷目次ページのパース  ← 最優先・最も信頼できる
collector/asPDF ─────┼─ (B) getOutline()             ← 品質ゲート通過時のみ
                     └─ (C) 本文/プレーンテキストの見出し正規表現 ← 1段組み文書で有効
                              │
                              ▼
                    docStructure(JSON) を data に付与
                              │
      ┌───────────────────────┴────────────────────────┐
      ▼                                                ▼
 workspace_documents.metadata            （Tier 1）\x1e マーカーで本文に埋め込み
 （文書レベル・チャンクに入れない）        → chunkHeader として各チャンク先頭に付与
      │                                                │
      ▼                                                ▼
 構成クエリ時に systemPrompt / contextTexts に注入   embedding が変わる＝全再embed必須
```

**採用順（1文書につき1回だけ決定）【提案】**

1. (A) 印刷目次ページが見つかり、エントリ数 ≥ 5 → **(A) を採用**
2. (A) が空で、(B) が品質ゲート（§4.2）を通る → **(B) を採用**
3. どちらも駄目 → **(C)** を実行。連番チェックを通ったエントリ数 ≥ 3 なら採用
4. すべて駄目 → `docStructure = null`。構成クエリには「この文書には目次情報が含まれていません」と正直に返す

### 4.2 `getOutline()` 品質ゲート【提案】

§2.3 の実測を踏まえ、以下を**全部**満たすときのみアウトラインを採用する:

- [ ] エントリ数 ≥ 3
- [ ] タイトルが**拡張子・アンダースコア連番パターンでない**
      （`/^[\w\-]+_[\w\-]+_[\w\-]+$/` や `/\.(indd|pdf|ai|psd)$/i` を弾く）
- [ ] タイトルに**日本語または英単語のスペース区切り**が含まれる（＝人間が読む語）
- [ ] 「空白ページ」「表紙」「奥付」等の定型ノイズを除外した残数 ≥ 3
- [ ] `dest` からページ解決できた比率 ≥ 70%

**防衛白書はこのゲートで落ちる**（`防衛2025_00_本冊表紙A_sh0301` はアンダースコア連番パターン）。
**それが正しい挙動。**

### 4.3 `docStructure` のスキーマ【提案】

```jsonc
{
  "source": "printed-toc",        // "printed-toc" | "pdf-outline" | "heading-regex" | null
  "confidence": 0.9,               // 0..1
  "tocPages": [5, 10],             // printed-toc のとき、PDF物理ページ範囲
  "pageOffset": 10,                // 印刷p.51 = PDF p.61 のズレ（推定できれば）
  "entries": [
    { "level": 2, "title": "第3章 諸外国の防衛政策など", "printedPage": null, "pdfPage": 61 },
    { "level": 3, "title": "第1節 米国",                 "printedPage": 51,   "pdfPage": 61 },
    { "level": 4, "title": "1 安全保障・国防政策",        "printedPage": 51,   "pdfPage": 61 }
  ],
  "truncated": false
}
```

- `entries` は**上限 500 件**で打ち切り（`truncated: true`）。防衛白書で実測280件なので十分【実証ベース】
- `pageOffset` は「目次のエントリのprintedPageに一致する印刷ページ番号を本文から探す」ことで推定できる【推測】。
  失敗したら `null`。**`getPageLabels()` は null を返すので使えない**【実証】

### 4.4 保存先：`workspace_documents.metadata`（**スキーマ変更不要**）

**【実証】ここが本設計で最も重要な発見。**

`server/models/documents.js:120-126`:

```js
const { pageContent: _pageContent, ...metadata } = data;
const newDoc = {
  docId, filename, docpath, workspaceId,
  metadata: JSON.stringify(metadata),   // ← pageContent 以外の全フィールドが入る
};
```

つまり **collector の `data` に `docStructure` を足すだけで、
Prisma のマイグレーションなしに `workspace_documents.metadata` に永続化される。**
`schema.prisma:36` の `metadata String?` は自由形式のJSON文字列カラム。

**ただし同時に踏んではいけない罠がある【実証】**

`server/utils/vectorDbProviders/lance/index.js:528`:

```js
const { pageContent, docId, ...metadata } = documentData;
```
→ `lance/index.js:626-631` で
```js
metadata: { ...metadata, text: textChunks[i], ...(chunkPages[i] != null ? { pageNumber: chunkPages[i] } : {}) }
```

**`docStructure` をそのまま `data` に足すと、全チャンク行に目次JSON丸ごとが複製される。**
防衛白書なら約1,000チャンク × 7KB ≈ 7MB の無駄＋LanceDB のスキーマ肥大。

さらに `lance/index.js:447-456 updateOrCreateCollection` は
既存テーブルには `collection.add(data)` するだけで、**スキーマは最初の `createTable` で確定する**。
既存 namespace に新フィールド付きの行を追加すると **LanceDB のスキーマ不一致で落ちる可能性が高い**【推測、未実行】。

> **【提案】必須の対策**: `addDocumentToNamespace` の冒頭
> （`lance/index.js:528` 直後）で `docStructure` を metadata から**明示的に除外**する。
> ```js
> const { pageContent, docId, docStructure: _ds, ...metadata } = documentData;
> ```
> **これを忘れると本番の既存ワークスペースが壊れる。設計レビューの最重要チェック項目。**

なお `curateSources`（`lance/index.js:783-797`）はチャンクmetadataをそのまま
フロントの引用に渡すので、この観点でもチャンクに載せるべきでない。

### 4.5 構成クエリの判定（クエリルーティング）

#### 既存の先例

**【実証】** 本リポジトリには既にクエリを条件分岐させる機構がある:
`server/utils/chats/queryReformulation.js`（156行）。

- env gate: `QUERY_REFORMULATION=true`（**既定OFF**）
- 発動条件: 検索スコアが閾値未満のときだけ（`searchIsWeak`, `:36-41`）
- 非破壊: 元の検索結果を減らさない（`:120-140`）
- **`stream.js` と `apiChatHandler.js` の双方から呼ばれることを冒頭コメントで明記**（`:15`）

**この設計パターンをそのまま踏襲すべき。**

#### 判定方式の比較【提案】

| 方式 | 誤爆リスク | レイテンシ | 判定 |
|------|-----------|-----------|------|
| **A. 正規表現/キーワード** | 中 | 0ms | **推奨（Tier 0 初版）** |
| B. LLM 分類（1トークン返答） | 低 | +0.5〜2s | 将来の改善 |
| C. 埋め込み類似度（構成クエリ例文との cos） | 中 | +50ms | 過剰 |

**方式A のトリガ語彙案**

```
肯定: 目次 / もくじ / 構成 / 章立て / 全体像 / 何章 / いくつの章 /
      どんな項目 / 見出し一覧 / アウトライン / 概要を教え(?!.*について) /
      条文一覧 / 何条まで / どんな条文
条件: 上記に該当 かつ 文が短い（40字以下）かつ 固有名詞的な検索語を含まない
```

**誤爆リスクの具体例と対策**

| 誤爆しうる質問 | 問題 | 対策 |
|--------------|------|------|
| 「第3章の**構成**はどうなってる？」 | 章単位の構成＝部分。全体目次を返すと的外れ | 「第N章/節/条」を含む場合は**構成モードに入るが範囲を絞る**（Tier 0 初版では通常RAGに落とす） |
| 「育児休業の**概要**を教えて」 | 内容質問。目次を返したら大失敗 | 「概要」単独ではトリガしない。「〜の概要」形は除外 |
| 「文書管理規程の**目次**」 | 複数文書があるワークスペースでどの文書か曖昧 | **文書特定が必要**（§4.6） |
| 「この資料、全部で何ページ？」 | 構成ではなくメタ質問 | 別ハンドラ or 通常RAG |

> **【提案】誤爆を許容できる設計にする**
> 構成モードでも**通常のtop-k検索結果は捨てず併記**する（queryReformulation と同じ非破壊思想）。
> 構成情報を `contextTexts` の**先頭に追加するだけ**にすれば、
> 誤爆しても「余計な目次が context に入る」だけで、回答が壊れない。
> これなら判定精度が7割でも実用に耐える。

#### 対象文書の特定【提案】

構成クエリは「どの文書の」構成かを決める必要がある。優先順:

1. `searchDocumentIds`（UI の文書スコープ指定。`stream.js:181-191` で既に実装済み）があればそれ
2. ピン留め文書（`DocumentManager.pinnedDocs()`, `server/utils/DocumentManager/index.js:29-68`）があればそれ
3. ワークスペースの文書が **1件だけ**ならそれ
4. 複数あり特定不能 → **通常のtop-k検索を実行し、上位ソースが属する文書**の構成を出す
5. それも駄目 → 「どの資料の構成を知りたいですか？」と文書名一覧を返す

### 4.6 注入方法【提案】

構成モード発動時、`contextTexts` の**先頭**に以下を積む
（`stream.js:263` の `contextTexts = [...contextTexts, ...filledSources.contextTexts]` の直前）:

```
<document_structure source="printed-toc" title="令和7年版 防衛白書">
第Ⅰ部 わが国を取り巻く安全保障環境
  第1章 概観
  第2章 ロシアによる侵略とウクライナによる防衛
  第3章 諸外国の防衛政策など
    第1節 米国 … p.51
    第2節 中国 … p.60
    ...
</document_structure>
```

**トークン予算の実測に基づく制約【実証】**

`runtime/docker-compose.yml:119` → `OLLAMA_MODEL_TOKEN_LIMIT=8192`
`server/utils/AiProviders/ollama/index.js:60-62` → user（＝contextTexts）配分は **0.7 = 約5,734トークン**

- 防衛白書の**目次全文は約7,200トークン**【実証】→ **そのままでは入らない**
- 章・節レベルまでに圧縮すれば約1,500トークン【推測、280エントリ→90エントリの外挿】

> **【提案】** `docStructure` を注入する際は**レベル打ち切りを動的に行う**。
> level 1→2→3… と順に足していき、予算（既定 2,000 トークン）を超える直前で止め、
> 末尾に `（第4階層以下は省略）` を付ける。**この予算管理を実装しないと gemma4 の context を溢れさせて既存の回答品質を壊す。**

### 4.7 既存RAG経路への影響 — **経路は2つではなく7つ**

**【実証】`performSimilaritySearch` の呼び出し箇所を全列挙した:**

| # | ファイル:行 | 用途 | Tier 0 対応要否 |
|---|-----------|------|---------------|
| 1 | `server/utils/chats/stream.js:194` | **UI のストリーミングチャット（主経路）** | **必須** |
| 2 | `server/utils/chats/apiChatHandler.js:323` | 外部API `chatSync`（**評価スクリプトが叩く経路**） | **必須** |
| 3 | `server/utils/chats/apiChatHandler.js:713` | 外部API `streamChat` | **必須** |
| 4 | `server/utils/chats/openaiCompatible.js:97` | OpenAI互換API `chatSync` | 推奨 |
| 5 | `server/utils/chats/openaiCompatible.js:333` | OpenAI互換API `streamChat` | 推奨 |
| 6 | `server/utils/chats/embed.js:108` | 埋め込みウィジェット | 顧客配布では未使用の想定。要確認 |
| 7 | `server/endpoints/api/workspace/index.js:995` | `vector-search` エンドポイント（検索のみ） | 不要 |
| (8) | `server/utils/chats/queryReformulation.js:101` | 内部再検索（1〜6から呼ばれる） | 不要 |

> **【警告】** 「stream.js と apiChatHandler.js の2経路」という前提は**不正確**。
> `apiChatHandler.js` は **2箇所**あり、さらに `openaiCompatible.js` にも 2箇所ある。
> **同じコードを6箇所にコピペする設計は再発事故を100%起こす。**

**【提案】必須の構造対策**

`queryReformulation.js` と同じく **1つの共有モジュールに切り出し、各経路は1行呼ぶだけ**にする。

```
server/utils/chats/documentStructure.js   ← 新規（唯一の実装）
  ├ isStructureQuery(message)          … 判定
  ├ resolveTargetDocument({...})       … 対象文書特定
  └ buildStructureContext({...})       … 予算内に収めた文字列を返す or null
```

各経路には次の**2行だけ**を挿入する（`contextTexts` 組み立ての直前）:

```js
const structCtx = await buildStructureContext({ workspace, message: updatedMessage, searchDocumentIds, budgetTokens: 2000 });
if (structCtx) contextTexts.unshift(structCtx);
```

さらに**回帰テストで全経路を叩く**こと。既存の `scripts/hakusho-eval.py` は
経路#2（`apiChatHandler.chatSync`）を使っているはずなので、
**UI経路（#1）は自動テストで守られていない**点に注意【推測、スクリプト未精読】。

### 4.8 Tier 1（各チャンクへの見出しパンくず付与）への拡張性

**【実証】受け皿は既に存在する。** `server/utils/TextSplitter/index.js:135-147`:

```js
stringifyHeader() {
  let content = "";
  if (!this.config.chunkHeaderMeta) return this.#applyPrefix(content);
  Object.entries(this.config.chunkHeaderMeta).map(([key, value]) => {
    if (!key || !value) return;
    content += `${key}: ${value}\n`;
  });
  ...
  return this.#applyPrefix(`<document_metadata>\n${content}</document_metadata>\n\n`);
}
```

現在は `TextSplitter.buildHeaderMeta(metadata)`（`lance/index.js:572`）が
`sourceDocument` / `published` / `source` を返し、**全チャンクに同一のヘッダ**が付く。

**Tier 1 で必要な変更点【推測】**

1. ヘッダを**チャンクごとに可変**にする。現状 `RecursiveSplitter`（`TextSplitter/index.js:173-205`）は
   コンストラクタで固定の `chunkHeader` を受け取り、`createDocuments(..., { chunkHeader })` で
   一括付与している（`:196-201`）。**チャンクごとに変える構造になっていない**ため、
   `_splitText` の改修が要る（例: `chunkHeader` に関数を許容する）
2. collector 側で見出し位置マーカー `\x1e<level>|<title>\x1e` を本文に挿入
   （`\f` マーカーと同じ手法。`asPDF/index.js:39-45` の隣）
3. `lance/index.js:577-612` の `\f` パース処理と**同じ場所で** `\x1e` もパースし、
   各チャンクの「直前に有効な見出しスタック」を計算 → パンくず文字列を作る
4. **マーカー除去は必ず embedding 前**（`lance/index.js:611` と同じ位置）

**注意点【実証】**
- `chunkHeader` は `splitText` の**戻り値に含まれる＝そのまま `embedChunks`（`lance/index.js:617`）に渡る**。
  → **見出しパンくずは embedding ベクトルに影響する＝全文書の再embedが必須**
- `EMBEDDING_MODEL_MAX_CHUNK_LENGTH=500`（`runtime/docker-compose.yml:133`）。
  **実効チャンクサイズは1000ではなく500字**（`TextSplitter.determineMaxChunkSize` が min を取る、`TextSplitter/index.js:47-56`）。
  パンくず「第Ⅰ部 > 第3章 諸外国の防衛政策など > 第1節 米国」で約30字＝**本文の6%を消費**する。
  無視できない。パンくずは**最下位2レベルに切り詰める**べき【提案】
- **`server/utils/files/index.js:177-189` の vector-cache**（`storage/vector-cache/<uuid5>.json`）は
  ファイル名をキーに**チャンクごと丸ごとキャッシュ**する。`lance/index.js:534-552` でキャッシュヒット時は
  再チャンク化を一切せずそのまま投入する。
  → **Tier 1 デプロイ時は vector-cache を全削除しないと古いチャンクが復活する**

---

## 5. 工数見積もり

### Tier 0 — 構成クエリ対応のみ

| # | 作業 | 人時 |
|---|------|-----|
| T0-1 | 目次ページ検出＋パーサ（`collector/utils/docStructure/tocParser.js` 新規） | 5〜7 |
| T0-2 | `getOutline()` 取得＋品質ゲート（`PDFLoader` 改修 + 判定） | 2〜3 |
| T0-3 | 正規表現見出し検出（規程集・txt/docx向け、連番チェック含む） | 3〜4 |
| T0-4 | `asPDF/index.js` / `asTxt` 等への配線・`data.docStructure` 付与 | 1.5 |
| T0-5 | **`lance/index.js:528` で `docStructure` をチャンクmetadataから除外**（必須・小さいが致命的） | 0.5 |
| T0-6 | `server/utils/chats/documentStructure.js` 新規（判定・文書特定・予算内整形） | 4〜5 |
| T0-7 | 6経路への2行挿入（#1〜#6）＋ env gate `DOC_STRUCTURE_QUERY=true` | 1.5 |
| T0-8 | 既存文書の再取り込み手順書＋バックフィルスクリプト（`docStructure` は既存文書に無い） | 2 |
| T0-9 | テスト（防衛白書・規程集10本・アウトライン無しPDF・誤爆ケース） | 3〜5 |
| | **合計** | **22.5〜29.5 人時** |

**再embed: 不要。**
理由【実証】: チャンク分割ロジック（`lance/index.js:575`）にも
埋め込みテキスト（`lance/index.js:617` に渡る `textChunks`）にも一切触れないため。
`docStructure` は `workspace_documents.metadata`（SQLite）にのみ載る。

**ただし「再取り込み」は必要**: 既存文書の `metadata` には `docStructure` が無い。
- 選択肢1: 対象文書だけ再アップロード（**embedding は vector-cache ヒットで再計算されない** — `files/index.js:177-189`）
- 選択肢2: バックフィルスクリプトで `storage/documents/**/*.json` を読み直して
  構造抽出 → `workspace_documents.metadata` を UPDATE（**ベクトルに触らない＝最も安全**）【提案】

### Tier 1 — 各チャンクへの見出しパンくず付与

| # | 作業 | 人時 |
|---|------|-----|
| T1-1 | 見出し位置マーカー `\x1e` の挿入（collector、行オフセット計算含む） | 4〜5 |
| T1-2 | `lance/index.js` でのマーカーパース＋見出しスタック管理（`\f` 処理と統合） | 5〜7 |
| T1-3 | `RecursiveSplitter` をチャンク別ヘッダ対応に改修（`TextSplitter/index.js:173-205`） | 4〜6 |
| T1-4 | パンくず長制御（500字制約下での切り詰め） | 2 |
| T1-5 | **全文書の再embed運用**（vector-cache 全削除 → 再投入 → 検証） | 3〜4 |
| T1-6 | 精度回帰評価（hakusho 30問 / ambiguous 15問 / scale 精度）**再実行必須** | 6〜10 |
| T1-7 | 精度が下がった場合のロールバック手順整備 | 2 |
| | **合計** | **26〜38 人時** |

**再embed: 必須。**
理由【実証】: `chunkHeader` は `RecursiveSplitter._splitText`（`TextSplitter/index.js:194-204`）で
チャンク本文に連結され、その文字列がそのまま `EmbedderEngine.embedChunks(textChunks)`
（`lance/index.js:617`）に渡る。**埋め込み対象テキストが変わる。**
加えて `storage/vector-cache/` の**全削除**が必要（`files/index.js:177-189`, `lance/index.js:534-552`）。

---

## 6. リスクと未検証事項

| # | 内容 | 深刻度 |
|---|------|-------|
| R1 | **`docStructure` をチャンクmetadataから除外し忘れると、既存 LanceDB テーブルへの `add()` がスキーマ不一致で失敗しうる**（`lance/index.js:447-456`）。未実行検証【推測】 | **高** |
| R2 | 目次パーサの検証サンプルが**防衛白書1本のみ**。日本の行政文書PDF全般に一般化できるかは未検証 | 高 |
| R3 | 印刷ページ番号↔PDF物理ページのオフセット（実測10）を解決する汎用手段が無い（`getPageLabels()` は null）【実証】。出典 `p.51` 表示との整合が崩れる | 中 |
| R4 | 6経路への横展開漏れ。**共有モジュール化しないと必ず起きる** | 中 |
| R5 | 構成クエリ判定の誤爆。§4.6 の「非破壊注入」で被害は限定できるが、トークン予算は消費する | 中 |
| R6 | gemma4:12b の実効 context が **8192**（`docker-compose.yml:119`）と小さく、目次注入の余地が狭い【実証】 | 中 |
| R7 | Tier 1 の再embed後に既存ベンチ（hakusho 27〜28/30、ambiguous 15/15）が**劣化する可能性**。改善保証はない | 中 |
| R8 | OCR経路（`asPDF/index.js:26-33`）を通った文書は構造情報を一切取れない | 低 |
| R9 | `scripts/hakusho-eval.py` 等がどの経路を叩いているか未精読。UI経路の自動テストが無い可能性【推測】 | 低 |

---

## 7. 推奨アクション

1. **まず T0-1（目次ページパーサ）だけを単体で作り、防衛白書＋顧客想定文書2〜3本で精度を測る。**
   ここが駄目なら Tier 0 全体が成立しないので、最初に潰す。
2. **`getOutline()` は「品質ゲート付きの第2候補」として実装する。第一候補にしない**（§2.3 の実証結果）。
3. **`lance/index.js:528` の除外は設計レビューの必須チェック項目**として明記する（R1）。
4. **共有モジュール化を先に決める**。6経路コピペは禁止（§4.7）。
5. Tier 1 は Tier 0 の効果を測ってから判断する。**再embed＋全ベンチ再実行のコストが大きく、
   核心仮説A検証（撤退基準 2026-08-15）より優先すべきではない。**

---

## 付録: 本調査で使用した検証スクリプト

いずれも scratchpad（リポジトリ外）に置いた使い捨て。リポジトリには一切追加していない。

- `outline-probe.mjs` — `getOutline()` / `getDestination()` / `getPageIndex()` の実証
- `text-probe.mjs` — `PDFLoader` と同一ロジックでの指定ページテキスト抽出
- `labels.mjs` — `getPageLabels()` / `getMetadata()` の実証

再現するには、`collector/node_modules/pdfjs-dist` の legacy build を
`PDFLoader/index.js:56-64` と同じオプションで開けばよい。
