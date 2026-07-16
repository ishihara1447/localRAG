# 引き継ぎメモ（セッション間ハンドオフ）

最終更新: 2026-07-16（**文抽出クッションは有効と確定：baseline 18〜19 → cushion 24〜25（+6〜7、c)定義は2/6→6/6満点）。量子化int8で十分（fp16と同等）。ただし配布image 1.0.5にhybrid/cushionが未搭載＝配布ブロッカー、要image再ビルド**。加えて評価スクリプト全般のtemperature未固定・採点正規表現の脆弱性・統計的検定なしという構造的弱点が判明） / 次セッション開始時にまずこれを読む。

> **【評価方法論の監査＋クッション再検証 2026-07-15】文抽出クッションの目玉結果を撤回、評価プロセス自体に構造的欠陥**
> ユーザー指示で、これまでの防衛白書30問評価（19/30→22/30→24/30等の推移で語ってきた各種施策の効果）の妥当性をサブエージェント2体で監査・調査した。
> - **内部監査**（`docs/RAG_EVAL_INTERNAL_AUDIT_2026-07-16.md`）: 評価スクリプトが**temperature=0.7（既定値）のまま単発実行**されており、同一条件の再実行だけで19〜24/30とばらつくことをログから実測。n=30での点差の多くは二項検定で有意でない（p≈0.15〜0.37）。採点用正規表現の空白バグが2回連続発生し「生スコア→手動補正」が常態化。(d)不明応答判定に否定語を伴わない危険なパターンあり。**文抽出クッションのstandalone結果（19/30→29/30）はbaseline側temp=0.7・cushion側temp=0という条件不一致で比較されており、公平なA/Bになっていなかった**。
> - **外部調査**（`docs/RAG_EVAL_METHODOLOGY_RESEARCH_2026-07-16.md`）: RAGAS/DeepEval/ARES等の業界標準と比較し、キーワード採点の偽陰性・retrieval/generation評価の未分離・信頼区間なしの単発比較という3点で標準から乖離。日本語は表記ゆれで偽陰性リスクが英語以上に高い。オフライン制約下でもローカルLLM-as-judge（Prometheus 2, 7B, 16GB VRAM）等の改善余地あり。
> - **フェア再検証 → 訂正・確定**（`docs/RAG_SENTENCE_CUSHION_FAIR_REEVAL_2026-07-15.md`）: 当初「temperature固定でも改善なし（baseline 21 vs cushion 20）」と結論したが**これは誤り**だった。真因は**稼働コンテナ（image 1.0.5, 2026-07-12ビルド）のlance/index.jsが6/29の古い版で、hybridもcushionも実装ごと存在せず一度も動いていなかった**こと（`docker compose up -d`のたびイメージの古コードに戻っていた）。最新lance一式＋native(fp16対応)を`docker cp`＋`restart`で反映し（`scratchpad/apply_latest.sh`）、コンテナログでクッション発火を確認した上で3条件×2回を再測定：**baseline(cushion OFF) 18〜19 / cushion+int8 24〜25 / cushion+fp16 25**。→ ①**クッションは有効（+6〜7、c)定義 2/6→6/6満点）**、②**量子化int8で十分（fp16と同等、fp16はサイズ2倍レイテンシ2.4倍で見返りゼロ）**、③以前「効果なし」は環境欠陥による誤り。ユーザー当初の「リランカーをワンクッション挟む」着想が実測で裏付けられた。トレードオフ: d)白書外が5/5→4/5（厚生年金を「65歳」と捏造1件、要プロンプト対策）。
> - **【配布ブロッカー判明】image 1.0.5にhybrid/cushion未搭載**: docsは「hybrid既定ON確定」としているがビルド成果物には入っていない。顧客配布前に最新`lance/`一式＋`EmbeddingRerankers/native/index.js`を含めて**image再ビルド必須**（WSL2 DNS対策で`docker build --network=host`等）。hybrid・cushion双方のブロッカー。
> - **cushion実装の反映状況**: fork側ソースに`sentenceCushion.js`（新規）、`lance/index.js`にフック（L698）、`native/index.js`にRERANKER_QUANTIZED対応済み。`runtime/docker-compose.yml`は`LANCE_SENTENCE_CUSHION=true`（防衛白書等の長文向けに採用）。**実際に効かせるにはimage再ビルド必須**。
> - **【評価基盤改善 実施済み 2026-07-16】**: (a)プロンプト強化=数値の一般知識補完を禁じるルール8を`fixtures/local/prompt-tuned.txt`とfork`systemSettings.js`に追加（防衛白書で他カテゴリ非破壊を確認）。(b)評価ハーネス移設=`scratchpad/hakusho_eval30.py`→`scripts/hakusho-eval.py`（git管理, temperature=0固定・UNKNOWN否定形修正・(c)キーワード空白正規化）。`scale-eval.py`も同修正。(c)設問欠陥修正=(d)厚生年金設問を雇用保険失業給付へ差替（白書に「年金受給開始年齢である65歳」が実在し不明期待が誤りだった）。→ **cushion+int8+ルール8+設問修正で防衛白書26/30を2回完全再現（d)5/5・c)6/6安定）**。
> - **【士業ドメイン 未解決課題 2026-07-16】**: 士業30問(`scale-eval.py`)でcushion回帰を試みたが、a)が7→3に激変。原因はプロンプトでなく**scale-eval.pyが毎回新規ワークスペース作成+sleep(10)のみで評価に入り、embed/FTS sidecar構築が間に合わずretrieval不安定**なこと（防衛白書は既存WS再利用で安定）。→ ①ルール8の萎縮は明確に観測されず、②**cushionが短い規程集で核心数値を絞り落とすドメイン依存リスクは確定も否定もできず**。ユーザー判断で防衛白書主軸で確定・コミット、士業は課題記録。cushionの効果は当面**長文ドメインに限定して解釈**。
> - **今後の優先課題**: (1)cushion含めたimage再ビルド（配布ブロッカー解消）、(2)`scale-eval.py`のretrieval安定化（embed/sidecar待ちのポーリング化 or 既存WS再利用）→士業でcushion ON/OFFをフェア再検証、(3)evalセットの50〜200問拡張・retrieval hit-rate/MRRの自動計測・統計的有意性チェック（内部監査の中期課題）。

> **【モデル比較 2026-07-15】Phi-4 14B（Microsoft, MIT）を実測A/B → 不採用、gemma4:12b現状維持**
> 抽出精度の高さが期待できる非中国系候補として調査・実測（`docs/MODEL_EXTRACTION_ACCURACY_RESEARCH_2026-07-15.md`）。
> - 防衛白書30問: 15〜20/30（gemma4基準19〜21を下回る）、**(d)白書外(不明応答)が1/5〜4/5と2回とも崩壊**。
> - 士業30問: 22〜26/30（gemma4基準19〜25と同水準、(c)は5/5維持）。
> - **不採用の決め手**: 白書に無い設問で消費税率・最低賃金・年金保険料等の具体的数値を作り出し、**「出典：R07zenpen.pdf」等と実在文書からの引用であるかのように偽装**。士業でも存在しない条文番号を伴う架空引用が発生。gemma4の失敗（安全側の過剰拒否）より危険な失敗モードで、再現性あり（プロンプト調整未実施でも2回とも発生）。
> - 詳細: `docs/PHI4_AB_TEST_RESULT_2026-07-15.md`。devのphi4は削除済み、製品既定は最初から変更なし（gemma4:12bのまま）。

> **【セキュリティ修正 2026-07-15】APIキー漏洩脆弱性（`/system/api-keys`が認証なしでLAN越しに読める）**
> Codexが発見。原因は(1)シングルユーザーモードでパスワード未設定なら認証が丸ごとバイパスされる仕様(upstream)、(2)server(3001)・collector(8888)が`app.listen(port)`のhost省略で**暗黙に0.0.0.0(全インターフェース)にバインド**されていたこと。組み合わさると顧客がパスワード未設定の場合、同一LAN上の誰でもAPIキーを盗める。
> - **修正**: サーバー/collectorの既定バインド先を**127.0.0.1限定**に（内部Ollamaポート11435と同じ設計思想に統一）。`server/utils/boot/index.js`・`collector/index.js`に`SERVER_HOST`/`COLLECTOR_HOST`（既定127.0.0.1）を追加。server→collector間の接続も未定義動作だった`0.0.0.0`から`127.0.0.1`に修正（`collectorApi/index.js`）。Docker配布は`SERVER_HOST=0.0.0.0`を明示（ポート公開に必要、collectorは巻き込まない）。Windows native側は変数未設定のままで両方127.0.0.1になる。
> - **検証**: 別Dockerコンテナからの到達性テストでcollector(127.0.0.1)への接続が実際に拒否されることを確認（HTTP 000）。RAG E2E **11/11 PASS**（server→collector通信含め回帰なし）。
> - 詳細: `docs/API_KEY_EXPOSURE_FIX_2026-07-15.md`。残課題（パスワード必須化・secret平文保存の見直し）は別途判断。

> **【Linux検証完了 2026-07-15】日本語ハイブリッド検索（dense + BM25 + RRF）既定ON確定**
> 稼働中コンテナで修正版を検証。LanceDB query()の既定limit=10問題を修正した版でsidecar全1,748行を構築し、非核三原則・交戦権のBM25 retrievalは**2/2 PASS**。API出典にも正解チャンクが入り、残る回答失敗はgemma4の抽出問題と判定した。30問は生20/30だが、正答「約3万2,000円」を評価正規表現が取りこぼした27問目を内容補正すると**21/30**（baseline維持）、文書外5/5、RAG E2E 11/11 PASS。詳細=`docs/HYBRID_SEARCH_LINUX_VERIFY_RESULT_2026-07-15.md`。**ユーザー判断で既定ON確定**（`LANCE_HYBRID_SEARCH=true`）。私(Claude)が独自に同日実施したA/B（`docs/HYBRID_SEARCH_LINUX_VERIFY_RESULT_2026-07-14.md`）は採点用正規表現の不備で「retrieval 1/2・要退行」と誤判定していたため訂正済み。

> **【Codex実装・Linux検証済み 2026-07-15】日本語ハイブリッド検索（dense + BM25 + RRF）**
> 防衛白書でdense top30にも入らなかった「非核三原則」「交戦権」の2件を救うため、LanceDB 0.15へ日本語bi-gram BM25 sidecarとRRF融合を実装した。既存ベクトル表は変更せず、文書追加/削除・namespace削除へ追随し、`LANCE_HYBRID_SEARCH=true` のときだけ有効。FTS障害時はdenseへ自動フォールバックする。Linux/Windows nativeの一時DBプローブと防衛白書Linux E2EはPASS。実装記録=`docs/CODEX_HYBRID_SEARCH_IMPLEMENTATION_2026-07-14.md`、依頼=`docs/CLAUDE_CODE_REQUEST_HYBRID_SEARCH_LINUX_VERIFY_2026-07-14.md`。

> **【出荷前ハードニング課題 2026-07-15】APIキーsecretの未認証露出**
> `GET /api/system/api-keys` が認証なしでもAPIキー一覧とsecretを返すことを確認した。hybrid検索とは無関係の既存課題だが、顧客配布前の重大なセキュリティブロッカー。今回作成した一時キーは対象名を限定して削除済み、既存のHakusho系キーは変更していない。次のセキュリティ修正で認証必須化とsecret非返却を実装・検証する。

> **【根本改善 2026-07-14】日本語PDFの字間空白を正規化（検索精度の真因を修正）＋ num_parallel修正**
> 防衛白書546pでの精度評価中に2つの重要問題を発見・修正（`docs/JP_PDF_SPACING_FIX_2026-07-14.md` / `docs/MODEL_SELECTION_NON_CHINESE_2026-07-14.md`）:
> 1. **collector(pdfjs)が日本語の字間に空白を挿入**（"43兆円程度"→"43 兆円程度"）→ bge-m3の埋め込みが質問と一致せず検索漏れ。`PDFLoader/index.js`に`normalizeJapaneseSpacing()`追加（英単語間は保持）。実測: 正解事実のdense top8捕捉が **3/7→7/7**。topN調整・チャンク拡大・リランキングはいずれも無効で、真因は抽出テキストの空白だった。
> 2. **`OLLAMA_NUM_PARALLEL=4`でgemma4:12bが16GB GPUに載らずCPU転落**（26文字生成に134秒）→ 並列1に修正（compose＋`LocalRAG-Ollama.xml`）。1にすると8.1GB・GPU100%。
> - どちらもv1.2.0再ビルドに含まれる（collectorソース／設定）。**end-to-end再評価はdev image再ビルド後の再取り込みで確認**（9/16からの向上見込み）。fork `5649a7ec`。

> **【統合状況 2026-07-14】Codexのv1.2.0成果 ＋ gemma4切替 を1つの最終ビルドに合流させる**
> Codexとgemma4切替の作業を統合した結果、**出荷可能なv1.2.0まであと「最終再ビルド1回＋クリーン管理者検証」だけ**。
>
> **すでに揃っているもの（gitに取り込み済み）**:
> - Codex完了分: OTE-RAGリブランド＋日の丸favicon込みのv1.2.0ビルド、Round2自動検証**全PASS**（E2E 11/11・GPU・backup・stop/start・uninstall）、サービス制御バグ修正（`install.ps1`が`.env.production`も生成＝Web UIからのOllama/Collector制御が有効化）、export堅牢化。詳細: `docs/WINDOWS_NATIVE_VERIFY_V1.2.0_RESULT_2026-07-14.md`。
> - Claude完了分: LLMを gemma4:12b に切替（設定・export・MODEL_CARDS・調整プロンプト、下の【モデル切替】ブロック参照）。
>
> **未合流の一点**: Codexが検証したv1.2.0.zip（`C:\LocalRAG\dist\LocalRAG-win64-v1.2.0.zip`, 8.25GB）の**同梱LLMは qwen3:8b**（gemma4切替より前のビルド）。gemma4はまだパッケージに入っていない。
>
> **残作業（Codex、最終ビルド1回）**:
> 1. `C:\LocalRAG\src\server\models\systemSettings.js` を最新（gemma4調整プロンプト）に再同期、`windows-native\export-windows.ps1`（gemma4:12b同梱に更新済み）も再同期。
> 2. ビルドマシンで `ollama pull gemma4:12b`。
> 3. `export-windows.ps1 -Version 1.2.0` で再ビルド（**配布zipは約10.5GBに増**＝gemma4 7.56GB＋bge-m3）。同梱LLMが gemma4:12b であることをzip内manifestで確認。
> 4. **クリーン管理者インストール**（Codex保留の旧`C:\LocalRAGProd`をUAC承認でuninstell後）→ Round2＋**サービス制御の手動再確認**（`.env.production`修正の実証：Collector/Ollama controllable=true、Web UIから停止起動、VRAM解放）→ `/api/ps`でgemma4ロード確認。
> 5. 結果を `docs/WINDOWS_NATIVE_VERIFY_V1.2.0_RESULT_2026-07-14.md` に追記。
> これで OTE-RAG ＋ gemma4:12b ＋ サービス制御 の全部入りv1.2.0が完成し、顧客配布可能になる。

> **【モデル切替 2026-07-14】LLM: qwen3:8b（中国系）→ gemma4:12b（Google, Apache 2.0, 非中国系）**
> ユーザー指示「中国系以外の優秀なモデルを1つ採用」。調査＝`docs/MODEL_SELECTION_NON_CHINESE_2026-07-14.md`、モデルカード＝`docs/MODEL_CARDS.md`。
> - dev評価: gemma4:12b＋gemma4向け調整プロンプト＋topN=8で **scale-eval 25/30・ハルシネーションゼロ**（同条件のqwen3:8bは22/30・捏造4件）。topN=15は悪化するため8を維持。
> - **反映済み（ソース側）**: 既定プロンプト（fork `server/models/systemSettings.js`）、`OLLAMA_MODEL_PREF=gemma4:12b`（compose/env template）、`export-windows.ps1 $BundleModels`・`export.sh`、`MODEL_CARDS.md`。Embeddingは bge-m3 のまま（再embed不要）。
> - **未反映（Windows/Codex）**: v1.2.0再ビルドで gemma4:12b を同梱（`ollama pull gemma4:12b` 後にexport）。配布zipは約2.3GB増。→ `docs/CODEX_HANDOFF_V1.2.0_OTERAG_2026-07-14.md` STEP3に統合済み。
> - dev環境メモ: composeネットワークが外部到達不可（tailscale起因）だったため、gemma4:12bはデフォルトブリッジの使い捨てコンテナで共有ボリュームへpullした。配布物には無関係。

> **【Codex一式委任 2026-07-14】OTE-RAG v1.2.0 ビルド＆実機検証（現状と作業を1枚に集約）**
> `docs/CODEX_HANDOFF_V1.2.0_OTERAG_2026-07-14.md` を参照。要点:
> - **Linux側は完成**（コード・ロゴ・顧客資料すべてOTE-RAG化、fork `8907620d`／localRAG origin同期済み）。
> - **Windows側は1つ前**: `C:\LocalRAG\src`はリブランド未反映（サービス制御57b5d115まで）、`dist`はv1.1.0まで、v1.2.0未ビルド・未検証。
> - Codex作業: (1)WSL forkから`frontend/`＋server3ファイルを`C:\LocalRAG\src`へ同期（node_modules除く）→(2)favicon再生成→(3)v1.2.0ビルド→(4)管理者検証（新機能=ショートカット/ランチャー/サービス制御UI/日の丸見た目/回帰）→(5)結果レポート。

> **【リブランド 2026-07-13】製品名「LocalRAG for ℳシステム」→「OTE-RAG」、アイコンを日の丸化**
> ユーザー指示。命名意図＝「**お手軽**にローカルでRAG」＋Made in Japan（読みは「おてらぐ」だが表示名には併記しない）。アイコンは先頭Oを**日の丸（赤 #BC002D＋白縁）**に。
> - **ユーザー可視の表示テキストのみ**をOTE-RAG化（forkフロント/サーバ38ファイル・109箇所、`frontend/index.html`のtitle/meta、`MetaGenerator.js`のtitle/PWA名、サービス制御UIラベル「OTE-RAG Server/Collector/Ollama」）。
> - **温存した技術識別子**: Windowsサービス名`LocalRAG-Ollama/Collector/Server`、パス`C:\LocalRAG*`、import識別子`LocalRAGIcon`、アセット名`localrag-*.svg`。※perl一括置換で`C:\LocalRAG\storage`のパスコメント1件が誤変換→revert済み。
> - **ロゴSVG3点**（dark/light/icon）を作り直し: ワードマーク「⭕TE-RAG」（先頭Oが日の丸赤ディスク＋白縁）。iconは日の丸＋RAG文書ライン。デスクトップランチャー`LocalRAG.html`（ファイル名は温存）の表示ブランドもOTE-RAG化。読み「おてらぐ」は表示名に併記しない（2026-07-13ユーザー指示）。
> - **favicon.png/.ico未更新**: WSLではsharpのlinuxネイティブバイナリが無く生成不可。**Windowsビルド時にsharpで`localrag-icon.svg`から再生成する手順を`docs/CODEX_WINDOWS_NATIVE_BUILD_V1.2.0_2026-07-13.md` Part Aに追記済み**。
> - **反映にはv1.2.0再ビルドが必須**（src再同期→yarn build）。dev docker（compose）も次回リビルドでimage 1.0.6にする想定。**未コミット**（ユーザー確認待ち）。

> **【要対応 2026-07-13 第2報】v1.2.0ビルド未実行のズレ → 再依頼**

> **【要対応 2026-07-13 第2報】v1.2.0ビルド未実行のズレ → 再依頼**
> Codex 1回目の実行（`docs/WINDOWS_NATIVE_VERIFY_ROUND2_RESULT_2026-07-13.md`）は、Part A/B（ビルド）を飛ばして
> 検証ランナーだけを回したため、**v1.2.0ではなく既存v1.1.0.zipを検証**してしまった（ランナー既定ZipPathがv1.1.0だったため）。
> - v1.1.0の回帰は全PASS（install→E2E PASS=11→GPU size_vram 10.5GB→backup/stop/start→uninstall、8分15秒）。だが**v1.2.0新機能（ショートカット・ランチャー・サービス制御UI）は未検証**。
> - 対策: (1)`round2-admin-verify.ps1`の既定ZipPathをv1.2.0に変更（未ビルドなら「zip not found」で止まり誤検証を防止）。(2)依頼書`docs/CODEX_WINDOWS_NATIVE_BUILD_V1.2.0_2026-07-13.md`冒頭に「必ずPart A/Bのビルドを先に完了させてからPart Cへ」を明記。
> - **次: Codexが依頼書どおりPart A（yarn install/build）→Part B（export-windows.ps1 -Version 1.2.0でv1.2.0.zip生成）→Part C（-ZipPath v1.2.0で検証）を通しで実行**。

> **【同期完了・Codex依頼 2026-07-13】v1.2.0ビルド準備完了**
> - `C:\LocalRAG\src`（frontend/server, fork `57b5d115`）は既に同期済みと確認（diffなし）。
> - `C:\LocalRAG\windows-native` はJul 10時点で止まっていた（`launcher/`フォルダ自体が存在せず、install.ps1/export-windows.ps1/uninstall.ps1/config/server.env.templateも未反映）。リポジトリと完全一致になるよう同期済み。
> - localRAGリポジトリのコミット5件（サービス制御UI実装4件＋Round2検証レポート記録1件）をorigin/mainにpush済み。
> - **次: Codexが`docs/CODEX_WINDOWS_NATIVE_BUILD_V1.2.0_2026-07-13.md`の手順でyarn install/build→export-windows.ps1 -Version 1.2.0→実機検証（デスクトップショートカット・ランチャー・サービス制御UIのオンオフが新規確認項目）**。

> **【機能追加 2026-07-13】Web UIからのサービス制御 + デスクトップショートカット（fork `57b5d115`, image 1.0.5, localRAG側もコミット済み）**
> ユーザー要望「常時各サーバを起動しているとメモリを消費するため画面から自由にオン/オフしたい」への対応。
> - **API**: `GET /api/system/local-services`（3サービス状態）、`POST .../{llm|collector}/{start|stop}`（sc.exe経由でWinSW制御）。
>   `LOCAL_SERVICE_CONTROL=winsw`（server.env.templateに追加済み）のときのみ制御有効。**serverはUI提供中のため制御不可**（鶏卵問題）。
> - **UI**: チャット/ホーム右上に状態ピル→クリックで3サービスパネル。llm停止中は入力欄上にバナー+起動ボタン。15秒ポーリング。
> - **デスクトップショートカット**: install.ps1が全ユーザーデスクトップに`LocalRAG.lnk`を作成（uninstallで削除）。
>   飛び先は`InstallRoot\LocalRAG.html`（疎通確認ランチャー: 正常→アプリへ自動遷移／サーバー停止→日本語案内+再接続ボタン。
>   file://のCORSを避けるため画像ロード方式でping）。アイコンは`LocalRAG.ico`（brand PNG埋め込みICO）。
> - 検証: dev(image 1.0.5)でllm停止/復帰の状態遷移・停止バナー表示を実機確認、rag-e2e 11/11 PASS。
>   **sc.exeによる実サービス制御はdevでは検証不可能 → 次のWindows実機検証（v1.2.0）の必須確認項目**。
> - **次: Windows側v1.2.0再ビルド** — `C:\LocalRAG\src`へforkソースツリー再同期（50a11701+57b5d115、frontend/server広範囲のため
>   再コピー+yarn install/build推奨）→export-windows.ps1（launcher同梱・ショートカット込み）→Round2系の再検証
>   （新規確認: デスクトップショートカット動作・ランチャー・サービス制御UIからのOllama停止起動・VRAM解放）。

> **【デザイン刷新 2026-07-12】「LocalRAG for ℳシステム」ブランド + 2テーマ（fork `50a11701`, image 1.0.4）**
> ユーザー指示による全面デザイン改修。(1)AnythingLLM表記をユーザー可視面から排除（タイトル/favicon/ロゴ/
> オンボーディング/ロケール等28ファイル102件。**本番のindex.htmlはserver/utils/boot/MetaGenerator.jsが動的生成**
> するためサーバー側も変更が必要だった点に注意）。Community Hub等の外部製品実名は虚偽になるため温存。
> (2)既定テーマをダークに変更、アクセントはダーク=蛍光青緑#00e5c0系/ライト=マゼンタ#d61f8d系。
> ハードコードsky/blueのTailwindクラス（サイドバー選択・ログイン・進捗バー）も置換。
> 主要ボタンのweight強化・hoverネオングロー・コントラスト是正込み。新ロゴはSVG3点
> （frontend/src/media/logo/localrag-*.svg）。WSL側は`runtime/docker-compose.yml`をimage 1.0.4に切替済み・動作確認済み。
> **注意: Windows native配布zip v1.1.0とGitHub Release `v1.1.0-demo` は旧デザイン（AnythingLLMブランド）のまま。**
> デザイン込みで配布するにはWindows側`C:\LocalRAG\src`へのfork再同期（今回はfrontend/server広範囲のため
> 差分コピーでなくソースツリー再コピー+yarn install/build推奨）→v1.2.0再ビルド→Release再アップロードが必要。

> **【重要 2026-07-12 Codex】v1.1.0 Round2再検証 PASS — Windows native配布の核心課題は解決**
> 詳細: `docs/WINDOWS_NATIVE_VERIFY_ROUND2_RESULT_2026-07-12.md`。
> - `C:\LocalRAG\dist\LocalRAG-win64-v1.1.0.zip`でRound2通し検証が完走。summary=`C:\Temp\localrag-round2-logs\round2-admin-20260712-074657.summary.json`。
> - tar展開、install、API ping、API key生成、PS5.1 E2E、GPU判定、backup、stop/start、uninstall、cleanupはいずれもOK。PS5.1 E2Eは`PASS=11 FAIL=0`。
> - **主要確認（2026-07-09から3セッションかけて追ってきた核心問い）**: Windows Service / Session 0 のOllamaでCUDA認識成功。`NVIDIA GeForce RTX 5070 Ti`、`total_vram=15.9 GiB`、`/api/ps size_vram_total=10537381395`。これでDocker/WSLなしの完全native配布がGPU込みで動作することが実証された。
> - 残タスク（いずれも仕上げレベル、出荷ブロッカーではない）:
>   1. B2-6 reboot resilienceはランナー仕様でSKIP → 手動でWindows再起動後のサービス自動起動・API ping・GPU VRAM確認が必要
>   2. `C:\LocalRAGProd\uninstall.ps1`だけ残る（軽微、uninstall設計の仕様。除去するかドキュメント化するか要判断）
>   3. 完全オフライン（ネットワーク遮断）実機検証が未実施（ログにcontext-window map syncやOllama cloud既定値の挙動あり、顧客配布前に強めるべき）
>   4. PS5.1のtranscriptで日本語グリフが重複表示される見た目の問題（pass/failには無関係）
> - **次に大きく残っているのは技術ではなく、士業ヒアリング（核心仮説A）**。技術トラックはここで一区切り。

> **【今すぐの状況 2026-07-12】Round2指摘の修正完了、v1.1.0で再検証待ち（ユーザー管理者実行）**
> Codexレポート（`docs/WINDOWS_NATIVE_VERIFY_ROUND2_RESULT_2026-07-11.md`）の全指摘に対応済み:
> - **配布zipのOllamaランタイム欠落（根本原因）**: `C:\LocalRAG\build-deps\ollama`に`ollama.exe`しか無かった
>   → 公式zip（v0.31.2）を丸ごと展開し直し（lib/ollama/llama-server.exe・DLL・cuda_v12/v13、計1.9GB）。
>   export-windows.ps1のllama-server.exe必須チェック（Codex追加）も維持。
> - **Round2ランナーのバグ**（curl "no URL specified"／summary JSON未生成）を修正:
>   (1) `CurlText([string[]]$Args)`のパラメータ名がPS5.1自動変数`$args`に潰され空になる→`$CurlArgs`に改名。
>   (2) `[pscustomobject]@{steps=@(List[object])}`がPS5.1で「引数の型が一致しません」→`.ToArray()`。いずれも実PS5.1で再現→修正確認。
>   (3) GPU判定を文字列"GPU"検索→`/api/ps`の`size_vram`実値でOK/NG判定に変更（Round2の核心を正式判定化）。
> - **rag-e2e-test.ps1のPS5.1バグ**を修正: JSON bodyの二重引用符剥がれ→一時ファイル+`--data-binary`化。
>   さらに実走で新規発見した3件も修正: curl stdoutのCP932誤デコード（日本語JSON破壊）→`[Console]::OutputEncoding=UTF8`、
>   例外時に偽PASS（exit 0）で終わる構造欠陥→catch追加、UNC上のfixtureをResolve-Path .Pathが壊す→`.ProviderPath`。
>   **修正後、WSL稼働インスタンス（qwen3:8b+bge-m3）相手にPS5.1/pwsh両方でPASS=11 FAIL=0を実測確認。**
> - **fork新コミット（日本語セパレータenv化・プロンプト文書名指示）をWindows側`C:\LocalRAG\src`へ同期**（3ファイル、
>   同期前がfd67e830と完全一致であることを確認した上での最小コピー）。
> - **v1.1.0再ビルド**（qwen3:8b+bge-m3同梱・MODEL_CARDS同梱・完全Ollamaランタイム）。
>   ランナー既定ZipPathはv1.1.0に更新済み、修正版ランナー/READMEは`C:\Temp\localrag-round2\`へ配置済み。
> - **次: ユーザーが`C:\Temp\localrag-round2\Run-Round2-Verify.cmd`を管理者実行**（クリーン再インストールで
>   Session 0 GPU＝`size_vram>0`を確認するのが核心。Codexが2026-07-12に前回残骸を掃除済みでクリーン状態）。

> **【重要 2026-07-11 Codex】Round2実機検証は「部分成功・配布zipはNG」**
> 詳細: `docs/WINDOWS_NATIVE_VERIFY_ROUND2_RESULT_2026-07-11.md`。
> - 管理者実行でtar展開、preflight、install、WinSWサービス3本、`/api/ping`は到達。ポートは`3005/8888/11435`で起動。
> - ただしRound2ランナー自体は`curl: (2) no URL specified`でAPI ping/API key生成に失敗し、summary JSONもPowerShell型不一致で未生成。手動curlではAPIは正常なのでランナー側バグ。
> - 配布zipの重大欠陥: `runtime/ollama/ollama.exe`しか入っておらず、`lib/ollama/llama-server.exe`とDLL/CUDAツリーが欠落。Embeddingが`llama-server binary not found`で失敗。
> - 診断用に公式Ollama zipから`lib/`を`C:\LocalRAGProd\runtime\ollama`へ手動追加したところ、PowerShell 7版E2Eは`PASS=11 FAIL=0`。つまり製品経路は動くが、現zipは出荷不可。
> - GPU検証は未解決。サービス起動時ログは`inference compute id=cpu` / `total_vram="0 B"`、`/api/ps`も`size_vram:0`。完全Ollama同梱で再ビルド・クリーン再インストール後にSession 0 GPUを再確認する。
> - Codexで再発防止として`windows-native/export-windows.ps1`に`lib\ollama\llama-server.exe`必須チェックを追加済み。次はWindows側`C:\LocalRAG\build-deps\ollama`を公式zip丸ごと展開に直して再ビルド。
> - 追加修正候補: `rag-e2e-test.ps1`はWindows PowerShell 5.1でJSON body quotingに失敗するため、JSONを一時ファイルまたはstdin経由にする。
> - 2026-07-12 Codex: 再検証前の初期化として途中インストールを削除済み。LocalRAGサービス3本なし、`C:\LocalRAGProd` / `C:\ProgramData\LocalRAG` / `C:\Temp\localrag-verify` は削除済み。Round2ログ `C:\Temp\localrag-round2-logs` と cleanupログのみ保持。

> **【重要 2026-07-11】RAG精度検証の結果、モデル構成を全面変更（詳細: `docs/RAG_ACCURACY_IMPROVEMENT_2026-07-11.md`）**
> - **旧LLM（llm-jpコミュニティGGUF）はテンプレート破損で本文が空になる致命的問題**があり撤回。
>   過去のe2e PASSは思考テキストへの偶然マッチを含む見かけのPASSだった。以後LLMはOllama公式配布のみ使用。
> - **新構成: LLM=`qwen3:8b`・Embedding=`bge-m3`・topN既定8（env注入）・日本語セパレータ・image 1.0.3**。
>   実運用規模30問評価（紛らわしい規程10本、`scripts/scale-eval.py`）で26/30・ハルシネーションゼロ・不明応答5/5。
>   回帰: e2e 11/11 PASS。配布側（compose/envテンプレ/export-windows.ps1のBundleModels/LICENSES）も反映済み。
> - **Round2実機検証（ユーザーの管理者実行待ち）は旧構成zipのまま実施してよい**（インストーラ機構の検証として有効）。
>   合格後にv1.1.0として新モデル構成で再ビルドする。**再ビルドのモデル前提は整備済み（2026-07-11 Claude）**:
>   bge-m3をWSL側`runtime/ollama-models`からWindows側`%USERPROFILE%\.ollama\models`へコピーし全blobのsha256検証OK、
>   qwen3:8bもWindows側で全blob存在を検証済み。`docs/MODEL_CARDS.md`を作成し両export（export.sh / export-windows.ps1）に同梱処理を追加。

> **【今すぐの状況 2026-07-10】Round2検証は「ユーザーが管理者権限で1回実行」だけ待ち**
> Codexは第2ラウンド検証で再び管理者権限の壁に当たり（予測どおり）、代わりに検証を通しで自動実行する
> ランナー `windows-native/verify/round2-admin-verify.ps1` を完成させて実行待ちにした。ClaudeがレビューしASCII/構文OKを確認、
> リポジトリに取り込み＋UAC自己昇格ランチャー `Run-Round2-Verify.cmd` を追加（Codex版.cmdは自己昇格しないため）。
> 実行物は `C:\Temp\localrag-round2\` にも配置済み。**ユーザーがこの.cmdをダブルクリック→UAC承認するだけ**で
> tar展開→install→E2E→backup→uninstallまで走り、`C:\Temp\localrag-round2-logs\*.summary.json`に結果が出る。
> それをClaudeが判定して仕上げ（顧客docsの実機確認2点・完全オフライン検証4-6へ）。

> **【新トラック 2026-07-09】Windows native配布（Docker/WSLなし配布）— PoC合格・Go確定**
> Codex提案（`docs/CLAUDE_CODE_MEMO_WINDOWS_NATIVE_DISTRIBUTION_2026-07-09.md`）→ Phase 0（Claude）→
> Codex実機PoC（`docs/WINDOWS_NATIVE_POC_RESULT_2026-07-09.md`、**RAG E2E 11/11 PASS**・GPU認識・オフラインモデル投入OK）→
> **ClaudeがGo判断を確定（2026-07-09）**。判断根拠とPhase 4詳細設計は `docs/WINDOWS_NATIVE_PHASE4_DESIGN_2026-07-09.md`。
> - **PoC課題対応済み**: #1 PS5.1文字化け → `windows-native/rag-e2e-test.ps1`をUTF-8 BOM付き化。
>   #2 hotdir誤解決 → fork `fd67e830`で`COLLECTOR_HOTDIR_PATH` env追加（server/collector共有）、envテンプレ更新済み。
> - **Phase 4方針**: WinSWでWindows Service 3本（Server/Collector/専用Ollama@11435）、
>   ビルド済み成果物同梱のzip+install.ps1配布、preflight（ポートowner/GPU/VRAM/ディスク検出）。
>   タスク分解4-1〜4-8と担当は設計メモ参照（4-1〜4-4=Claude、4-5/4-6実機検証=Codex）。
> - **Phase 4-1〜4-4実装完了（2026-07-09 Claude）**: WinSWサービス定義3本＋登録/解除ps1、
>   `export-windows.ps1`（配布zip生成、モデルはmanifest解析で必要blobのみ同梱）、
>   `install.ps1`（preflight＋checksum検証＋env生成＋prisma migrate＋サービス登録＋疎通確認）、
>   運用5本（start/stop/backup/restore/uninstall）、本番envテンプレ（`windows-native/config/`）。
>   全ps1はPowerShell 7.4.6 parserでSYNTAX OK・ASCII-only（rag-e2e-test.ps1のみ日本語＋UTF-8 BOM）。
>   設計判断: STORAGE_DIRは`app\server\storage`固定（prisma schemaのDBパスがソースツリー相対のため）、
>   InstallRoot既定は`C:\LocalRAG`（Program Filesの空白パスリスク回避）、モデル/ログのみProgramData。
> - **Codex実行結果（2026-07-10）**: 配布ビルドPart Aは成功。成果物は `C:\LocalRAG\dist\LocalRAG-win64-v1.0.0.zip`
>   （6.04GiB、100513 files、`versions.lock`作成済み）。結果詳細は `docs/WINDOWS_NATIVE_BUILD_VERIFY_RESULT_2026-07-09.md`。
>   Part Bは非管理者のため中断。「Expand-Archive展開後のinstall.ps1がPS5.1でハング」を発見。
> - **Claude診断完了（2026-07-10）**: ハングは成果物の欠陥ではなく、Expand-Archiveが書いたNTFSファイル実体に残る
>   開発機ローカルのフィルタドライバ状態と特定（13項目の切り分け: 同一内容の複製は動く・rename追従・pwsh正常・
>   排他オープン成功）。**展開手順は`tar.exe -xf`を正式化、PS5.1のExpand-Archiveは使用禁止**。
>   Ollama「0.23.0」表示は接続先サーバー（WSL Docker側）のバージョンで、**同梱exeは正しくv0.31.2**（再DL不要）。
>   詳細: `docs/WINDOWS_NATIVE_EXPAND_ARCHIVE_HANG_DIAGNOSIS_2026-07-10.md`
> - **Phase 4-7/4-8完了（2026-07-10、サブエージェント委譲で並行実施）**: 顧客向けdocs 4点を`docs/customer-windows/`に
>   作成しexport-windows.ps1の同梱対象を切替（Docker版docs同梱バグも修正）。LICENSES/にWinSW(MIT)・
>   Node.js v22(複合)の全文追加、NOTICE/THIRD_PARTY_NOTICES更新。
>   実機確認待ち2点: WinSWログファイル名の実名、アップロードUIの実文言（第2ラウンド検証時または次回に確認）
> - **次: Codexが第2ラウンド検証を実行** — 依頼書 `docs/CODEX_WINDOWS_NATIVE_VERIFY_ROUND2_2026-07-10.md`
>   （管理者権限でtar展開→install→**サービスからのGPU動作確認（Session 0でCUDAが効くかが今回の核心）**→
>   E2E(PS5.1)→backup/stop/start→uninstall。障害予測と対策表・昇格不可時の代替手順を同梱。
>   ポートは3001でなく3005を使用＝wsl --shutdownがWSL上のClaude Codeを殺すため回避）
> - 現行のWSL2+Docker方式は保険として無変更で温存。P2（install.shフルサイクル検証等）はWindows native版の顧客配布方針確定後に要否を再判断

> **P1完了（2026-07-08）**: Phase 1完了に必須の技術タスクはすべて消化した。残るPhase 1タスクは
> **士業ヒアリング（核心仮説「士業はローカルAIに金を払うか」の検証）のみ**で、これはユーザー自身の作業。
> 技術側の次はP2（配布品質: trust_remote_codeレビュー・install.shフルサイクル検証）。
権威ドキュメント: `AGENTS.md`/`CLAUDE.md`（制約集約） → 本ファイル → `docs/OFFLINE_DISTRIBUTION_HARDENING_PLAN.md`（配布ハードニング計画） → `docs/PROJECT_STATUS.md`（俯瞰） → `docs/anythingllm_customer_distribution_plan.md`（配布計画＝一次情報）。

---

## 1. プロジェクト一行説明

AnythingLLM(MIT) を fork 改修し、完全ローカルの日本語RAGを構築 → 顧客配布する。**Phase 1（個人PC検証）進行中**。オフライン配布パッケージの P0（配布必須要件）は完了し、P1（LLM/embedding確定）が次の焦点。

## 2. いま動いているもの / 確認コマンド

- **AnythingLLM**: `http://localhost:3001`（healthy）。
  - image: **`localrag-anythingllm:1.0.0`**（`anything-llm/`(`product/customer-rag-base`)からカスタムビルド。外部LLM provider allowlist改修が反映済み。公式 `mintplexlabs/anythingllm:latest` は使用していない）。
  - LLM: `hf.co/mmnga-o/llm-jp-4-8b-thinking-gguf:Q4_K_M`（2026-07-04にClaudeが切替。[B2]参照）。
  - Embedding: `mxbai-embed-large:latest`（Apache-2.0, 日本語対応）。
  - VectorDB: LanceDB（内蔵）。
- **Ollama**: Docker サービス（`rag-ollama`, `rag-internal` ネットワーク、外部非公開）。ホストプロセスは使っていない。

```bash
cd /home/ishihara1447/projects/fukugyo/repos/localRAG/runtime
docker compose ps
curl -s http://localhost:3001/api/ping           # {"online":true}
```

## 3. 今セッションでの主な作業（2026-07-02）

前回セッションの「Codexレビュー」(`docs/OFFLINE_DISTRIBUTION_HARDENING_PLAN.md`)への対応が不十分だったとの追加指摘(`docs/CLAUDE_CODE_REVIEW_FEEDBACK_2026-07-02.md`)を受け、優先度順に対応。**全項目コミット・push済み**。

1. **P0: カスタム AnythingLLM image 化**（最重要・完了）
   - DNS問題の根本原因判明: WSL2のDNSプロキシが特定ホスト（`release-assets.githubusercontent.com`、GitHub releaseアセット配信）への断続的な解決失敗を起こす。`getent hosts`は成功するのに`curl`は失敗する再現性のある症状。
   - 対処: `docker build --network=host --add-host=release-assets.githubusercontent.com:185.199.108.133 ...` でビルド成功。
   - `runtime/docker-compose.yml` / `scripts/export.sh` の既定imageを `localrag-anythingllm:1.0.0` に切替。
   - 実機確認: 外部provider(openai)指定 → API側で拒否、Swagger docs無効、smoke-test・rag-e2e-test全PASS。
2. **export.sh/install.sh/backup.shのバグ修正**
   - `package.sha256`/`ollama-models.sha256`生成が`xargs`にシェル関数を渡していて不安定 → `while read`に統一。
   - `install.sh`のchecksum検証が欠落時に「スキップ」していた → 3種のchecksum必須化、欠落・不一致で停止。
   - `versions.lock`に`unknown`が残り得た → git commit/image digest取得失敗時にexportを失敗させる。ローカルビルドimageはRepoDigestを持たないためimage IDにフォールバック。
   - `backup.sh`のtar追記バグ（`.tar.gz`作成後に別名`.tar`へ追記しようとして失敗）を修正。
   - **実機で発見した追加バグ**（当初のレビュー指摘には無かったもの）:
     - `export.sh`: `--output`に相対パスを渡すと`cd`後に意図しない場所へ書き込む → 絶対パスへ正規化。
     - `export.sh`: ollamaコンテナがroot権限で`/root/.ollama`配下(`id_ed25519`等)をroot所有・600権限で作成し、ホスト側非rootユーザーがchecksum生成時に読めず失敗 → コンテナ経由でchownして解決。
     - `uninstall.sh`: image名が`mintplexlabs/anythingllm`のままハードコードされ、カスタムimage化後は削除対象を見つけられなかった → `versions.lock`から実際のimage名を読み取るよう修正。
     - `smoke-test.sh`: Ollama疎通確認が`wget`依存だったが、カスタムimageのベース(Ubuntu 24.04)には`wget`が無く`curl`のみ存在 → `curl`ベースに変更。
3. **rag-e2e-test.shの拡充**: 外部provider拒否・Swagger無効の検証を追加（計画§10.4の未実装項目）。文書外質問の「不明」判定パターンがLLM応答の表現ゆれで誤FAILすることも発見・パターン拡張。
4. **LICENSES/NOTICE**: AnythingLLM(MIT)/Ollama(MIT)/Apache-2.0(llm-jp・mxbai-embed-large)/Llama 3.1 Community Licenseの実ライセンス全文を公式配布元から取得して同梱。
5. **顧客向けドキュメント5点**: `docs/customer/`にREADME/INSTALL_GUIDE/OPERATIONS_GUIDE/SECURITY_GUIDE/TROUBLESHOOTINGを作成（`export.sh`が自動でパッケージ直下にコピー）。
6. **Windows PowerShell版スクリプト**: install/start/stop/backup/restore/uninstallの6本を作成。

### 追加作業（Windows 11 + WSL2 + Docker Engine 方針の検証 / 2026-07-02）

- Docker Desktop を使わない方針を現環境で検証。
  - WSL2 `Ubuntu-22.04` 上の Docker Engine (`unix:///var/run/docker.sock`) が使われていることを確認。
  - Windows 側 Docker context は `desktop-linux` を指しており、PowerShell から Docker を直接叩く実装は方針に合わないことを確認。
  - Docker service は `active` / `enabled`。
  - NVIDIA GPU (`NVIDIA GeForce RTX 5070 Ti`, 16GB級VRAM) が WSL2 と `rag-ollama` コンテナ内の両方で認識されることを確認。
  - `nvidia-container-toolkit` (`1.19.0`) と Docker runtime `nvidia` を確認。
- `scripts/*.ps1` を Docker Desktop 前提の直接 Docker 操作から、WSL2 内の既存 bash スクリプトを呼ぶ薄いランチャーへ変更。
  - 共通ヘルパー: `scripts/localrag-wsl-launcher.ps1`
  - `export.sh` は `.ps1` ランチャーも配布パッケージへ同梱する。
  - PowerShell → WSL2 → bash → Docker 経路で `smoke-test.sh` 実行成功。
- `docs/customer/INSTALL_GUIDE.md` に Windows 11 + WSL2 手順を追記。
- 検証詳細は `docs/WINDOWS_WSL2_VALIDATION_REPORT_2026-07-02.md`。

注意: UNC 上の `.ps1` は既定 ExecutionPolicy でブロックされた。顧客手順では `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1` を明記する。

### 実機検証で確認できたこと（今セッション）

- `bash scripts/export.sh --version 1.0.0 --output ./dist/localrag-1.0.0` が成功し、9.3GBのパッケージを生成。
- `checksums/{images,ollama-models,package}.sha256` すべて `sha256sum -c` で検証OK。
- `versions.lock` に `unknown` が残らないことを確認。
- `rag-e2e-test.sh`・`fixtures/`・`LICENSES/`・`NOTICE`・顧客向けdocsがすべて正しくパッケージに同梱されることを確認。
- 検証後、`dist/`は削除済み（`.gitignore`対象、ローカルにも残していない）。

### まだ検証していないこと

- `install.sh`のフルサイクル（今回生成した`dist/localrag-1.0.0/`を使って実際にゼロから`bash install.sh`を実行する検証）。現在稼働中のコンテナと名前・ポートが衝突するため、このセッションでは実施しなかった。
- 生成済み配布パッケージ上での PowerShell ランチャー動作確認（共通ランチャー経由の `smoke-test.sh` は現環境で確認済み）。
- 完全オフライン（ネットワーク遮断）環境での通し検証（計画のP4）。
- APIキー未設定のため、今回の Windows/WSL2 再検証では `rag-e2e-test.sh` は未実行。

## 4. ★未解決ブロッカー

### [B1] vLLM が WSL2 で起動できない（未解決）

- 症状: `RuntimeError: UVA is not available` (GPUModelRunnerV2, WSL2 非対応)。
- **現在の回避策**: Docker Ollama + `llama3.1:8b`。
- **本番対応（未着手）**: Dockerfile で GPUModelRunnerV2 の UVA チェックをパッチした独自 vLLM イメージをビルド。
  - 参考: https://discuss.vllm.ai/t/project-vllm-docker-for-running-smoothly-on-rtx-5090-wsl2/1697

### [B2] llm-jp-4-8b-thinking が実用速度で使えない → **解決済み（2026-07-08、RAGフルパス検証完了）**

- 従来症状: 単純な質問でも 3分13秒（thinking フェーズで大量トークン生成）。AnythingLLM のデフォルト HTTP タイムアウトを超える。
- **2026-07-04 実施した対処**:
  1. `runtime/docker-compose.yml` に `OLLAMA_RESPONSE_TIMEOUT=1200000`（20分）を有効化。
  2. `OLLAMA_MODEL_PREF` を `hf.co/mmnga-o/llm-jp-4-8b-thinking-gguf:Q4_K_M` に切替、`docker compose up -d anythingllm` でコンテナ再作成 → `healthy` 復帰・`/api/ping` 正常を確認。
  3. `docker exec rag-ollama ollama run ...` で生Ollama呼び出しを2回実測: 1回目（コールドスタート）**6.6秒**、2回目（ウォーム、就業規則要約という多少実務的な質問）**1.06秒**。GPU（RTX 5070 Ti）がしっかり効いており、当初の「3分13秒」は再現しなかった。
- **2026-07-08 実施したRAGフルパス検証**: AnythingLLM管理画面を使わず、`POST /api/system/generate-api-key`をAPI直叩きでAPIキーを発行（single-user mode・AUTH_TOKEN未設定のため無認証で発行可能だった）。`LOCALRAG_API_KEY=<key> bash scripts/rag-e2e-test.sh`を2回実行:
  - ワークスペース作成→文書アップロード・embedding→文書内質問（RAG検索＋LLM推論＋出典付き回答）→文書外質問→外部provider拒否確認→Swagger無効確認、の全6ステップが**合計6.4秒**で完走（タイムアウトなし）。当初懸念していた「3分13秒」は文書検索を挟んだフルパスでも再現せず、[B2]は完全解消と判断してよい。
  - 文書内質問（「有給休暇は年間何日か」）には正しく「22」を含む回答＋出典1件が返り、PASS。
  - **新たに発見した問題**: 文書外質問（文書に無い情報を聞く）に対して、AnythingLLMが「不明」と答えずに出典付きで回答してしまい、FAIL（ハルシネーションの疑い）。これは`CLAUDE.md`の絶対ルール「RAG回答は出典必須・文書外は『不明』を既定プロンプトで強制」が未実装であることを示す。下記P1に追加。
- 使用したテスト用APIキーはすべてテスト後に`DELETE /api/system/api-key/:id`で削除済み。

### [B3] コンテナ内DNS失敗 → **解決済み（2026-07-02）**

`docker build --network=host --add-host=release-assets.githubusercontent.com:<IP>` でカスタムimageビルド成功。詳細は上記セクション3参照。

## 5. 次のアクション（優先度順）

### P1 — Phase 1 完了に必須

1. ~~**[B2] フルパス検証**~~ → **完了（2026-07-08）**。6ステップ合計6.4秒、タイムアウトなし。詳細は上記[B2]セクション参照。
2. ~~**RAG回答の「出典必須・文書外は不明」を既定システムプロンプトで強制**~~ → **完了（2026-07-08）**。fork commit `b29d5567`で`saneDefaultSystemPrompt`を日本語RAG厳格版に変更（出典必須・文書外は「提供された文書には該当する情報がありません」・日本語回答強制）。image 1.0.1に反映しrag-e2e-test.shで文書外質問の不明応答を確認済み。
3. ~~**PDF/DOCX テスト**~~ → **完了（2026-07-08）**。DOCXは素通し成功。**日本語CIDフォントPDFは取り込み失敗するバグを発見・修正**（fork commit `5773dc9f`: pdf-parse同梱の古いpdf.jsがcMap非対応 → pdfjs-dist@4.4.168+同梱cMapsに切替。upstream masterも未修正の制約だった）。image 1.0.2に反映、fixtures/test-expense.pdf（CIDフォント）＋test-attendance.docxで検証、rag-e2e-test.shに回帰テスト[3b][3c]を追加（11/11 PASS）。
4. ~~**日本語 embedding 正式選定**~~ → **mxbai-embed-largeを正式採用（2026-07-08）**。文書の語彙を避けた言い換え質問5問（年休→有給休暇・手当→日当・リモートワーク→在宅勤務等の同義語検索を含む）で5/5正答を確認し実用水準と判断。plamo-embedding-1b等への切替（全文書再embedding必須）は不要。※サンプル5問・3文書での評価のため、実文書規模での再確認はPhase 2で行う。

### P2 — 配布品質

5. `trust_remote_code` コードレビュー（llm-jp-4-8b-thinking 採用時）とコミットハッシュ固定。
6. `install.sh` のフルサイクル実機検証（別マシンまたは現行コンテナ停止後に実施）。
7. **（2026-07-08発見）既定`topN=4`は複数文書投入時に不足**: `scripts/precision-eval.py`で検証。単一の長文文書内では16/16正答だが、4文書（短文3件＋長文1件）を同一ワークスペースに入れるとtopN=4では3問中2問が誤った文書から出典を引いた（長文側がチャンク数で他文書を圧迫し上位を独占）。topN=8に上げたところ3/3正答。**ワークスペース既定値のtopN引き上げ（例: 6〜8）を検討し、複数文書アップロードを前提とした顧客シナリオで再検証すること。**

### P3 — 仕上げ

7. 完全オフライン（ネットワーク遮断）実機検証。
8. SBOM の作成（MODEL_CARDSは2026-07-11完了: `docs/MODEL_CARDS.md`、両exportで同梱済み）。
9. 生成済み配布パッケージ上でのPowerShellランチャー動作確認。

## 6. 現在のファイル構成

- `runtime/docker-compose.yml`: AnythingLLM(`localrag-anythingllm:1.0.0`) + Ollama(Docker) サービス定義。
- `runtime/anythingllm-storage/`: データ永続化ボリューム（DB, ベクター, 設定）。コミット禁止。
- `runtime/ollama-models/`: Ollamaモデルファイル。コミット禁止。
- `anything-llm/`: AnythingLLM fork（branch: `product/customer-rag-base`、独立git、親からは`.gitignore`で除外）。
- `scripts/`: export/install/uninstall/start/stop/backup/restore/smoke-test/rag-e2e-test（bash）+ WSL2ランチャー版PowerShellスクリプト(.ps1)。
- `docs/customer/`: 顧客向けドキュメント5点。
- `LICENSES/`, `NOTICE`: 第三者ライセンス。

## 7. Git 状態

- リモート: `git@github.com:ishihara1447/localRAG.git`（`origin/main`、push運用に移行済み）。
- `anything-llm/` は独立リポジトリ。fork先remoteは未設定（`upstream`=Mintplex-Labs本家のみ）。**pushしない**（allowlist改修などはローカルコミットのみ）。

## 8. Claude Code セッション運用

- ユーザー方針: 確認・プロンプトを極力減らす。妥当なデフォルトは自分で決めて進め、事後報告。ただし工数の大きい別トラック（PowerShell対応など）は着手前に確認する。
- 作業単位: 1改修1コミット。レビュー→修正→再レビュー→コミット&pushのサイクルを細かく回す。
- メモリ: `~/.claude/projects/-home-ishihara1447-projects-localRAG/memory/` に保存済み。

---

Source（vLLM/WSL2 ブロッカー調査）:
- vLLM Forum: Project: vLLM docker for running smoothly on RTX 5090 + WSL2 — https://discuss.vllm.ai/t/project-vllm-docker-for-running-smoothly-on-rtx-5090-wsl2/1697
- Making vLLM work on WSL2 (DEV) — https://dev.to/docteurrs/making-vllm-work-on-wsl2-482e
- vLLM Troubleshooting — https://docs.vllm.ai/en/latest/usage/troubleshooting/
