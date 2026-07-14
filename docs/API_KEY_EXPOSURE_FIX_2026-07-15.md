# APIキー漏洩脆弱性の修正（2026-07-15）

## 発見の経緯

Codexがハイブリッド検索の実機検証（`docs/HYBRID_SEARCH_LINUX_VERIFY_RESULT_2026-07-15.md`）の後処理確認で、`GET /api/system/api-keys` が認証なしでAPIキー一覧とsecretを平文で返すことを発見。ハイブリッド検索とは無関係の、独立した脆弱性。

## 根本原因

1. `server/utils/middleware/validatedRequest.js`: シングルユーザーモード（本製品の既定運用形態）で、管理者が**パスワードを設定していない**（`AUTH_TOKEN`未設定）場合、認証チェックを完全にバイパスする（upstream AnythingLLMの元設計。個人PCでの信頼境界を前提）。
2. `server/utils/boot/index.js`（`bootHTTP`/`bootSSL`）と `collector/index.js`: `app.listen(port, callback)` で **host未指定**。Node/Expressはこの場合**暗黙に0.0.0.0（全ネットワークインターフェース）へバインド**する。

**この2つが重なると**: 顧客がオンボーディングでパスワードを設定しなければ、**同一LAN上の誰でも** `http://<顧客PCのIP>:3001/system/api-keys` にアクセスするだけでAPIキーのsecretを盗める。盗んだキーで文書チャット等のフルAPIが叩ける。

本製品は「士業向け・単一PC専用」（`INSTALL_GUIDE.md`: 「通常の利用者はブラウザで`http://localhost:3001`を開くだけ」）で、内部Ollamaポート（11435）は既に127.0.0.1限定という設計思想が既にあったにもかかわらず、メインサーバー（3001）とcollector（8888）だけがLANに開いていた、という一貫性の欠如でもあった。

## 修正

**サーバーの既定バインド先を127.0.0.1（このPC自身）に限定**。パスワード設定の有無に関わらず、そもそもLAN経由で到達できなくする（多層防御・かつ既存の設計思想「127.0.0.1=このパソコン自身」との統一）。

- `server/utils/boot/index.js`: `bootHTTP`/`bootSSL` に `BIND_HOST = process.env.SERVER_HOST || "127.0.0.1"` を追加し、`.listen(port, BIND_HOST, ...)` に。
- `collector/index.js`: 同様に `COLLECTOR_BIND_HOST = process.env.COLLECTOR_HOST || "127.0.0.1"`（サーバー用の`SERVER_HOST`とは別変数。Docker配布でサーバーだけを公開してもcollectorが巻き込まれて公開されないようにするため）。
- `server/utils/collectorApi/index.js`: サーバー→collector間の接続先を、未定義動作の `http://0.0.0.0:8888`（upstreamのハック）から `http://${COLLECTOR_HOST || "127.0.0.1"}:8888` に変更。0.0.0.0への接続はプラットフォームで動作が保証されないため。
- `runtime/docker-compose.yml`: サーバーは`SERVER_HOST=0.0.0.0`を明示（ポート公開`3001:3001`に必要）。collectorは同一コンテナ内通信のみなので未設定のまま127.0.0.1既定を使う。
- `windows-native/config/server.env.template` / `collector.env.template`: `SERVER_HOST`/`COLLECTOR_HOST`は**意図的に未設定**のまま（コード既定の127.0.0.1が適用される）。

## 検証

Docker環境で、別コンテナ（同一Dockerネットワーク・別ネットワーク名前空間）から実際に到達性をテスト:

| 対象 | 到達性 |
|---|---|
| server:3001（`SERVER_HOST=0.0.0.0`、Docker公開ポート） | ✅ 届く（設計通り） |
| collector:8888（既定127.0.0.1） | ❌ 接続不可（HTTP 000）＝**修正が機能している** |

Windows native配布は`SERVER_HOST`/`COLLECTOR_HOST`とも未設定のため、server(3001)・collector(8888)の**両方**が127.0.0.1限定になる（上記collectorと同じ遮断効果）。

RAG E2E回帰: `scripts/rag-e2e-test.sh` **PASS=11 FAIL=0**（server→collector間通信を127.0.0.1経由に変更した後も、アップロード・embedding含め全項目成功）。

## 残課題（フォローアップ候補、未実施）

- 今回の修正はネットワーク到達性を断つ多層防御。**パスワード未設定時に認証を丸ごとバイパスするvalidatedRequestの設計自体**は温存（upstreamの仕様）。オンボーディングでパスワード設定を必須化するかは、UX変更を伴う大きめの判断のため別途相談が必要。
- `/system/api-keys` がsecretを平文で返す設計（`ApiKey`テーブルも平文保存）自体は upstream 標準仕様のまま。今回はネットワーク層での遮断を優先。

## 影響範囲

未コミット。fork（server/collector/collectorApi）＋localRAG（compose・env template）。次のv1.2.0再ビルドに含める。
