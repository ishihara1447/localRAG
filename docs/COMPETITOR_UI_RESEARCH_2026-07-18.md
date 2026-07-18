# 競合UI/UX調査と OTE-RAG 改善提案書

- 作成日: 2026-07-18
- 対象: OTE-RAG（`Mintplex-Labs/anything-llm` fork, branch `product/customer-rag-base`）
- 目的: 完全ローカル・日本語RAGデスクトップとして、**非エンジニアでも迷わず使える手軽さ**を最大化するためのUI/UX改善点を、有名同系統ツールの調査から抽出する。
- 注記: 各ツールの記述はWeb上の公式ドキュメント/レビュー記事に基づく（末尾に出典）。実機で全ツールを検証したわけではないため、UIの細部は「未確認」を明記した箇所がある。

---

## 0. OTE-RAG の現状インベントリ（コードを実読して確認済み）

「無い要素」を誤判定しないため、先に現状を整理する。読んだファイル:
`frontend/src/pages/Main/Home/index.jsx`, `components/Modals/DocumentManager.jsx`,
`components/WorkspaceChat/ChatContainer/DnDWrapper/index.jsx`,
`components/LocalServicesPanel/index.jsx`, `components/lib/QuickActions/index.jsx`,
`components/lib/SuggestedMessages/index.jsx`,
`components/WorkspaceChat/ChatContainer/ChatHistory/Citation/index.jsx`。

**既にあるもの（=「無い」と言ってはいけない）**
- ChatGPT風ホーム: 挨拶＋中央プロンプト入力＋クイックアクション＋サジェスト質問。メッセージ送信/ドロップでワークスペースを裏側自動生成。
- **ドロップ=ベクトルDBへ埋め込み（真のRAG登録）**。画像はビジョン添付、それ以外はparse→embed。**ファイル単位のステータス**（in_progress/embedded/failed）とエラーメッセージあり。ドラッグ中は専用オーバーレイ（アイコン＋タイトル＋説明）。
- **資料の管理モーダル**（独自実装）: 一覧・削除・追加。表示は「タイトル／取り込み日／概算語数」。空状態の案内文あり。ワークスペースは複数時のみセレクタ表示。対応拡張子は `.pdf,.doc,.docx,.txt,.md,.csv,.rtf,.html,.json`。削除はベクトルDBからのunembedまで実施。
- **ローカルサービスパネル**: server/collector/llm の状態ドット（起動中/停止中/確認中）＋起動停止ボタン。AIエンジン停止は確認ダイアログ。ヘッダのピル＋停止時の警告バナー（起動ボタン付き）。15秒ポーリング。
- 日本語UI（`locales/ja/common.js`）。
- 出典表示: upstream の Citation/SourcesSidebar を流用。関連度％（`toPercentString`）、ソース種別アイコン、原文プレビュー（モーダル/サイドバー）あり。
- クイックアクション: エージェント作成／ワークスペース編集／文書アップロード／資料の管理。
- 既定プロンプトで出典必須・文書外は「不明」を強制（ハルシネーション抑制）。

**現状で弱い/無いと確認できたもの（後述の提案の根拠）**
- 取り込みの**進捗バー/キュー可視化が弱い**（スピナー＋テキストのみ、%やN/M件表示なし）。
- **再インデックス/再取り込み（re-embed）ボタンが管理画面に無い**。
- **フォルダ/タグ/コレクション概念が無い**（全資料フラット）。資料一覧に**検索・絞り込みが無い**。
- **初回起動オンボーディングが非エンジニア向けに最適化されていない**（upstream の OnboardingFlow は残存するが、LLM選択・Survey等エンジニア前提。ChatGPT風ホームとの関係・初回ツアー/空状態の誘導は未整備）。**未確認**: fork で OnboardingFlow が実際に表示されるかは要実機確認。
- **「データは外に出ません」の安心感を伝えるUI要素が見当たらない**（最大の差別化なのにホーム/チャットに常設表示なし）。
- **出典の原文プレビューはあるが、PDF内ハイライト表示は無い**（Kotaemon対比）。
- **回答の信頼度/低関連度の警告表示が無い**（検索がスカったときに黙って答える恐れ）。
- Citation のリンク型ソースは favicon を `google.com/s2/favicons` から取得しており、**完全オフライン方針と矛盾する外部通信**（ファイル型では発火しないが要確認・要遮断）。
- DnDオーバーレイに**対応形式の明示が無い**（何を入れてよいか分からない）。

---

## 1. 各ツールの要点（強み/参考になるUI）

### LM Studio
- **オンボーディングが最速級**: 起動→モデル名/用途で検索→**DL前にRAM要件を提示**→数分でチャット。ターミナル不要層の定番。
- GPUオフロードを**スライダー＋リアルタイムVRAM推定**で見せ、内部フラグを隠蔽。難しい設定の「隠し方」の好例。
- 文書は**チャットにPDFをドロップして即質問**（2025〜）。ただし会話スコープ（indexなし）で、新規チャットで消える=継続的な資料ライブラリには不向き。→ OTE-RAGの「ドロップで永続RAG登録」は逆にここが強み。
- 参考点: **DL前のハード要件提示**、**難しい設定のスライダー化＋実測値表示**。

### Jan
- **ローカルLLM界で最もクリーンなUIと評価**。オンボーディングは「5クリック」。RAMに合うモデルを選ぶ→GGUFをDL→10分で会話。
- プライバシーを製品哲学の中心に（"Your AI, on your computer" / 推論は全てローカル / DL後はネット不要）。**プライバシー訴求をブランドの一貫したメッセージにしている**のが参考。
- 参考点: **一貫したプライバシーメッセージング**、**極小ステップのオンボーディング**。

### GPT4All（LocalDocs）
- **コレクション単位の文書管理**（`+ Add Collection` で名前を付けフォルダを紐付け）。
- **取り込み進捗を明快に可視化**: LocalDocsページに「Embedding in progress」カウンタ、完了で緑の「Ready」インジケータ。**完了前でも準備できたファイルからチャット可能**。
- チャンク→ベクトル化の流れをDBアイコンから追える。
- 参考点: **進捗カウンタ＋Ready状態の明示**、**部分的に使える漸進的可用性**、**フォルダ紐付け型コレクション**。

### Open WebUI
- **Knowledge（ナレッジベース）を明示概念**として持つ。Workspace→Knowledge→`+ New Knowledge`（名前＋説明）→ファイル追加。チャットで `#` で参照、モデルに紐付けも可能。
- **引用（citations）でLLMに渡した文脈の出所を追跡可能**（透明性・説明責任）。
- **Focused Retrieval（RAG）と Full Context（全文注入）を選択可能**。OTE-RAGの upstream「ピン留め＝全文注入」と同系。
- 参考点: **ナレッジに名前＋説明を付ける**、**引用の透明性**、**検索モードの明示切替**。

### Msty（Studio / Knowledge Stacks）
- RAGを「**Knowledge Stack**（AIに渡す一時的な参考書）」というメタファで説明。**非エンジニアに伝わる言い換え**が上手い。
- **Chunk Console / Visualizer**でチャンク分割を可視化し、サンプルクエリを試せる。**Rerank Model**、単一チャンク保持など高度設定も提供（隠して出せる）。
- ファイル/フォルダに加え、過去会話・Webリンク・プロジェクトをStackに投入可。
- **オンボーディング**: 起動時に3択（ローカルAI設定 / リモート追加 / Ollama利用[上級]）。既定でGemma系を自動DL。**DL中もアプリに進める（バックグラウンドDL＋進捗表示）**。
- 参考点: **RAGのメタファ命名**、**バックグラウンドDL＋進捗**、**上級設定の段階的開示**。

### Cherry Studio
- **フォルダをドロップで丸ごとナレッジ化**。ローカル埋め込みで「文書は端末外に出ない」を明言。
- **リアルタイム検索テスト**でチャンク品質・分割を投入前に確認できる。多様なデータ源（ローカル/URL/サイトマップ/手入力）。
- ファイル/描画/ナレッジを**統一カテゴリ＋グローバル検索**で横断管理。
- 参考点: **投入前の検索テスト（品質確認）**、**グローバル検索での横断発見性**。

### NVIDIA ChatRTX（Windows+RTX、OTE-RASGと最も対象が近い）
- **データセット=フォルダ選択**（鉛筆アイコンでパス変更）。フォルダ変更時に**自動で再ベクトル化**、時間はファイル数/サイズ依存と明示。
- **完全オフライン前提**（モデル/データDL後はネット不要）をUXとして打ち出す。
- 対応形式: txt/pdf/doc(docx)/xml/画像(png/jpg/bmp)等。**画像もデータ源**に含む。
- 参考点: **フォルダ丸ごと指定＋自動再インデックスの状態表示**、**Windows/RTX層向けのオフライン訴求**。競合として最も直接的。

### Kotaemon（Cinnamon, OSS）
- **引用UIが白眉**: **ブラウザ内PDFビューアで該当箇所をハイライト表示**、関連度スコア付き。回答の裏取りが視覚的に即座にできる。
- 表/図を含むマルチモーダル文書、**ハイブリッドRAG（全文＋ベクトル＋リランク）**（OTE-RAGと同系の構成）。
- **低関連度しか返らないときに警告を出す**（＝スカった質問を黙って答えない）。
- 参考点: **原文ハイライト付き引用**、**低関連度の警告**。OTE-RAGの信頼性訴求と最も相性が良い。

### Chatbox
- 汎用チャットクライアント。ローカル/クラウド両対応、クリーンなクロスプラットUIが評価。RAG/ナレッジ管理は上記勢ほど厚くない（**未確認**部分あり）。参考優先度は低。

### AnythingLLM（upstream / Desktop）— 流用可能性の母体
OTE-RAGはこの fork なので、**upstreamに既にある機能=低コストで流用可能**。
- **Document Pinning**: 埋め込み済み文書を全文注入（＝Open WebUIのFull Context相当）。UIは既存。
- **Automatic Document Sync（Watch）**: 埋め込み済みファイルに「目」アイコン、10分毎に変更検知→自動re-embed（全ワークスペース反映）。**フォルダ単位のwatchは未対応**。
- **Embedder変更時は全文書delete＋re-embedが必要**（OTE-RAGのCLAUDE.md制約と一致）。
- 2ペインの ManageWorkspace モーダルは非エンジニアには過剰、という現状課題（OTE-RAGは独自DocumentManagerで既に簡素化済み）。

---

## 2. OTE-RAG に反映すべき改善アイデア（優先度付き）

各項目: 効果 / 実装コスト / upstream流用可否 / 全体最適コメント。
コストは「シンプルな変更から細かく積む」前提での相対見積り。

### P0（手軽さ・信頼という核心価値に直結。まず着手）

**A. 取り込み進捗の可視化強化（スピナー→件数＋進捗＋Ready）**
- 効果: 高 / コスト: 小 / upstream流用: 一部（`embedProgress`/`ATTACHMENTS_PROCESSING/PROCESSED` イベントが既存、UIに出すだけ）
- 現状はスピナーとステータス文字のみ。GPT4Allの「N/M件・Embedding in progress・完了でReady」を踏襲し、DnD直後とDocumentManagerに**進捗バー＋完了トースト**を出す。埋め込みは時間がかかるので「今なにが起きているか」を必ず見せる。
- 全体最適: 「入れた→ちゃんと入った」の確信は本製品の生命線。局所装飾でなく、ドロップ/追加/管理の全経路で同じ進捗表現に統一すると一貫性が出る。

**B. 「データは外に出ません」プライバシー常設表示**
- 効果: 高 / コスト: 小 / upstream流用: 不可（新規、ただし静的表示のみで軽い）
- Jan/ローカルAI勢の中心訴求。ホームの挨拶付近＋チャットフッタに**小さな常設バッジ**（例: 「🔒 すべてローカルで処理。文書は外部に送信されません」）。設定に「オフライン動作の確認（機内モードで試す）」の一文も有効。
- 全体最適: 最大の差別化を毎画面で無言に補強する。守秘業務ユーザーの購買・継続の理由そのもの。安っぽくならないようトーン統一（LocalServicesの状態ドットと同じデザイン言語で）。

**C. 出典の原文ハイライト・プレビュー強化（Kotaemon型）**
- 効果: 高 / コスト: 中 / upstream流用: 一部（Citation/原文プレビューは既存。ハイライト/PDFビューアは追加）
- 現状は関連度％＋テキストプレビュー。まず**チャンク前後の文脈と一致箇所ハイライト**（テキストレベル）を強化。PDFインラインビューアは中〜大なので後段。
- 全体最適: 「出典必須」を既定にしている製品思想と直結。裏取りが容易＝ハルシネーション不安の解消＝信頼。飾りでなく核心価値の可視化。

**D. 低関連度の警告（Kotaemon型「その質問は資料に無いかも」）**
- 効果: 高 / コスト: 中 / upstream流用: 不可（リランカー/検索スコアは既にあるので閾値判定を足す）
- ハイブリッド検索＋bge-rerankerのスコアが低い場合、回答前に**「関連する資料が見つかりませんでした／確信度が低いです」**を提示。既定プロンプトの「文書外は不明」をUI側からも補強。
- 全体最適: 出典必須・不明許容の思想と一貫。非エンジニアが誤答を鵜呑みにするリスクを構造的に減らす。

### P1（発見容易性・管理性。手軽さの底上げ）

**E. DnDオーバーレイ/空状態に対応形式と手順を明示**
- 効果: 中 / コスト: 小 / upstream流用: 該当（`t("dnd.*")` 文言変更のみ）
- 「PDF / Word / テキスト等をここにドロップ」と**対応形式を明示**。DocumentManagerの空状態文言（既にあり）と表現を統一。
- 全体最適: 最初の1問前の詰まりを消す。文言だけなので即着手向き。

**F. 資料一覧に検索・絞り込み**
- 効果: 中 / コスト: 小 / upstream流用: 不可（クライアント側フィルタで足りる）
- 資料が増えると現状のフラット一覧は破綻。**名前での絞り込み入力**を1つ足すだけで発見性が上がる。件数表示は既存。
- 全体最適: Cherry Studioのグローバル検索の軽量版。管理画面の実用性を底上げ。

**G. 再取り込み/再インデックス（re-embed）ボタン**
- 効果: 中 / コスト: 中 / upstream流用: 可（ManageWorkspace の Watch/再embedロジックが母体。ただし単発re-embedのAPI経路確認要）
- 文書更新後に**その資料だけ入れ直す**導線。まずは「削除→再追加」の2手を1ボタン化する軽量版から。
- 全体最適: 実運用（版が変わる契約書・規程類）で効く。士業ユースと相性良。

**H. AIエンジン/モデルの状態を非エンジニア語で（＋初回DL進捗）**
- 効果: 中 / コスト: 中 / upstream流用: 一部（LocalServicesは既存。モデルDL進捗表示は新規）
- LocalServicesPanelは既に良い（起動中/停止中を日本語で）。追加で、初回のモデル取得やウォームアップ中に**「AIエンジンを準備中… （数分）」の進捗**を出す（Msty/LM StudioのバックグラウンドDL＋進捗が手本）。
- 全体最適: 「無反応で固まった?」という初回離脱を防ぐ。既存パネルの言語に揃えれば一貫。

### P2（構造・拡張。急がない）

**I. フォルダ/タグ（軽量コレクション）**
- 効果: 中 / コスト: 大 / upstream流用: 一部（ワークスペース概念を隠したまま導入する設計が必要）
- GPT4Allのコレクション、Msty Stack、Cherryのフォルダ相当。ただしワークスペースを表に出さない現方針と衝突しやすい。**当面はタグ1階層など最小構成**に留め、乱用しない。
- 全体最適: 早すぎる構造化は手軽さを損なう。資料件数が実運用で増えてから。局所最適の誘惑に注意。

**J. 投入前の検索テスト（Cherry/Mstyの品質確認）**
- 効果: 低〜中 / コスト: 中 / upstream流用: 不可
- 「この資料でうまく引けるか」を投入時に試せる。非エンジニアには過剰の懸念。**上級者向けに折りたたみ**で。
- 全体最適: 段階的開示（Msty流）で普段は隠す前提なら一貫性を壊さない。

**K. フォルダ丸ごと取り込み＋Watch（ChatRTX/AnythingLLM Watch）**
- 効果: 中 / コスト: 大 / upstream流用: 可（Automatic Document Sync が母体。ただしフォルダwatchはupstream未対応）
- 共有フォルダの規程類を自動追随。強力だが完全オフライン/守秘の検証項目が増える。ヒアリングで需要確認後。
- 全体最適: 需要未検証のうちは投資しない。核心仮説A（士業ヒアリング）検証後の候補。

### 要対応（バグ寄り・提案とは別枠）

**X. Citation のリンク型 favicon 外部取得を遮断**
- 効果: 高（方針遵守）/ コスト: 小 / upstream流用: 該当箇所の修正
- `Citation/index.jsx` が `google.com/s2/favicons` を叩く。ファイル型RAGでは通常発火しないが、**「顧客文書を外部に送信しない/完全オフライン」方針とUI由来の外部通信は矛盾**。ローカルアイコンにフォールバックし外部取得を止める。**未確認**: 実際に発火する経路があるか要確認だが、方針上は塞ぐべき。

---

## 3. 実装順の提案（シンプル→全体最適）

「単発の飾り」を避け、**製品の一貫した価値=手軽さ・ローカル信頼**を各ステップで太らせる順にする。

1. **文言・静的表示だけで効く層（コスト小・即日）**
   - E（DnD/空状態に対応形式）、B（プライバシー常設バッジ）、X（favicon外部取得の遮断）。
   - まずリスク・工数が小さく、ブランドメッセージ（ローカル/安心/手軽）を全画面に浸透させる。

2. **既存イベント/データを可視化する層（コスト小〜中）**
   - A（取り込み進捗＋Ready）、F（資料一覧の絞り込み）。
   - 既にある `embedProgress`/ステータス/件数を「見せるだけ」。手軽さの体感が一段上がる。

3. **信頼性の中核を強化する層（コスト中）**
   - D（低関連度の警告）、C（出典ハイライト強化）。
   - 「出典必須・文書外は不明」という製品思想をUIで完成させる。差別化の核。

4. **運用機能（コスト中）**
   - G（再取り込み）、H（モデル準備の進捗/非エンジニア語）。
   - 実運用の摩擦を消す。ここまでで非エンジニア向けの一貫体験が概ね揃う。

5. **構造・拡張（コスト大・需要検証後）**
   - I（タグ）、K（フォルダwatch）、J（検索テスト）。
   - 核心仮説A（士業ヒアリング）で需要が確認できてから。早すぎる構造化で手軽さを壊さない。

**全体最適の指針**: 個々の画面に機能を足すより、「入れる（取り込み）」「聞く（チャット）」「確かめる（出典）」「安心する（ローカル）」の4動線が**同じデザイン言語・同じ日本語トーン**で貫かれている状態を優先する。LocalServicesの状態ドット・DocumentManagerの空状態文言など既存の良い部品の表現に新規要素を揃えること。

---

## 出典（Sources）

- LM Studio: [Chat with Documents (公式)](https://lmstudio.ai/docs/app/basics/rag) / [LM Studio Review 2026](https://aifoss.dev/blog/lm-studio-review-2026/) / [LM Studio vs Jan 2026](https://www.kunalganglani.com/blog/lm-studio-vs-jan) / [Local AI Apps With Built-In RAG](https://www.promptquorum.com/power-local-llm/local-ai-app-with-built-in-rag)
- Jan: [Jan AI Review 2026 (WeavAI)](https://weavai.app/blog/en/2026/04/24/jan-ai-review-2026-free-open-source-local-ai-app/) / [Techno360 Jan Review](https://techno360.in/jan-ai-review-the-best-free-open-source-offline-ai-app-to-run-llms-on-your-pc/) / [Jan Docs](https://www.jan.ai/docs)
- GPT4All: [LocalDocs (公式)](https://docs.gpt4all.io/gpt4all_desktop/localdocs.html) / [LocalDocs Wiki](https://github.com/nomic-ai/gpt4all/wiki/LocalDocs) / [Testing GPT4All LocalDocs](https://kurkista.fi/2025/08/22/from-pdfs-to-conversations-testing-gpt4alls-localdocs/)
- Open WebUI: [Knowledge (公式)](https://docs.openwebui.com/features/workspace/knowledge/) / [RAG (公式)](https://docs.openwebui.com/features/chat-conversations/rag/)
- Msty: [Knowledge Stack RAG explained](https://docs.msty.app/features/knowledge-stack/rag-explained) / [Knowledge Stacks Overview](https://docs.msty.studio/features/knowledge-stacks/overview) / [Onboarding](https://docs.msty.app/getting-started/onboarding) / [Download Offline Models](https://docs.msty.app/how-to-guides/download-offline-models)
- Cherry Studio: [Complete Guide 2026](https://codersera.com/blog/cherry-studio-complete-guide-2026/) / [Knowledge Base Data (公式)](https://docs.cherry-ai.com/docs/en-us/knowledge-base/data) / [In-Depth Review](https://skywork.ai/skypage/en/Cherry-Studio:-An-In-Depth-Review-of-the-All-in-One-AI-Desktop-Client/1972882990813605888)
- NVIDIA ChatRTX: [User Guide (公式)](https://nvidia.custhelp.com/app/answers/detail/a_id/5542/~/nvidia-chatrtx-user-guide) / [GitHub NVIDIA/ChatRTX](https://github.com/NVIDIA/ChatRTX) / [MS Power User guide](https://mspoweruser.com/how-to-use-chat-with-rtx-the-local-ai-chatbot-by-nvidia/)
- Kotaemon: [GitHub Cinnamon/kotaemon](https://github.com/Cinnamon/kotaemon) / [Kotaemon 紹介](https://prompts.brightcoding.dev/blog/kotaemon-your-next-favorite-rag-based-chat-tool)
- AnythingLLM (upstream): [Automatic document sync](https://docs.anythingllm.com/beta-preview/active-features/live-document-sync) / [Using Documents](https://docs.anythingllm.com/chatting-with-documents/introduction) / [Document Management (DeepWiki)](https://deepwiki.com/Mintplex-Labs/anything-llm/8.2-document-management)
- プライバシーUI: [Local AI Privacy Guide 2026](https://localaimaster.com/blog/local-ai-privacy-guide)
- GUI比較（横断）: [GUIs for Local LLMs with RAG (S. Turner)](https://blog.stephenturner.us/p/gui-local-llm-rag)
