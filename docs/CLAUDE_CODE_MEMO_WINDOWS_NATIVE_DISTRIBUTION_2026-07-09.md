# Claude Code 連携メモ: Windows 配布方式の再検討

作成日: 2026-07-09

## 目的

LocalRAG の顧客配布方式について、従来の **WSL2 + Docker Engine 前提**から、
**真っさらな Windows 11 に導入できる方式**へ再検討する。

このメモは Claude Code / Codex 間で方針を共有するためのもの。
実装着手前に `docs/HANDOFF.md`、`CLAUDE.md`、本メモを読むこと。

## 前提

想定する顧客環境:

- Windows 11
- 初期状態では WSL なし
- Docker / Docker Desktop なし
- 可能なら顧客側で installer を実行するだけで導入したい
- ただし、技術的に難しい場合は IT エンジニアが導入作業を代行する方式も許容
- 顧客文書・RAG 問い合わせ・embedding は外部送信しない
- インストール後は `http://localhost:3001` などで利用する

## 検討する2方式

### A. WSL2 + Docker Engine を IT エンジニアが導入する方式

現行の成果物に近い方式。

構成:

- Windows 11
- WSL2 Ubuntu
- WSL 内 Docker Engine
- `runtime/docker-compose.yml`
- `localrag-anythingllm:1.0.2`
- Docker Ollama

長所:

- 現行の開発・検証成果をかなり活かせる
- `runtime/docker-compose.yml`、`scripts/export.sh`、`install.sh`、`rag-e2e-test.sh` がそのまま使いやすい
- Linux container 前提なので AnythingLLM の既存検証結果と差分が少ない
- 早期パイロットや社内検証には現実的

短所:

- 真っさらな Windows には WSL / Ubuntu / Docker Engine / GPU runtime の導入が必要
- WSL のオフライン導入は可能だが、管理者 PowerShell、Windows optional feature 有効化、再起動、distro 導入が絡む
- 顧客セルフ導入には重い
- 導入手順が「LocalRAG のインストール」ではなく「Windows 上に Linux 実行基盤を構築する作業」になりやすい

位置づけ:

- **保険 / パイロット方式**
- IT エンジニアが設置作業を担当する案件では許容
- ただし顧客向け本命の配布方式にはしない方がよい

### B. Windows native installer 方式

Docker / WSL なしで Windows OS 上に LocalRAG を配置する方式。

理想構成:

- Windows installer (`LocalRAGSetup.exe` / `.msi` / zip + setup)
- Windows native AnythingLLM server
- Windows native collector
- build 済み frontend
- Windows 版 Ollama、または同等の Windows LLM runtime
- 同梱済み LLM / embedding モデル
- `C:\ProgramData\LocalRAG\...` に storage / logs / models を配置
- Windows service、または tray app で起動管理

長所:

- 顧客体験が最もよい
- Docker Desktop / WSL の導入説明が不要
- 「Windows アプリを入れる」体験に近づけられる
- 将来の顧客配布・運用・サポートが単純化しやすい

短所:

- 現行 Docker 配布物とは別トラックの設計になる
- AnythingLLM の bare-metal deployment は upstream core team のサポート外
- Windows native の依存解決が未検証
- `sharp`、`@lancedb/lancedb`、`prisma`、`puppeteer`、PDF/DOCX 処理など native dependency が詰まる可能性
- `node_modules` を顧客 PC で build させるのは避けたいので、事前ビルド済み成果物を作る必要がある
- Windows 版 Ollama にモデルを完全オフライン投入できるか確認が必要
- service 化、ログ、更新、アンインストール、バックアップ設計が新規に必要

位置づけ:

- **本命候補**
- まず PoC で成立性を確認する
- PoC が通れば、この方式を顧客配布の主軸にする

## 推奨方針

優先順位:

1. **B: Windows native installer 方式を本命として PoC する**
2. **A: WSL2 + Docker Engine 方式は保険・初期パイロット用に残す**

理由:

- 顧客側で導入できる製品にしたいなら、WSL/Docker 前提は最後まで導入障壁になる
- IT エンジニア代行前提なら A は成立するが、事業として横展開しにくい
- Ollama は Windows 版が存在し、AnythingLLM も bare-metal 起動手順自体は存在するため、B は無理筋ではない
- ただし B は実装難度が読めないので、まず小さく検証する

## Windows native PoC の合格条件

まず installer は作らない。
Windows 上で Docker / WSL なしに以下が成立するか確認する。

1. AnythingLLM `server` と `collector` が Windows native Node.js で production 起動できる
2. build 済み frontend を `server/public` に配置して `http://localhost:3001` が開く
3. Windows 版 Ollama が `127.0.0.1:11434` で動く
4. 同梱またはローカル配置した LLM / embedding モデルを Ollama に読ませられる
5. AnythingLLM から Ollama に接続して TXT / PDF / DOCX の RAG E2E が通る
6. 外部 provider 拒否、Swagger 無効、出典必須・文書外不明応答が Docker 版と同等に効く

この PoC が通れば、次に installer / service 化へ進む。
通らなければ、A をパイロット方式として採用しつつ、B はランタイム差し替えや機能縮小を検討する。

## 調査・実装メモ

参照すべきローカルファイル:

- `docs/HANDOFF.md`
- `CLAUDE.md`
- `anything-llm/BARE_METAL.md`
- `runtime/docker-compose.yml`
- `scripts/rag-e2e-test.sh`
- `docs/WINDOWS_OFFLINE_MANUAL_CHECKLIST_2026-07-05.md`

特に `anything-llm/BARE_METAL.md` には、Docker なし production 起動の流れがある:

- Node.js v18+
- Yarn
- frontend build
- `frontend/dist` を `server/public` にコピー
- Prisma generate / migrate
- `server` と `collector` を別プロセスで production 起動

Windows native PoC では、まずこの手順を Windows 上で再現できるかを見る。

## 未解決の確認事項

- Windows native で `@lancedb/lancedb` が安定動作するか
- `sharp` / `puppeteer` / `pdfjs-dist` / `mammoth` / `officeparser` など collector 依存が Windows で問題なく動くか
- Prisma SQLite migration が `C:\ProgramData\LocalRAG\storage` のようなパスで問題ないか
- Ollama Windows のモデル格納場所を installer 側で制御できるか
- Ollama のモデルファイルを `ollama pull` なしで完全オフライン投入できるか
- Windows service として server / collector / Ollama をどう管理するか
- NVIDIA driver / GPU 要件を installer でどこまで面倒を見るか
- 顧客環境での firewall / antivirus / proxy / 権限問題

## 次アクション案

1. `docs/` に Windows native PoC 計画書を作る
2. Windows 側に PoC 用ディレクトリを作る
3. AnythingLLM fork の build 済み成果物を Windows native で起動する
4. Ollama for Windows + 既存モデルで API 疎通する
5. 既存 `rag-e2e-test.sh` 相当の Windows native E2E を作る
6. 結果を `docs/HANDOFF.md` に反映する

## 判断メモ

現時点の判断:

- WSL2 + Docker 方式を捨てる必要はない
- ただし、顧客配布の本命としては Windows native installer を先に検証する価値が高い
- 今後の作業は「WSL 上の install 検証」よりも「Windows native PoC」を優先する

