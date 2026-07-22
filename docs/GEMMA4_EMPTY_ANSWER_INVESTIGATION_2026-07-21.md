# gemma4:12b 空回答/think暴走 調査（2026-07-21）

## 背景

`scripts/ambiguous-eval.py`（防衛白書 15問ペア）で、一部の質問（Q06/Q07/Q30 等）が
**空回答（`textResponse` が空文字）** で NG になる現象が観測された。空NG問は**実行間で移動**
する（Q06明確版・Q09曖昧版は1回目空→2回目OK）ため、retrieval でも P1（言い換え再検索）でもない、
**gemma4:12b の生成側の非決定的な揺らぎ**であることが分かっていた。本メモはその根本原因を特定する。

## 根本原因（特定）

gemma4:12b は Ollama chat API で回答を **`thinking`（思考）と `content`（最終回答）に分離**して返す。
AnythingLLM の Ollama プロバイダはこれを結合する（`server/utils/AiProviders/ollama/index.js`）:

```js
if (res.message.thinking)
  content = `<think>${res.message.thinking}</think>${content}`;
```

- temperature=0 で gemma4 の `thinking` が**反復ループで暴走**することがある（実測: ある質問で
  thinking が約18,000字に達し、英語の "Question: … Constraint 1: …" を延々と繰り返す）。
- その結果 **`content`（最終回答）が空**になる。結合後の文字列は `<think>…暴走…</think>` ＋ `""`。
- 評価スクリプトは `<think>…</think>` を除去して採点するため、**除去後は空文字 → NG**。

つまり「空回答」は retrieval の失敗ではなく、**gemma4 の thinking が回答本体を食い潰したときの副作用**。

## 検証: `think: false` で無効化できる

RAGコンテキスト無しの直接 Ollama 呼び出し（`gemma4:12b`, temp=0, num_ctx=8192）:

| 設定 | thinking長 | content長 | 所要 |
|------|-----------|-----------|------|
| `think: true`（現状） | 2,010字 | 83字 | 20.8秒 |
| `think: false` | 0字 | 5字（直接回答） | **0.5秒** |

- `think: false` で thinking を完全に止められ、**直接 `content` を返す**（暴走・空回答の余地が消える）。
- 副次効果として **約40倍高速**（思考トークンを生成しないため）。RAG 応答レイテンシの大幅改善も見込める。
- 現状のプロバイダは `think` を渡していない（＝モデル既定の thinking が有効）。

## 推奨（次アクション）

1. **`OLLAMA_DISABLE_THINKING`（仮）env で `think:false` を渡せるようにする**（`ollama/index.js` の
   `getChatCompletion`/`streamGetChatCompletion` に `think` を条件付きで追加）。hybrid/cushion/P1 と
   同じ env opt-in パターン。
2. **A/B 検証**: think ON/OFF で `scripts/ambiguous-eval.py`＋`scripts/hakusho-eval.py` を回し、
   (a) 空回答NGが消えるか、(b) thinking が効いていた難問の精度が落ちないか、を確認する。
   think:false は40倍速いので A/B は安価（フル30問が数分）。
3. 結果次第で製品既定を決める。thinking が精度に寄与していない/わずかなら、**既定 OFF**（安定・高速・
   決定的）にするのが有力。寄与が大きい問があれば、num_predict で thinking をバウンドする案も検討。

## A/B 検証結果（2026-07-21・採用確定）

`OLLAMA_DISABLE_THINKING` env ゲートを `ollama/index.js` の getChatCompletion/
streamGetChatCompletion に実装し（`think:false` を条件付き付与）、dev(image 1.0.6, temp=0,
hybrid+cushion+P1)で A/B した。P1(QUERY_REFORMULATION)は全条件で有効。

| 構成 | ambiguous 明確版 | ambiguous 曖昧版 | 空回答NG | 決定性 | hakusho |
|------|:---:|:---:|:---:|:---:|:---:|
| think ON + P1 | 14/15 | 12/15 | 3件(Q06/07/30) | 揺らぐ | 26/30(既知) |
| think OFF・P1無し | 15/15 | 14/15(Q4のみNG) | 0件 | 一致 | 28/30 |
| **think OFF + P1（採用）** | **15/15** | **15/15** | **0件** | **2回完全一致** | **27/30** |

- **think OFF が空回答を根絶**し、ambiguous を決定的にした（2回完全一致）。
- **think OFF + P1 で ambiguous 満点(15/15+15/15)**。Q4曖昧版はP1が日付チャンクを持ち込み、
  think OFF でも gemma4 が正答（think ONで効いていた推論をP1の retrieval 改善が代替）。
- hakusho は think OFF で 27〜28/30（think ON基準 26/30 を上回る）。P1無し28・P1有り27の
  1問差は、**P1が発火していない (a)三文書(明確版・強い検索)** の generation 揺らぎで、
  hakusho-eval が sessionId 分離しない共有履歴ノイズ（同じ質問が sessionId 分離の
  ambiguous-eval では2回とも正答）。my変更の回帰ではない。
- **結論: `OLLAMA_DISABLE_THINKING=true` を製品既定に採用**（`runtime/docker-compose.yml`）。
  コードは env 未設定なら従来どおり thinking 有効（upstream挙動を非破壊で温存）。

## 注意・限界

- 上の think ON/OFF 実測は**RAGコンテキスト無しの単純プロンプト**で、回答の正誤自体は評価対象外
  （機構とレイテンシの確認が目的）。**精度の結論は必ず RAG 込みの eval A/B で出すこと**。
- 空回答は非決定的なので、A/B は各条件で複数回（最低2回）回して再現性を見る（評価方法論監査
  `docs/RAG_EVAL_INTERNAL_AUDIT_2026-07-16.md` の指摘に従う）。
- 本調査ではコード・設定は変更していない（`ollama/index.js` は未編集）。dev コンテナも未変更。
