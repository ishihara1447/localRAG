# 最新プログラムの修正反映状況（2026-07-28）

## 結論

修正は次の3層で状態が異なる。

| 層 | 状態 | 判定 |
|---|---|---|
| ソース（`anything-llm`） | 設定メニュー整理、直接URLガード、顧客向けprovider allowlist、完全オフライン強化が実装済み | **反映済み** |
| Windows配布候補 v1.2.7 | 2026-07-28作成。新しいfrontend bundleとオフライン強化コードを同梱 | **同梱確認済み** |
| 現在のインストール先 `C:\LocalRAGProd` | `versions.lock` は v1.2.5、build_date は 2026-07-24。bundleも 2026-07-23生成 | **未反映** |

したがって、現在Windows上で動いている実体は最新ではない。最新状態を実機で確認するには、v1.2.7を使ったクリーンインストールが必要である。

## 確認した最新ソース

ルートリポジトリの最新コミットは次のとおり。

- `833ade6`（2026-07-28 10:35）: v1.2.7 Release Notes追加、README版数更新
- `ab424c9`（2026-07-28 09:56）: OCR言語データ同梱、完全オフライン設定、古いfrontend bundle検出の改善

`anything-llm` 側の製品改修ブランチでは、次のコミットが最新の主要実装である。

- `2e61181d`: 設定画面を顧客向けallowlistに整理し、直接URLを案内画面で遮断
- `48c68662`: リランカー、OCR、ローカルWhisperの外部モデル／CDN取得を既定で禁止

### ソースで反映済みの内容

1. 設定サイドバーを顧客向けallowlistに整理
   - LLM、埋め込み、LanceDB、チャンク設定、ワークスペース、UI、チャット、イベントログ、APIキー等を残す
   - Community Hub、Telegram、Agent Skills、Scheduled Jobs、Browser Extension、Mobile App等を隠す
2. 非対応設定の直接URLアクセスを遮断
   - `PrivateRoute`で「この配布版では利用できません」を表示
3. providerをサーバー側でも制限
   - LLM: `ollama`
   - embedding: `ollama`
   - Vector DB: `lancedb`
   - 旧環境の `native` embedding は、復旧可能性のため起動時のみ警告付きで許容。保存時の選択肢には含めない
4. 完全オフライン強化
   - Transformers.jsのリモートモデル取得を既定OFF
   - OCRの言語データをローカル固定
   - Whisperのモデル取得を既定OFF
   - 同梱モデル不足時は黙って精度を落とさず、日本語警告を出す

## v1.2.7配布物の確認

確認対象:

- [OTE-RAG-win64-v1.2.7.zip](C:/LocalRAG/dist/OTE-RAG-win64-v1.2.7.zip)
- [OTE-RAG-Setup.exe](C:/LocalRAG/dist/OTE-RAG-Setup.exe)
- [v1.2.7展開ディレクトリ](C:/LocalRAG/dist/OTE-RAG-win64-v1.2.7)

実測値:

- ZIPサイズ: `11,023,848,322` bytes
- ZIP作成時刻: `2026-07-28 10:16:17`
- Setup作成時刻: `2026-07-28 10:16:35`
- frontend `server/public/_index.html`: `2026-07-28 10:02:22`
- frontend `server/public/index.js`: `2,789,012` bytes、`2026-07-28 10:02:22`
- SHA-256: `8ead6ea1b8ec1aba2aedee685c1dcf703c3945c6fee682e2024ca24367b8f618`
- `.sha256`記載値との一致: **一致**

bundle内に次の文字列を確認した。

- 直接URL遮断画面: `この配布版では利用できません`
- 製品名: `OTE-RAG Windows版`

また、配布物の次のサーバー／collectorファイルに、オフライン強化実装の主要な識別子を確認した。

- `server/utils/EmbeddingRerankers/native/index.js`
- `server/utils/EmbeddingEngines/native/index.js`
- `server/utils/boot/verifyBundledAssets.js`
- `server/utils/helpers/transformersOffline.js`
- `collector/utils/OCRLoader/index.js`
- `collector/utils/WhisperProviders/localWhisper.js`

## 現在のインストール先との比較

`C:\LocalRAGProd\versions.lock` の実測値:

```text
package_version=1.2.5
build_date=2026-07-24T13:16:42+09:00
node=v22.20.0
ollama=0.31.2
models=bge-m3:latest, gemma4:12b
reranker=onnx-community/bge-reranker-v2-m3-ONNX (int8)
```

インストール済みfrontend bundleは `2026-07-23`生成で、次の最新修正識別子を含まなかった。

- `この配布版では利用できません`: **未検出**
- `OTE-RAG Windows版`: **未検出**
- `system/local-services`: **未検出**

一方、旧bundleには上流由来の `Model Router`、`Community Hub`、`Scheduled Jobs`等の文字列が残っている。これは表示制御が反映された最新bundleではなく、旧v1.2.5が起動対象になっていることと整合する。

## 未完了・未検証

次の項目は、ソースまたは配布物への同梱確認だけでは完了扱いにできない。

1. v1.2.7を実機へクリーンインストールし、実ブラウザでスパナメニューを確認
2. 非対応設定URLが案内画面になることを確認
3. Ollama / Ollama / LanceDB以外のproviderをAPI経由で保存できないことを確認
4. ネットワーク遮断状態で、資料取込、検索、出典付き回答を通す
5. OCR、リランカー、音声認識の同梱モデル不足時のエラー表示を実機確認
6. TTS/STTのサーバー側allowlist化（現状はUI非表示・URLガードまで。API/env直接編集による外部provider保存は未解消）
7. ワークスペース設定内のAgent Configurationタブを残すかどうかの製品判断

なお、v1.2.7のRelease Notesにも「実機のオフライン環境での通しテストは未実施」と記載されている。

## 次の推奨作業

1. 現在の `C:\LocalRAGProd` を停止し、関係ファイルだけをバックアップまたは削除
2. `OTE-RAG-win64-v1.2.7.zip` のSHA-256を再確認
3. `OTE-RAG-Setup.exe`でクリーンインストール
4. 実ブラウザのメニュー、直接URL、provider一覧を確認
5. ネットワーク遮断下でRAGの最小E2Eを実施
6. 結果をWindows実機検証レポートとして追記

この確認では、インストール済みの旧版を削除・変更していない。
