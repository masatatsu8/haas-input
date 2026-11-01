# Haas音声入力

Haas-jaを使い、Macのカーソル位置へ日本語の音声を順次入力する専用アプリです。録音中の暫定結果を表示し、確定した区間から入力します。

このリポジトリでは専用版を開発しています。[実装計画](_docs/plans/20261101_haas-dedicated-japanese-app.md)に、引き継ぐ機能と検証項目を記載しています。

## 4つの画面で使う

| 画面 | できること |
|---|---|
| ホーム | 録音の開始・停止、モデルの準備状態、権限の確認 |
| 履歴 | 認識した文章と録音の確認、コピー、入力確認待ちの操作 |
| 辞書 | 正式表記と読み・別表記の登録、置換ルール、辞書ファイルの共有 |
| 設定 | ショートカット、録音デバイス、句読点、録音中の音声制御など |

認識にはローカルのHaas-ja Q8とspeech.cppを使います。句読点の「速度優先」は追加AIを使わず、明確な文末にだけ句点を補います。「自然さ優先」は、利用可能なAppleの端末内モデルで句読点の追加を試します。

## ソースからアプリを作る

Apple SiliconのMac、macOS 15以降、macOS 26以降のSDKを含むXcode、XcodeGen 2.44.1以降、Python 3、Gitを用意してください。自然さ優先の利用にはmacOS 26以降と、利用可能なAppleの端末内モデルが必要です。

リポジトリのルートで実行します。

```sh
make build
```

初回は依存ライブラリ、固定版の推論エンジン、モデルを取得します。モデルと推論エンジンはSHA-256を確認してから使います。候補アプリは次の場所に作成されます。

```text
.haas-build/dedicated-app-candidate/Haas音声入力.app
```

ビルド処理はアプリを起動せず、使用中のアプリへ自動配置もしません。旧「VoiceInk Haas」から更新するときは、旧版を終了してから新しいアプリを起動してください。

Command Line Toolsが選ばれていて`DEVELOPER_DIR`が未指定の場合、ビルド・テスト用スクリプトは`/Applications/Xcode.app`を使います。システムの`xcode-select`設定は変更しません。別のXcodeを使う場合は、そのビルドに限って指定できます。

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make build
```

既定の署名はad-hoc署名です。自分の署名IDを使う場合は`HAAS_CODESIGN_IDENTITY`で指定します。署名が変わると、アクセシビリティ権限の再登録が必要になる場合があります。

| 環境変数 | 用途 |
|---|---|
| `HAAS_OUTPUT_ROOT` | 候補アプリの出力先 |
| `HAAS_BUILD_CONFIGURATION` | `Release`が既定。開発時は`Debug`も指定可能 |
| `HAAS_CODESIGN_IDENTITY` | 署名ID。既定は`-` |
| `HAAS_BUNDLE_MODELS` | `1`はモデル同梱、`0`はモデルを同梱しない構成 |

## テストを実行する

```sh
make test
```

本番と異なるbundle IDのTestHostで実行します。TestHostの入口は空の画面だけで、モデルの準備や録音を開始しません。移行の検証には合成データを使い、実際の辞書・履歴を使いません。本番ビルドとTestHostの中間生成物も分離しています。

Xcodeプロジェクトの正本は`project.yml`です。生成済みprojectは直接編集せず、定義を変えてから再生成します。

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make project
```

`make clean`は専用ビルドとTestHostの中間生成物だけを削除します。モデルの取得キャッシュ、候補アプリ、ユーザーの保存データは残します。

## 以前のデータを引き継ぐ

アプリの表示名は「Haas音声入力」ですが、保存先を識別するbundle IDは`com.tatsumi.VoiceInkHaas`を維持します。以前の「VoiceInk Haas」の履歴、辞書、置換ルール、入力確認待ちを引き継ぐ構成です。

辞書の種類は整理用です。認識には正式表記と読み・別表記を渡し、「組織」「人名」などの分類属性は渡しません。入力先を確認できないときは文章を保留します。過去の確認待ちを新しい録音へ混ぜて自動再送しません。

## ライセンスと再利用したコード

VoiceInkと既存のHaas統合コードの必要な部分を再利用しています。アプリのソースは[GPL v3](LICENSE)です。再利用元は[Beingpax/VoiceInk](https://github.com/Beingpax/VoiceInk)です。このリポジトリは独立したGit履歴で管理し、`upstream`は登録していません。

推論エンジンは[speech.cpp](https://github.com/nyosegawa/speech.cpp)、認識モデルはHaas-ja、発話区間の検出はSilero VADを使います。これらのライセンス原文をアプリへ同梱します。Swiftの依存ライブラリは[Swift Atomics](https://github.com/apple/swift-atomics)と[MediaRemoteAdapter](https://github.com/Beingpax/mediaremote-adapter)です。固定revisionは`project.yml`に記載し、取得済みのライセンス・著作権表示を保持します。
