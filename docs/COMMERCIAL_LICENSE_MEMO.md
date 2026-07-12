# 商用販売の可否メモ（LocalRAG）

- 作成: 2026-07-12（Claude）
- 目的: 本製品（LocalRAG）を**買い切りで商用販売してよい根拠**を、後から何度でも確認できるよう1枚にまとめる。
- 結論: **販売してよい。** 中核のAnythingLLMはMITライセンスで、MITは商用販売を明示的に許可している。要点はOS（Windows/Linux）ではなく「**Mintplex配布のDesktopアプリ（ビルド済みバイナリ）ではなく、MITソースから自分でビルドしたものか**」であり、本製品は後者に該当する。

---

## 1. よくある誤解の訂正

> 「Windows版のAnythingLLMは売れないが、Linux版なら売れる」——これは**誤り**。

分かれ目は**OSではない**。正しくは次の区別:

| 区分 | ライセンス | 商用再配布 |
|---|---|---|
| Mintplex配布の **Desktopアプリ（ビルド済みElectronバイナリ）** | 別途 Desktop App Terms（＋過去にRCE系脆弱性） | 改変・再配布は避けるべき |
| **ソースからビルドした self-hosted 版**（Docker / Windows native / Source いずれも） | **MIT License** | **可（本製品はこれ）** |

`TERMS_SELF_HOSTED.md` §1 は self-hosted 版として **「Docker, Desktop, or Source」** を列挙し、いずれもMIT扱いと明記している。つまりDocker/Windowsといった実行形態やOSは論点ではない。

## 2. 「Windows native版」は何者か（名前の混乱に注意）

本製品の「Windows native」とは **「Dockerなしで Windows 上で直接動く self-hosted ビルド」** の意味であり、**「AnythingLLM Desktop の Windows 版アプリ」ではない**。

- ビルド元: `Mintplex-Labs/anything-llm` の **GitHub MITソース**（fork `product/customer-rag-base`）を `C:\LocalRAG\src` で `yarn install`＋フロントエンドビルドし、Node.js / Ollama / WinSW と共に同梱（`windows-native/export-windows.ps1`）。
- Mintplex配布のDesktop Electronバイナリは**一切使用していない**。
- したがって「ソースからビルドした self-hosted 版」に該当し、**MITが適用され販売可能**。

## 3. 根拠（MITは販売を許可）

同梱の `LICENSES/AnythingLLM_LICENSE.txt`（＝fork本体の `LICENSE`）に、MIT本文として次がある:

> Permission is hereby granted, free of charge, to any person obtaining a copy of this software ... to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or **sell** copies of the Software ...

「**and/or sell**」が明記されており、**商用販売はライセンス上明確に許可**されている。条件は「著作権表示とライセンス文を同梱すること（attribution）」のみ。

## 4. 満たすべき義務と対応状況（すべて対応済み）

| 義務 | 対応 |
|---|---|
| AnythingLLMのMIT表示・著作権表示を残す | `LICENSES/AnythingLLM_LICENSE.txt` ＋ `NOTICE` 同梱済み |
| 同梱OSSの表示（Ollama=MIT / WinSW=MIT / Node.js=MIT系） | `LICENSES/Ollama_LICENSE.txt` / `WinSW_LICENSE.txt` / `Node.js_LICENSE.txt` 同梱済み |
| 同梱モデルの表示（**Qwen3-8B=Apache-2.0** / **bge-m3=MIT**） | `LICENSES/Apache-2.0_LICENSE.txt` / `BGE-M3_LICENSE.txt` ＋ `docs/MODEL_CARDS.md` |
| 第三者表示の集約 | `LICENSES/THIRD_PARTY_NOTICES.txt` |

補足: v1.1.0でLlama 3.1は不採用（`LICENSES/Llama-3.1-Community-License.txt` は旧構成の名残。現行同梱モデルはQwen3-8B＋bge-m3のみ。`docs/MODEL_CARDS.md`参照）。

## 5. 販売時に守ること（ライセンス以外の実務的注意）

1. **自社製品名で売る。** MITはコードの権利であり、"AnythingLLM" の名称・ロゴ等の商標は別。AnythingLLMブランドとして売らず、自社の製品名（例: Local RAG Pro）で提供する。
2. **外部LLMプロバイダを有効化しない。** OpenAI/Anthropic等を使うとその第三者規約が別途かかる（本製品はAPI許可リストで遮断済みなので該当しない）。
3. **CDN依存を持ち込まない。** AnythingLLMは既定embedder/reranker(ONNX)をMintplexのCDNから取得する場合があるが、本製品はbge-m3をOllama経由で同梱し、オフライン固定化済み（外部取得なし）。
4. **無保証。** MIT/TERMS §5の通り "as is"。販売時のEULA/サポート範囲は自社で定義する（`repos/voicevox-narration-pipeline` の購入者限定EULAと同様の整備を将来検討）。
5. **バージョン固定を維持。** 検証済みの組み合わせ（`versions.lock`）で配布する。

## 6. 引用元（一次情報）

- AnythingLLM `TERMS_SELF_HOSTED.md`（Docker/Desktop/Source すべてMIT、§5 Licensing）: https://github.com/Mintplex-Labs/anything-llm/blob/master/TERMS_SELF_HOSTED.md
- AnythingLLM リポジトリ（MIT License）: https://github.com/mintplex-labs/anything-llm
- 同梱のMIT本文（ローカル）: `LICENSES/AnythingLLM_LICENSE.txt`、fork `anything-llm/LICENSE`
- プロジェクト内の当初方針記録（Desktopバイナリ回避・ソースビルド本命）: `docs/anythingllm_customer_distribution_plan.md`（§ライセンス整理・比較表）

## 7. 再確認のしかた（将来の自分へ）

1. fork `anything-llm/LICENSE` が MIT のままか（`git -C anything-llm log -- LICENSE` で改変履歴も確認）。
2. 上記 `TERMS_SELF_HOSTED.md` のリンク先で、self-hosted＝MITの記述が維持されているか（Mintplexが将来ライセンス変更していないか）。
3. 配布物に `LICENSES/` と `NOTICE` が同梱され続けているか（`export-windows.ps1` / `export.sh` のコピー処理）。
4. 同梱モデルを変えたら本メモと `docs/MODEL_CARDS.md` のライセンス欄を更新する。
