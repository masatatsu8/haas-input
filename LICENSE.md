# ライセンス

## Haas音声入力本体

Haas音声入力のソースコードは、GNU General Public License v3.0 (GPL v3) で公開しています。全文は[LICENSE](LICENSE)にあります。

このアプリは[Beingpax/VoiceInk](https://github.com/Beingpax/VoiceInk) (GPL v3) のコードと操作音 (`HaasInput/Resources/Sounds/`) を再利用し、改変しています。GPL v3に従い、改変版もGPL v3で配布します。

配布するアプリ (バイナリ) を受け取った人は、対応するソースコードをこのリポジトリから入手できます。各リリースは、ビルドしたcommitのtagと対応しています。

本ソフトウェアは無保証です。詳しくはGPL v3の第15条・第16条を参照してください。

## 同梱するコンポーネント

配布するアプリには、次のモデル・推論エンジン・ライブラリが含まれます。それぞれの著作権は原著作者にあり、各ライセンスに従って再配布しています。ライセンス原文は、アプリ内の表のファイルに収めています。

| コンポーネント | 用途 | ライセンス | 入手元 | アプリ内のライセンス原文 |
|---|---|---|---|---|
| Haas-ja v1.0 (Q8_0 GGUF) | 日本語音声認識モデル | Apache License 2.0 | 原モデル [third-intelligence/Haas-ja-v1.0](https://huggingface.co/third-intelligence/Haas-ja-v1.0)、GGUF変換 [sakasegawa/Haas-ja-v1.0-GGUF](https://huggingface.co/sakasegawa/Haas-ja-v1.0-GGUF) | `Contents/Resources/Haas/HAAS-LICENSE` |
| speech.cpp v0.9.4 | 推論エンジン | MIT License (Copyright (c) 2026 Sakasegawa) | [nyosegawa/speech.cpp](https://github.com/nyosegawa/speech.cpp) | `Contents/Resources/Haas/SPEECH-LICENSE` |
| ggml | speech.cppに静的リンクされる計算ライブラリ | MIT License (Copyright (c) 2023-2026 The ggml authors) | [nyosegawa/ggml](https://github.com/nyosegawa/ggml) (speech.cppのsubmodule) | `Contents/Resources/Haas/GGML-LICENSE` |
| cpp-httplib | speech.cppのコマンドに組み込まれるHTTPライブラリ | MIT License (Copyright (c) 2017 yhirose) | [yhirose/cpp-httplib](https://github.com/yhirose/cpp-httplib) (speech.cppに同梱) | `Contents/Resources/Haas/CPP-HTTPLIB-LICENSE` |
| miniaudio | speech.cppのコマンドに組み込まれる音声入力ライブラリ | Public Domain (Unlicense) またはMIT No Attribution の選択制 | [mackron/miniaudio](https://github.com/mackron/miniaudio) (speech.cppに同梱) | `Contents/Resources/Haas/MINIAUDIO-LICENSE` |
| Silero VAD (GGUF) | 発話区間の検出 | MIT License (Copyright (c) 2020-present Silero Team) | [sakasegawa/silero-vad-GGUF](https://huggingface.co/sakasegawa/silero-vad-GGUF) | `Contents/Resources/Haas/SILERO-LICENSE` |
| Swift Atomics | Swiftライブラリ | Apache License 2.0 (Runtime Library Exception付き) | [apple/swift-atomics](https://github.com/apple/swift-atomics) | `Contents/Resources/SWIFT-ATOMICS-LICENSE` |
| MediaRemoteAdapter | 録音中のメディア再生の一時停止 | BSD 3-Clause License ほか (下記) | [Beingpax/mediaremote-adapter](https://github.com/Beingpax/mediaremote-adapter) | `Contents/Resources/MediaRemoteAdapter-Notices.txt` |
| VoiceInk | 再利用元のアプリ | GPL v3 | [Beingpax/VoiceInk](https://github.com/Beingpax/VoiceInk) | `Contents/Resources/VOICEINK-LICENSE` |

モデル、推論エンジン、Silero VADは、ビルド時に固定revisionから取得し、SHA-256を確認して同梱します。取得元とrevisionは`scripts/prepare-haas-runtime.py`に記載しています。

### MediaRemoteAdapterの著作権表示

固定revision `cf30c4f1af29b5829d859f088f8dbdf12611a046` のソースに記載された表示を、[HaasInput/Resources/MediaRemoteAdapter-Notices.txt](HaasInput/Resources/MediaRemoteAdapter-Notices.txt)に原文のまま収めています。同じファイルの末尾に、上流の[ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)にあるBSD 3-Clause Licenseの全文も載せています。Beingpax版はこのリポジトリをもとにしたforkで、fork側にはLICENSEファイルがありません。

- `MediaRemoteAdapter.m` ほか: Copyright (c) 2025 Jonas van den Berg, BSD 3-Clause License
- `MediaRemoteAdapter.h`: Copyright © 2024 Ethan Bills. All rights reserved.
- `MediaRemote.h`: Copyright (c) 2013-2014 Cykey (David Murray). All rights reserved.

最後の2つのファイルには、ソース上に再配布条件の記載がなく、上流のBSD 3-Clause Licenseがこれらにも及ぶかは確認できていません。`MediaRemote.h`はmacOSの非公開フレームワークのインターフェイスを宣言するヘッダです。権利関係が確認でき次第、この節を更新します。

## 名称について

「VoiceInk」はBeingpax/VoiceInkのアプリ名です。本アプリはVoiceInkの公式版ではありません。bundle IDとSwiftモジュール名に残る`VoiceInk`は、前身アプリの保存データを引き継ぐための識別子です。
