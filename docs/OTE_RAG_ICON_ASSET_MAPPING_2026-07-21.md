# OTE-RAG アイコン反映対応表

作成日: 2026-07-21
対象: Claude Codeによるアイコン反映確認・再ビルド

## 目的

OTE-RAGの新アイコンを、開発ソース、ブラウザ表示、Windowsショートカット、セットアップ実行ファイル、配布ZIPへ一貫して反映する。

新アイコンの意味は次のとおり。

- 文書2枚: 顧客のローカル資料
- 検索レンズ: RAG検索・検索結果の取得
- レンズ内の日の丸: 日本製
- 右上のスパーク: AIによる回答生成

## 原本と成果物の対応

| 区分 | ファイル | 役割 | 対応 |
|---|---|---|---|
| 原本SVG | `anything-llm/frontend/src/media/logo/localrag-icon.svg` | 製品UI内でimportされる主アイコン | **最優先の原本**。ここを直接編集し、他の画像をここから生成する |
| ブラウザ画像 | `anything-llm/frontend/public/favicon.png` | ブラウザタブ、PWA manifest、通知アイコン、Windowsランチャー画面 | 原本SVGから64x64 PNGを生成する |
| favicon互換 | `anything-llm/frontend/public/favicon.ico` | ICOを参照するブラウザ・互換経路 | 原本SVGから32x32 ICOを生成する |
| Windowsアイコン | `windows-native/launcher/LocalRAG.ico` | Windowsショートカットとセットアップ実行ファイルのアイコン | 原本SVGから64x64 ICOを生成する。ファイル名は内部互換のため当面変更しない |
| ランチャー画面 | `windows-native/launcher/LocalRAG.html` | 起動後のブラウザランチャー | ソース上で `/favicon.png` を参照済み。通常はHTMLを編集せず、更新済みfavicon.pngを同梱する |
| セットアップ定義 | `windows-native/setup/build-setup.ps1` | Setup.exeのビルド | `launcher\\LocalRAG.ico`を`/win32icon`で埋め込む。参照先を確認し、ICO更新後に必ず再ビルドする |
| セットアップ実行ファイル | `C:\LocalRAG\dist\OTE-RAG-Setup.exe` | 顧客がダブルクリックする配布物 | ソースを変更しても自動更新されない。`build-setup.ps1`で再生成する |
| 配布パッケージ | `C:\LocalRAG\dist\OTE-RAG-win64-v<version>.zip` | Windows native本体とアイコンを含む配布ZIP | `windows-native/export-windows.ps1`で再作成し、ZIP内の `launcher\\LocalRAG.ico`、`app\\server\\public\\favicon.png`、`app\\server\\public\\favicon.ico` を確認する。原本SVGはフロントエンドビルドに取り込まれるため、実際のv1.2.2 ZIPにはapp/server/public/localrag-icon.svgも同梱される |
| インストール後 | `C:\LocalRAGProd\LocalRAG.ico` | インストール先のショートカット参照先 | 手動コピーではなく再インストールで更新する |

## 直接編集するファイル

原則として、次の4ファイルを同じデザインから更新する。

1. `anything-llm/frontend/src/media/logo/localrag-icon.svg`
2. `anything-llm/frontend/public/favicon.png`
3. `anything-llm/frontend/public/favicon.ico`
4. `windows-native/launcher/LocalRAG.ico`

フロントエンドをビルドして`server/public`へ配置した後は、次の2ファイルも確認対象になる。

- `anything-llm/server/public/favicon.png`（Windows配布ZIPでは`app/server/public/favicon.png`）
- `anything-llm/server/public/favicon.ico`（Windows配布ZIPでは`app/server/public/favicon.ico`）

`LocalRAG`という内部ファイル名は、既存のインストールスクリプト、ショートカット、ビルドスクリプトとの互換性のため維持する。表示名・製品名は`OTE-RAG`のままとする。

## Claude Code側の実施手順

1. このメモと `docs/HANDOFF.md` を確認する。
2. `anything-llm/` がルート `.gitignore` で除外されていることを確認する。SVGとfaviconはルートGit差分に出ないため、fork側の管理方法と配布ビルドへの取り込み方法を明確にする。
3. 原本SVGを確認し、PNG/ICOを原本から再生成する。別々に手描き修正しない。
4. 64px、32px、16px程度で縮小表示し、文書・検索レンズ・日の丸・スパークが判別できることを確認する。
5. フロントエンドのビルドと`server/public`への配置後、`server/public/favicon.png`と`server/public/favicon.ico`が更新済みであることを確認する。
6. `windows-native/export-windows.ps1`で配布ZIPを再作成する。
7. `build-setup.ps1`で`OTE-RAG-Setup.exe`を再ビルドする。
8. ZIP展開後のアイコン資材と、セットアップ実行ファイルの埋め込みアイコンを確認する。
9. 必要なら既存のOTE-RAGをアンインストールして再インストールし、デスクトップ／スタートメニューのショートカット表示を確認する。

## 検証項目

- SVGが正常にビルドできる。
- `favicon.png`が64x64 PNGである。
- `favicon.ico`が32x32 ICOである。
- `LocalRAG.ico`が64x64 ICOである。
- フロントエンドビルド後の`server/public/favicon.png`と`server/public/favicon.ico`が原本から生成された版である。
- `windows-native/setup/build-setup.ps1`が`LocalRAG.ico`を参照している。
- `LocalRAG.html`が更新済み`favicon.png`を読み込む。
- Setup.exeのプロパティ／ショートカットに旧アイコンが残っていない。
- ZIP内のアイコンと再ビルドしたSetup.exeのSHA-256を記録する。
- アイコン以外の製品機能、既存の`runtime/docker-compose.yml`、モデル資材を変更していない。

## 注意事項

- 今回更新済みの主SVGとfaviconは`anything-llm/`配下にあるため、ルートリポジトリではGit管理対象外。配布ビルドがこの作業ツリーを参照することを確認する。
- ルートGitで追跡されているアイコン変更は現時点では `windows-native/launcher/LocalRAG.ico`。このメモと`docs/HANDOFF.md`も反映記録として管理する。
- 既存の`C:\LocalRAG\dist`にあるSetup.exeやZIPは、再ビルドしない限り新アイコンにならない。
- `export-windows.ps1`は`server/public`をZIP内の`app/server`へコピーする。`anything-llm/frontend/public`だけ更新しても、フロントエンドのビルド・配置を行わなければ顧客配布物には反映されない。
- ICOのファイル名を`OTE-RAG.ico`へ変更する場合は、`windows-native/install.ps1`、`windows-native/setup/build-setup.ps1`、ショートカット生成処理、検証スクリプトを同時に更新する。今回の反映では名前変更を行わない。
- コミット・プッシュは別途ユーザーの明示依頼を受けてから実施する。
