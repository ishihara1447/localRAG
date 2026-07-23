> **【Codex icon redesign 2026-07-21】OTE-RAGのアイコンを文書検索AIとして再設計**
> ユーザー承認済みの調査方針（文書・検索・出典を前面に出すAnythingLLM/NotebookLM/Glean/Dify/Crew/PKSHA系の見せ方）に沿って、主アイコンを更新した。
> - マスターSVG: `anything-llm/frontend/src/media/logo/localrag-icon.svg`
> - デザイン: 背面の文書2枚=ローカル資料、中央の検索レンズ=RAG検索、レンズ内の赤い日の丸=日本製、右上のスパーク=AI生成。既存の暗色背景・青緑の枠・日の丸のブランド性は維持し、16〜64pxで要素が潰れないよう線幅と要素数を絞った。
> - 同じSVGから `anything-llm/frontend/public/favicon.png` (64px)、`anything-llm/frontend/public/favicon.ico` (32px)、`windows-native/launcher/LocalRAG.ico` (64px) を再生成。Windowsセットアップは既存の `windows-native/setup/build-setup.ps1` 経由で `LocalRAG.ico` を参照する。
> - 検証: SVGの内容確認、favicon/ICOの形式と寸法確認、`git diff --check` を実施。画像表示ヘルパーのWSLパス解決は失敗したが、生成64px PNGを会話内で目視確認し、文書・検索レンズ・日の丸・スパークが判別可能であることを確認。
> - 注意: `anything-llm/` 全体がルート `.gitignore` で除外されているため、SVGとfaviconの変更はルートGit差分に出ない。追跡対象では `windows-native/launcher/LocalRAG.ico` のみ変更表示となる。Claude Code側で配布用forkの同期・強制追加・除外方針を確認し、再ビルド時に3資材が同じデザインになることを確認すること。
> - 既存の `runtime/docker-compose.yml` の変更には触れていない。コミット・pushは未実施。
>
# 引き継ぎメモ（セッション間ハンドオフ）
> **【次セッションはここから 2026-07-22 Claude】出典ページ番号機能を実装。次はv1.2.0再ビルド→Windows実機で「文書投入＋出典p.表示」E2E確認**
> ユーザー要望「回答のエビデンス(引用元)を簡単に確認したい。最低限、引用元の文書名とページ番号」に対応。文書名は既存表示、**ページ番号を新規実装**。
> - **仕組み**: PDFLoaderが持つ`loc.pageNumber`を活用。collector(`asPDF/index.js`)がページ連結時に各ページ先頭へ境界マーカー`\f<page>\f`(フォームフィード=PDF本文に非出現)を挿入 → server(`lance/index.js` addDocumentToNamespace)がチャンク毎に**多数決(チャンク内で最も文字数が多いページ)**でページを判定し`metadata.pageNumber`付与＋マーカー除去(埋め込み・表示は汚さない) → frontend(`Citation/index.jsx`)が引用詳細モーダルの各チャンクに「p.232」表示。
> - **検証済み**: 単体テストで境界跨ぎ・単一ページ複数チャンクとも正しくページ付与、既存retrieval非破壊(dev cp+restartでスモークOK)。**未実施=実PDFでのE2E**(元PDFは解析後trashされるため、白書PDFの再投入が必要)。
> - **コミット/作業ツリー**: fork `0e0829dc`(collector+Citationの2ファイル)。**server `lance/index.js`のマーカー→pageNumber判定は先行cushion系ステージと同居のため未コミット・作業ツリー保持**(ビルドには反映される)。devコンテナへcollector+lanceをcp+restart済み。
> - **重要な前提**: ページ番号は**再embed(文書の再投入)して初めて付く**。既存の白書embeddingは旧パース(マーカー無し)なのでpageNumber無し。→ 次のビルド後に白書PDFを投入し直して確認する。
> - **【2026-07-22 完了】dev image再ビルド＋実PDF E2E**: 現ソースから **`localrag-anythingllm:1.0.7`** を再ビルド(P1・think:false・出典ページ番号・cushion/hybrid全部入り、frontendも`yarn build`でCitationのp.表示を同梱)。compose切替・コンテナ再作成済み(`docker cp`パッチ依存を解消)。**実白書を再embedしフルE2E成功**: チャット回答の出典に正しいページ番号(統合作戦司令部→p.242/244、歳出額84,748→p.228)。本番WS(5ec7ec63)は新パース(マーカー付き)で再embed済み。ブラウザ`localhost:3001`で引用モーダルにp.表示を目視可能。
> - **【2026-07-24 完了】Windows native v1.2.2 配布パッケージ(インストーラ/アンインストーラ堅牢化版)ビルド済み・インストール可能**。成果物: **`C:\LocalRAG\dist\OTE-RAG-Setup.exe`(23,552 bytes)＋`OTE-RAG-win64-v1.2.2.zip`(11,018,845,064 bytes, SHA-256=`45f3a29602cc4ecb349d663272756cbb3dab317711b51a8473cdd3bdba850d1f`, 100,622ファイル)＋`.sha256`**。旧v1.2.1一式は削除(Setup.exeは隣のv*.zipを1個だけglob要求)。中身のRAG改良はv1.2.1と同じ(P1言い換え再検索/think:false/出典ページ番号/cushion/hybrid/リブランド全部入り)。**Setup.exeは未署名**(SmartScreen「詳細情報→実行」)。
> - **v1.2.2の主眼=インストーラ/アンインストーラの堅牢化(fix→reviewループを収束まで反復。国内外テック記事参照のサブエージェント・レビュー駆動、`research/`に全ラウンド記録)**: (1)**失敗時自動ロールバック**(install.ps1: 成果物生成後に失敗したらサービス解除+プロセスkill+サービス消滅待ち+InstallRoot削除(storage退避)+ARP/ショートカット削除。半インストール状態を残さず"既存あり"で再実行が詰む問題を根治)、(2)**ARP登録**(「プログラムと機能」に表示、UninstallStringは自己昇格cmd)、(3)**自己昇格ダブルクリック`Uninstall-OTE-RAG.cmd`**(UAC自動昇格、完全削除は二段確認、終了コード判定)+デスクトップショートカット、(4)**堅牢アンインストール**(パス限定プロセスkill+サービス消滅30秒待ち+個別try/catch、keep-data退避失敗時はappを消さず文書保護)、(5)**非エンジニアUX**(顧客可視メッセージ日本語化、ping起動待ちをexit3で失敗表示しない/ランチャーHTMLへ、Mutex多重起動防止、C:容量preflight、EstimatedSize)。詳細レビュー: `research/installer-review-round3-converged-2026-07-24.md`・`research/uninstaller-recovery-review-round3-2026-07-24.md`。**スコープ外(別トラック)**: コード署名(証明書要), -Force /MIRアップグレード, QuietUninstall昇格。
> - **残り=ユーザーによるWindows実機インストール＋動作検証**: 上書き時はまず**旧インストールをアンインストール**(現C:\LocalRAGProdには即用の`Uninstall-OTE-RAG.cmd`配置済み。または「プログラムと機能」/デスクトップの「OTE-RAG アンインストール」)→`OTE-RAG-Setup.exe`ダブルクリック(UAC, InstallRoot=C:\LocalRAGProd/Port=3005で検証中)。検証項目: **白書PDF投入→質問→引用モーダルに出典p.表示**、think:false/P1の回答品質、失敗時ロールバック挙動、サービス制御/GPU、(可能なら)ネット遮断でのオフラインインストール。ログ=`C:\ProgramData\OTE-RAG\InstallerLogs\`。
>
> --- 以下は前セッション(2026-07-21)の記録 ---
> **【2026-07-21 Claude】P1（拒否前の自動言い換え再検索）実装・検証完了。gemma4空回答→think:false採用。P2→不採用**
> 下の【2026-07-18続き】で合意したP1を実装し、`scripts/ambiguous-eval.py`で検証まで完了した。**Q4曖昧版「三文書っていつ決まった？」がOKに回復**（最終回答「令和4年12月16日」）。
>
> **実装（共有モジュール化, fork未コミット）**:
> - 新規 `server/utils/chats/queryReformulation.js` に集約。検索が弱いとき(0件 / dense実スコア無し(全FTS専用ヒットでscore=null) / 最高スコア<閾値)だけ、質問を公式語彙へ1回言い換え(gemma4)→再検索→**非破壊マージ**(元＋再検索をid/textで重複排除、スコア降順、cap=max(topN,元件数)＝元の結果を絶対に減らさない)。
> - **重要な設計修正**: 評価も外部APIも `stream.js`(UI経路)ではなく **`server/utils/chats/apiChatHandler.js`(`chatSync`/`streamChat`)** を通る。P1依頼書は「stream.jsに挿入」としていたが、それだけでは評価も本番APIも効かない。→ **stream.js＋apiChatHandlerの計3経路**に配線した（共有ヘルパー呼び出し1行ずつ）。
> - gate: `QUERY_REFORMULATION=true`（`runtime/docker-compose.yml`に追加, 既定OFF）。閾値: `QUERY_REFORMULATION_MIN_SCORE`（既定0.45）。**実測で閾値決定**: 曖昧版Q4最高score0.401(日付取得できず) / 言い換え拡張クエリで日付チャンクをscore0.672取得 / 明確版0.645(素通し)。gemma4の言い換えは「三文書 …国家安全保障戦略… 閣議決定 いつ」と公式語彙を補えることを実測確認。
>
> **検証（ambiguous-eval, P1有効）**: 明確版14/15・曖昧版12/15。**Q4曖昧版=回復(OK)**。P1発火は全30問中2問のみ(Q4・Q14の曖昧版、他28問は検索が十分強く素通し)、エラーゼロ、Q14はOK維持＝**選択的・非破壊で回帰なし**。
> - **gemma4空回答/think暴走【2026-07-21 解決・think:false採用確定】** — `docs/GEMMA4_EMPTY_ANSWER_INVESTIGATION_2026-07-21.md`。空回答NG(Q06/Q07/Q30曖昧版等)の**原因**: gemma4はOllamaで`thinking`と`content`を分離返却し、プロバイダが`<think>${thinking}</think>${content}`で結合(`ollama/index.js`)。temp=0で`thinking`が反復暴走(実測~18,000字)し**`content`(最終回答)が空**→評価が`<think>`除去で空文字→NG(実行間で移動する非決定性)。**対策**: `OLLAMA_DISABLE_THINKING=true`(env, `ollama/index.js`のchat呼び出しに`think:false`条件付与)を実装。**A/B結果(採用確定)**: think OFF+P1で **ambiguous 15/15+15/15(満点・2回完全一致で決定的)・空回答ゼロ**、hakusho **27〜28/30**(think ON基準26/30を上回る)、生成**約40倍高速**(20.8s→0.5s)。→ `runtime/docker-compose.yml`で製品既定ON。
>
> **コミット済み【2026-07-21】**: fork(local-only) `3bdacb2e`(P1の3ファイル) ＋ think:false(`ollama/index.js`, 下記で追加コミット) / localRAGルート `f86944f`(P1 env)・`121632b`(gemma4調査)＋think:false採用の追加コミット。**先行cushion系4ファイルのステージ(M/M/M/A)とCodexのアイコン変更は巻き込まず温存**。push無し(fork=origin無し, ルート=要ユーザー確認)。devコンテナ(image 1.0.6)へP1＋think:false反映済み(※`docker compose up -d`で再作成するとcp済みP1が消えるので、env変更時はP1 3ファイルの再cpを忘れない)。評価後のチャット履歴・APIキーはクリーンアップ済み。
>
> **P2 プロンプト1ルール追加【2026-07-21 A/B検証 → 不採用・revert済み】**: 既定プロンプトにルール9(限定句・定義・主語の照合＋脚注/括弧根拠化)を追加しA/B。**初版・軟化版とも net-negative**。(1)狙ったhakusho (e)新司令部を改善せず(28.5→28.0で横ばい)、(2)ambiguous Q07「かがに降りた戦闘機」を**決定的に過剰拒否**(初版=曖昧版NG, 軟化版=明確版NGへ移動)＝ルール3(意味一致なら答える)と衝突。**根因**: 狙った候補混同failure(Q1/Q2/Q4型)は既にthink:false+P1で解消済みで、ルール9は「解決済みの問題」に制約を足して裏目に出た。→ **両ファイル(systemSettings.js/prompt-tuned.txt)をルール8状態へrevert済み、コンテナも復旧**。詳細ログ: scratchpad/p2-before.log・p2-after.log・p2-soft.log。
>
> **現ベースライン確定値(think:false + P1 + ルール8)**: ambiguous **15/15 + 15/15**(決定的)、hakusho **28〜29/30**(平均28.5)。残るhakusho NGは既知の2件のみ: **(b)個室化=チャンク境界の語中分断→P4(chunkOverlap増強)の領域**、**(e)新司令部=回答が「2025年3月」で「24日」精度が欠落**(think:false前は2006年誤答だったが失敗モードが変化)。
>
> **次の一手候補**: (a)**P4 chunkOverlap増強**で(b)個室化を狙う(要・全文書再embed＋30問再評価)、または(b)**P3 問い返し機能**(複数文書ワークスペースでの過少指定シナリオが主戦場、単一文書の現eval では効果測定しにくい)。プロンプト系(P2)は現ベースラインでは伸びしろが乏しいと判明したため優先度を下げる。
>
> **【2026-07-18続き】精度向上の原因分析2件が完了、P1〜P4の改善計画を合意（P1は上記で完了）**
> 直前エントリ（本ファイル次項）で画面精度回帰を解決しhakusho-eval 26/30を再現した後、ユーザー要望「精度を下げている要因の分析」「曖昧な質問への耐性評価」「曖昧質問を具体化する問い返し機能」に対応してサブエージェント2体で分析を実施。**コード変更はまだ一切していない（分析のみ）**。次にやるべきことは下記P1から。
>
> **① 失敗4問（26/30のNG分）の原因分析** — `docs/EVAL_FAILURE_ANALYSIS_2026-07-18.md`
> 実retrievalで実測した結果、**検索スタック(hybrid/cushion/rerank)起因の失敗はゼロ**。内訳:
> - Q1(三文書の閣議決定日,拒否)・Q2(防衛関係費歳出額,87,005億と誤答)・Q4(新司令部発足時期,2006年と誤答) → **3問とも正解チャンクはtop8に取得済みなのに生成側が紛らわしい併記から選び損ねる**（脚注形式の日付を拒否／字面が質問に似た罠の数値87,005億を選択／無関係な旧司令部の年代が混入した偽装チャンクを選択）。
> - Q3(営内隊舎の個室化,拒否) → 唯一の構造問題。正解文が「海上・航空自｜衛隊」で**チャンク境界の語中分断**、rerank:trueでも言い換えでもtop8圏外。プロンプトでは救えない。
>
> **② 曖昧質問への耐性評価（新規構築）** — `docs/AMBIGUOUS_QA_EVAL_2026-07-18.md`、再実行可能スクリプト `scripts/ambiguous-eval.py`
> 既存30問から15問を選び実ユーザー風の曖昧版（省略/指示語/口語/過少指定/誤字）を作成し明確版と対比。**明確版15/15・曖昧版14/15**、想定より頑健だった。
> - 唯一の失敗は「三文書って**いつ決まった**？」＝口語「決まった」が公式語彙「**閣議決定**」に検索で届かない**語彙ギャップ**（拒否のみ、誤答・ハルシネーションはゼロ）。追試で「閣議決定」を含む言い換えなら正答すると実証済み。
> - 過少指定型（「防衛費いくら？」等）はキーワード採点はOKだが**単一回答でなく複数候補の列挙**で答える（内容は白書に忠実）。単一直接回答率なら曖昧版は実質11/15相当。
> - **単一文書での評価**。複数文書ワークスペースでは過少指定型の成績がさらに下がる見込み＝ここがユーザー構想の「問い返し機能」の主戦場。
>
> **③ ユーザーと合意した改善計画（P1→P2→P3→P4の順、いずれも未着手）**
> - **P1 拒否前の自動言い換え再検索** ✅**【完了 2026-07-21・最上部ブロック参照】**（効果:実証済み・リスク:小・最優先）: 検索が弱い(スコア低/0件)ときだけ、LLMに質問を公式語彙へ1回言い換えさせ再検索してから回答。※実装時に判明: 挿入先は`stream.js`だけでは不足で`apiChatHandler.js`(評価/API経路)にも必要 → 共有モジュール`queryReformulation.js`化。曖昧評価でQ4が回復。
> - **P2 プロンプト1ルール追加** ❌**【2026-07-21 A/B検証で不採用・最上部ブロック参照】**（当初見込み:26/30→29/30）: 既定プロンプトに「質問の限定句と候補記述の定義・主語を照合してから選ぶ。脚注・括弧内も根拠として扱う」を追加。→ **hakusho改善せず・Q07を過剰拒否で退行。狙ったfailureはthink:false+P1で既に解消済みだった**。`server/models/systemSettings.js`の既定プロンプト＋`fixtures/local/prompt-tuned.txt`を同期。追加後は必ずhakusho-eval 30問を再実行し他カテゴリの萎縮（過剰拒否化）がないか確認するサイクルで進める。**このファイルは先行セッション(cushion系)の未コミット作業と同居するため編集は慎重に**（下記「現在の状態」参照）。
> - **P3 問い返し(clarification)機能**（ユーザー本人の構想）: 一律ではなく**発動条件を絞る**（①P1の言い換えでも検索が弱い、②検索候補が複数文書/複数トピックに割れている、のときだけ）。検索上位チャンクから動的に選択肢を生成し、「どの資料ですか？」→ 既存の`searchDocumentIds`（文書スコープ指定、コミット済み機能）を設定して再検索、または「どの観点ですか？」→キーワード付与して再検索。バックエンド(stream.jsに`clarification`型応答)＋フロント(選択肢ボタン)の両方が必要。複数文書ワークスペースでの過少指定シナリオで検証。
> - **P4 chunkOverlap増強**（Q3対策・優先度低）: チャンク分割の重なり幅を増やし語中分断を軽減。既存文書の再取り込みと30問再評価が必要。
>
> **現在の状態（2026-07-18時点）**:
> - fork（`repos/localRAG/anything-llm`, branch `product/customer-rag-base`）: 分析セッション中のコード変更なし。作業ツリーに残るのは**先行セッション（cushion/hybrid関連）がステージした4ファイル**のみ（`server/models/systemSettings.js` M・`server/utils/EmbeddingRerankers/native/index.js` M・`server/utils/vectorDbProviders/lance/index.js` M・`server/utils/vectorDbProviders/lance/sentenceCushion.js` A）。これは本セッションの担当外・未接触。**fork には origin remote が設定されておらず（`upstream`のみ）、コミットは全てローカルのみでpush不可という設計**（CLAUDE.md記載どおり、意図的）。
> - localRAGルート: `docs/EVAL_FAILURE_ANALYSIS_2026-07-18.md`・`docs/AMBIGUOUS_QA_EVAL_2026-07-18.md`・`scripts/ambiguous-eval.py`をコミット済み（`c956dd7`）。origin/mainへのpushは未実施（要ユーザー確認）。
> - devコンテナ: `localrag-anythingllm:1.0.6`が稼働中(healthy)。ソースとコンテナのファイルは主要6ファイルで完全一致を確認済み（drift無し）。ワークスペース設定=`chatMode:query, openAiTemp:0, topN:8`（ベンチ構成一致）。文書=防衛白書1件のみ。チャット履歴・APIキーはテスト後に0件までクリーンアップ済み。
>
> **次セッション最初の一手**: ~~P1（自動言い換え再検索）の実装から~~ → **P1は2026-07-21に実装・検証完了（最上部ブロック参照）**。次はgemma4の空回答/think暴走の調査、その後P2。

> **[Claude 2026-07-18] 画面利用の精度回帰を根本解決、dev image 1.0.6化、hakusho-eval 26/30を製品経路で完全再現**
> ユーザー報告「画面から使うと何を聞いても『記載なし』、ベンチ精度と不一致」を調査。原因は3層:
> (1) **稼働devコンテナがimage 1.0.5のままで日本語PDF字間空白fix未搭載** → 画面から取り込んだ白書テキストに空白3,466箇所混入し検索全滅（HANDOFF既記載の「image再ビルド必須」ブロッカーが画面利用で顕在化）。→ **image 1.0.6を現ソースから再ビルドし切替**（cushion/hybrid/調整プロンプト/全修正同梱、`docker cp`パッチ依存を解消）。WSL2 DNS不調でビルド2回失敗→**7ホストのadd-host固定**で成功（composeにコメント記録）。
> (2) **upstreamのWorkspace.newがchatMode:"automatic"をハードコード** → gemma4+ollama(ネイティブツール対応)で全質問がエージェントループへ吸われRAG注入路を通らない。→ 既定を修正。
> (3) **ベンチ(hakusho-eval)はmode=query・temperature=0で計測**、製品はchat・temp未固定だった。→ 新規WS既定をquery/temp0/日本語refusalに統一（fork `766304e1`）。プロンプトはprompt-tuned.txt≡既定を検証済み（空行差のみ）。
> さらに**出典表記を[CONTEXT n]→文書名に修正**（`91d4d255`: fillSourceWindowで本文冒頭に（出典: ファイル名）注入＋ollamaプロバイダでヘッダ昇格。プロンプト指示だけではgemma4が従わないと実測）。履歴に旧[CONTEXT n]回答があると模倣汚染が起きる点に注意（検証時は履歴クリア）。
> **検証: 防衛白書を製品経路(parse→embed)で再取り込み（空白0箇所）→ hakusho-eval 30問を製品と同一WSで実行し26/30（a7/8 b4/6 c6/6 d5/5 e4/5）＝ベンチ実績と完全一致**。エージェント既定スキルはmemoryのみ（docSummarizer/webScraping除外済み、監査`docs/AGENT_SKILLS_AUDIT_2026-07-18.md`）。全データワイプ実施済みのため**旧イメージで取り込んだ文書は要再アップロード**。本日のfork変更は多数コミット済み（i18n誤訳一掃/ドロップ=RAG埋め込み化/資料管理画面/検索スコープ指定/進捗バー等）、未コミットは先行セッションのcushion系4ファイル（ステージ済み）のみ。

> **[Claude UI改善 2026-07-17] 「お手軽UI」の具体的欠陥2点を修正（fork未コミット・要v1.2.0再ビルド）**
> ユーザー指摘「お手軽さが売りなのにUIは本当に簡単・分かりやすいか」を受けフロントを点検。主要動線は既に独自ホーム（`frontend/src/pages/Main/Home/index.jsx`）でワークスペースを裏側自動生成する簡易化＋i18n対応済みと確認できた（＝当初懸念の「ワークスペース概念の露出」はハッピーパスでは概ね解消済み）。残る具体的欠陥2点を修正:
> 1. **ドラッグ&ドロップのオーバーレイ文言が英語ハードコード**（"Add anything" / "Drop a file or image here to attach it to your workspace auto-magically"）。日本語UI製品の一番の見せ場で英語が出ていた。`i18n`化（`dnd.title`/`dnd.description`をen/ja `common.js`に追加、`DnDWrapper/index.jsx`で`useTranslation`使用）→日本語「ここに追加／ファイルや画像をここにドロップすると、資料として取り込みます。」。
> 2. **設定画面のLLMプロバイダー選択に40種超のクラウドLLM（OpenAI/Anthropic/Gemini等）が残存**。非エンジニアがAPIキー欄に迷い込む余地＋選んでもバックエンドallowlist（`server/utils/helpers/index.js`）で拒否され起動不能になる事故源。`GeneralSettings/LLMPreference/index.jsx`に`DISTRIBUTABLE_LLM_PROVIDERS`（バックエンドallowlistと一致するローカル系のみ）を追加し表示一覧をこれに限定。
> - **検証**: `eslint`（変更4ファイルclean）＋`vite build`成功（exit 0）。※実UIでの目視は要dev/再ビルド。
> - **未了**: 4ファイルは**fork（`product/customer-rag-base`）のワーキングツリーに未コミット**。配布へ反映するには image再ビルド→v1.2.0再ビルドが必要（既存の「cushion/hybrid未コミット＋要image再ビルド」ブロッカーと同じ扱い）。コミットはユーザー確認待ち。
> - **未対応（別判断）**: 「士業向け定型プロンプトテンプレート」はアイデアファイルの差別化点だが未実装。ただしユーザーより「ターゲットは士業に限定しない」旨の指示があったため今回スコープ外。

> **[Codex Windows GUI実機導入 2026-07-17] 修正版ワンクリックインストール＋基本動作確認 PASS**
> 初回実行はGUIの長い一時展開先（ユーザープロファイル配下）により深いnode_modulesの89ファイルが展開されず、内部checksumで停止した。`windows-native/setup/OTE-RAG-Setup.cs`の展開先を短い`C:/OTR/<timestamp>`へ変更し、ZIP最長232文字の2ファイルを最終フルパス最大255文字で実展開PASS後、Setup.exeを再ビルドした。修正版Setup SHA-256=`61af9b89c2dc0dabbb453021f3d80a3bd20420c2a01f676b565785b63ce90107`。失敗時の専用一時フォルダ（約13.2GB）と空の`C:/LocalRAGProd`だけを削除して再試行した。
> 再試行は外側SHA、`C:/OTR`展開、内部checksum、`C:/LocalRAGProd`配置、DB migration、3サービス登録・自動起動まで完走（12:39:19）。`LocalRAG-Server/Collector/Ollama`=Running、localhost `3005/8888/11435`=Listen。HTTPはUI=200、`/api/ping`=online true、Collector=`OK`、Ollama=0.31.2。モデルは`gemma4:12b`と`bge-m3:latest`、日本語embed=1024次元、Gemma生成=`動作確認完了`（done_reason=stop）。各サービスerr.log=0 bytes。ログ=`C:/ProgramData/OTE-RAG/InstallerLogs/setup-20260717-123416.log`。残る出荷確認はAuthenticode署名、再起動耐性、完全オフライン、APIキー＋文書投入を伴うRAG E2E。コミット/push未実施。
> **[Codex one-click installer 2026-07-17] OTE-RAG-Setup.exe distribution is ready**
> Final distribution is the three files in `C:/LocalRAG/dist`: `OTE-RAG-Setup.exe`, `OTE-RAG-win64-v1.2.0.zip`, and its `.zip.sha256`. Double-click Setup.exe -> UAC -> GUI -> outer SHA verification -> tar extraction -> existing install.ps1 -> browser launch. New ZIP SHA-256=`7f49942ce9387bfc6922a485f43debef6fce0f27c272823c643b36cdbe5911ff`; full extracted internal verification PASS=100,635 FAIL=0; positive verify exit=0; intentional bad SHA rejected with exit=2; packaged `Install-OTE-RAG.cmd --self-test` PASS. Report=`docs/WINDOWS_DOUBLE_CLICK_INSTALLER_V1.2.0_2026-07-17.md`. The real UAC install has since passed; see the block above. Setup.exe is unsigned because no code-signing certificate is installed; signing remains a formal-release task. No commit/push.


> **[Codex cleanup 2026-07-17] Removed obsolete models, old packages, and verification environments**
> Kept `C:/LocalRAG/dist/LocalRAG-win64-v1.2.0.zip`, source, and `build-deps`. Windows/WSL model stores now retain only `gemma4:12b` and `bge-m3`; old llm-jp/llama3.1/mxbai/qwen3, the candidate reranker, JQaRA caches, v1.0/v1.1 packages, extracted package trees, and Round2 temp scripts/logs were removed. Final ZIP SHA-256 was reverified and the running API remains healthy. **The older note below saying `Run-Round2-Verify.cmd` remains is stale: administrator Round2 is still pending, but its temp runner was removed at the user's request and must be regenerated before use.**


> **【Codex最終ビルド 2026-07-17】Windows native v1.2.0 zip生成・全件検証PASS**
> 詳細: docs/WINDOWS_NATIVE_BUILD_V1.2.0_FINAL_2026-07-17.md。成果物=C:/LocalRAG/dist/LocalRAG-win64-v1.2.0.zip、11,019,463,242 bytes、SHA-256=4941ce0d8784dd9f0ab86444db92f390d3eae6c3819603f88d03d85f0ee498d7。Gemma 4 + bge-m3 + 現行reranker int8、hybrid/cushion ON。zip全展開後package.sha256 PASS=100,634 FAIL=0。残作業はユーザー管理者実行のRun-Round2-Verify.cmdのみ。

> **【Codex最終判定 2026-07-16】日本語特化リランカーは製品既定への採用見送り**
> 詳細: docs/JAPANESE_RERANKER_PRODUCT_VALIDATION_2026-07-16.md。JQaRAと配布形式はPASSしたが、士業30問は21/30・26/30（平均23.5、5点幅）で現行25/30を安定して上回らなかった。Windows v1.2.0は現行onnx-community/bge-reranker-v2-m3-ONNX int8を維持する。評価server:3006とruntime候補モデルは撤去済み、通常server:3001 healthy、コミット/push未実施。

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
