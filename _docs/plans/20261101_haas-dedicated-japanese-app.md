---
status: active
created: 2026-11-01
---

# 「Haas音声入力」を日本語の専用アプリとして組み直す

## 主な目標

Haasの日本語音声をカーソル位置へ順次入力する専用アプリにする。利用者が使う画面は「ホーム・履歴・辞書・設定」と録音パネルに整理し、保存済みの辞書・履歴・保留文・録音設定・ショートカットを引き継ぐ。

利用者はModes、Transcribe、AI Models、VoiceInk Proのメニューと関連コードの削除、完全な日本語表示を希望した。アプリ名は「Haas音声入力」に決定済み。再利用元は `voiceink-haas` のマージ後の `a3bc288cc9a643aa0dc9dae3570d3c5e588d679b`。利用者の追加指示により、独立した非公開リポジトリ `masatatsu8/haas-input`、ローカル `/Users/tatsumi/work/haas-input` で作成する。Gitの履歴とupstream設定は引き継がず、新しい履歴で開始する。既存の `voiceink-haas` はマージ済みmainのまま維持する。

## 方針と完了条件

現在の入口はHaasの利用時にもWhisper、FluidAudio、汎用LLM、ライセンス、更新機構を組み立てている。専用のソースルート `HaasInput/` とアプリ入口を作り、必要な既存処理を移してから旧機能を削除する。

- 認識はHaas Q8 / speech.cpp / Silero VADだけにする。モデルの固定版取得・ハッシュ検証は保持する。
- 「速度優先」とApple端末内モデルによる「自然さ優先」の句読点設定を保持する。汎用LLM設定やモデル一覧とは分離する。
- Haas辞書の4分類ボタン、正式表記・読み、共有JSONと、確定後の明示的な置換ルールを保持する。
- 録音開始・終了、Fnを含むショートカット、押している間の録音、履歴、音声再生、CSV、保留文の確認・コピーを提供する。
- マイク選択、入力チャンネル、録音中の音量・再生制御、録音パネル、クリップボード復元、保存期間の設定を引き継ぐ。
- Modes、音声・動画ファイル取り込み、多モデルASR、汎用AI整形、Assistant、OCR/ブラウザ文脈取得、Auto Learn、販売ライセンス、上流向け自動更新を削除する。Haasで未対応だった履歴からのファイル再認識も提供しない。
- 新リポジトリへ必要なソースだけを持ち込み、旧機能のSwiftコード・SPM依存・Refine XPC・プロバイダ画像・不要なスクリプトと宣言を含めない。
- GPLのLICENSEと著作権表示、speech.cpp / Haas / Sileroのライセンス情報を保持する。
- ユーザー向けのメニュー、画面、説明、エラー、権限要求、通知を日本語にする。標準用語のHaas、JSON、CSV、キー記号、ライセンスの正式名称などは固有の表記を使用する。

## 第0段階: 依存関係と保存契約を確定する

この段階の役割: 動作するHaasの処理と保存済みデータを見分け、不要機能を安全に取り除くための境界を決める。

実コードと既存文書を3分野に分けて調査済み。GitNexusはこのリポジトリの登録がないため、参照箇所をソースで追跡した。

| 境界 | 再利用元とAPI |
|---|---|
| 認識 | `VoiceInk/Infrastructure/Providers/Transcription/Haas/`。`HaasRealtimeClient.connect(vocabulary:)`、`sendAudioChunk(_:)`、`finish()`、`cancel()` |
| セッション | `HaasDictationSession.swift:83-162`。他モデル用の未使用引数とファイル認識拒否adapterを取り除き、専用の準備・終了へ整理する |
| 録音 | `CoreAudioRecorder.swift:111`、`Recorder.swift`、`Recorder+RecordingDeviceSetup.swift`。同じPCMを録音ファイルとストリームへ渡す |
| キー操作 | `RecordingShortcutManager.swift:343`以降の`RecordingShortcutModeHandler`、Shortcut/Store/Monitor/EventTap/Thread/SessionPolicy |
| 入力保護 | `HaasInputDelivery.swift:29,332`、`CursorPaster.swift:256,354`。入力先の照合、所有権、保存順序を保持する |
| 永続化 | `VoiceInk.swift:229-271`の3つのModelConfiguration、4つのSwiftDataモデル、HaasSettingsStore、HaasRecoveryStore |
| 表示 | HaasVocabularyTable/Editor、HaasRecoveryHistoryView、録音パネル・画面位置の処理 |
| 配布 | `scripts/build-haas-prototype.sh:30-67`の隔離stage・runtime同梱・署名検証、`prepare-haas-runtime.py`の固定版取得 |

上のパスと行番号は比較元コミットの位置を指す。新構成への移動後は古い機能を呼び直さず、新しい接続口で組み合わせる。

Allowed APIsは既存のFoundation/SwiftUI/AppKit/SwiftData/CoreAudio/AVFoundation/ApplicationServices/Carbonと、現在使っているswift-atomics・MediaRemoteAdapterに限定する。Apple句読点は既存のFoundationModels availability境界を維持する。XcodeGenは導入済みの実行環境と公式仕様を確認してprojectを生成する。

検証: 依存の列挙、保存キーと4モデルの形状、Haasの準備・終了経路をソースで確認する。
注意: Modesの録音プロファイルと、ショートカットのtoggle/pushToTalk/hybrid/doubleTapを混同して削除しない。

## 第1段階: 互換性を固定して必要な中核を移す

この段階の役割: 専用版へ更新しても、利用者の登録語・録音・過去の確認待ちを失わずに使えるようにする。

本番bundle IDは `com.tatsumi.VoiceInkHaas`、Swift module名は保存互換のため `VoiceInk` を維持する。表示名と新project名は別にする。テストホストは `.TestsHost` の別ID・保存先を使い、実runtimeやマイクを起動しない構成にする。

`AppStorageIdentity` を専用版として明示し、`HAAS_PROTOTYPE` の条件を外した結果、元VoiceInkの保存先へ戻る事故を防ぐ。次の契約を維持する。

- `default.store` / configuration `default` / Transcription。
- `dictionary.store` / configuration `dictionary` / VocabularyWord + WordReplacement。
- `stats.store` / configuration `stats` / SessionMetric。
- 4モデルの属性、既存ID、`originalName`、録音の絶対file URLを保持する。旧ModesやAIの属性は、過去の履歴を読むための保存互換に限定する。
- `HaasVocabularyEntriesV1` とHaasのruntime/model/VADキー、共有format `voiceink.haas-vocabulary`、V1/V2互換とraw値を維持する。
- `haas-input-recovery.json` の版・record/segment ID・本文・disposition、旧defaults移行の検証とatomic保存を維持する。
- Shortcut保存キーとraw値、マイクのUID・優先順位・チャンネル、句読点のfast/natural、保存期間を維持する。

参照: AppStorageIdentity、Persistence/Modelsの4ファイル、HaasSettingsStore、HaasVocabularyArchive、HaasRecoveryStore/State、UserDefaultsManager、ShortcutStore/Migration。
検証: 比較元のモデルから生成した合成ストアを新しい保存層で開き、全属性・ID・音声参照を比較する。保存失敗時に無言で空の履歴へ切り替えない。実データの更新は合成データ検証後に行う。
注意: 読込時に辞書を正規化・削除したり、旧履歴の本文を書き換えたりしない。

## 第2段階: Haas専用の録音・入力制御を接続する

この段階の役割: 最初の文字から録音終了まで、Haasの結果を順番どおり表示・入力できるようにする。

新しいHaasEngineを、専用セッション、既存Recorder、保存層、HaasInputDeliveryへ接続する。録音開始要求IDを持ち、準備中の取消・キーrelease・前の停止応答が次の録音へ混ざらないようにする。ハードウェア停止とセッション終了、必要な履歴保存、資源解放を待ってからidleを公開する。

汎用TranscriptionServiceRegistry/ModeRuntimeResolver/AIServiceを持ち込まない。HaasDictationSessionは専用の `prepare()` / `finish()` と、`recognizedText` / `cancel()` / `attachTranscription(_:)` を接続口にする。必要な依存注入は録音・認識の実際の境界に置き、テスト専用の状態変更APIは作らない。

Clipboardの標準経路を専用pasterへ抽出する。secure input、secure field、自アプリのキーウィンドウ、前面PIDとAX要素、session/generationを送信直前・直後に確認する。本文・token・changeCountによる所有確認と復元、uncertainの自動再送禁止を保持する。Enter等の自動送信は実装しない。

録音プロファイル用ショートカットと未提供機能のショートカットを削除し、録音・取消・履歴表示・直前結果コピーなど専用版で意味のある操作へ絞る。自身の合成キーイベントを録音停止と誤認しない処理を保持する。

参照: VoiceInkEngineのHaas分岐、TranscriptionPipelineのHaas終了処理、RecordingShortcutModeHandler、HaasTextPasting/InputDelivery、CursorPasterの標準経路。
検証: 準備取消、遅いrelease、停止待ち、旧応答、履歴・保留の関連付け、クリップボード差し替え、入力先変更、secure input、fast/naturalの順序を検証する。
注意: 暫定結果は表示だけに使い、確定区間だけを一度ずつ入力する。復旧したセキュア入力の保護を速度改善の名目で外さない。

## 第3段階: 日本語の4画面と録音パネルを作る

この段階の役割: 目的と関係のない設定を探さずに、録音・履歴確認・辞書登録を行えるようにする。

- ホーム: Haasの準備状態、マイク/アクセシビリティの案内、録音操作、直近結果。
- 履歴: 検索、本文のコピー、音声再生、CSV書き出し、削除、入力確認待ち。過去のenhancedTextは既存の表示優先規則で読めるようにする。
- 辞書: Haas辞書の4分類ボタン・検索・編集・共有と、日本語の置換ルール。通常VocabularyやAuto Learnは削除する。
- 設定: ショートカット、録音機器・チャンネル、録音中の音量/再生制御、句読点、パネル表示、クリップボード復元、保存期間、ログイン時起動、診断とライセンス情報。

メニューバー常駐、初回案内、ミニ/画面上部の録音表示も日本語にする。古い言語選択設定で英語へ戻らないよう、日本語をアプリの基準言語として設定する。利用者向けのエラー本文に英語のサーバー診断をそのまま表示せず、必要な詳細は診断ログへ分ける。

参照: HaasVocabularyTable/Editor、HaasPendingInputView、HaasRecoveryHistoryView、Mini/NotchRecorderPanelとRecorderScreenResolver、AudioSetupView、ShortcutRecorder。
検証: 4画面・空状態・エラー・共有・削除確認・権限案内・録音中/終了中/保留の表示を確認する。辞書の追加・編集・種類の保存と、既存値の保持を確認する。
注意: ソース名や保存互換の属性名まで翻訳して保存契約を壊さない。製品表示に不要な実装用語を出さない。

## 第4段階: 新リポジトリのビルド対象を必要機能だけにする

この段階の役割: 専用版の保守・ビルド対象を、実際に提供する機能だけに揃える。

専用project/schemeと隔離TestHostを作る。XcodeGenの定義と生成projectを管理し、build/testスクリプトとREADMEを新アプリ名・新ルートへ揃える。必要なswift-atomicsと録音中再生制御用MediaRemoteAdapterは保持し、Whisper/FluidAudio/TranscribeCpp/LLMkit/MLX/HuggingFace/Tokenizers/MarkdownUI/ZIPFoundation/SparkleとRefine XPCを除去する。

新ルートのコンパイル閉包を検証し、新リポジトリに旧 `VoiceInk/`、旧project、Refine XPC、不要なShared/画像/多言語リソース/ブラウザスクリプト/上流リリースfeedが含まれないことを確認する。保存互換用の4モデル以外に旧機能の待機コードを残さない。既存リポジトリ、古い配布アプリ、ユーザーのモデルキャッシュは保持する。

既存テストは守る契約ごとに移す。廃止する多モデル/Mode選択のテストは除き、録音競合・回復・保護・辞書・句読点のテストを維持する。テスト数の維持やgrepだけのテストを目的にしない。

参照: project.pbxproj、build/test-haas-prototype.sh、prepare-haas-runtime.py、既存Haas/Shortcut/WordReplacementテスト。
検証: 新projectのソース/リンク依存、Bundle内framework/XPC、Info.plist/entitlementsを検査する。汎用モデル・LLM・ライセンス・ファイル取り込みの参照と英語UIの残りを調べる。未使用コードをビルド除外だけで残さない。

## 第5段階: データ継承と専用版の実動作を確認して反映する

この段階の役割: 画面が小さくなっただけでなく、普段の音声入力が引き続き使える完成状態を確認する。

意味のある単体・統合テスト、隔離Releaseビルド、署名とruntime/モデルの同梱検証を実施する。保存互換の合成データ確認と日本語UI確認を終え、deslopとcodex-reviewを通してから新しい非公開リポジトリ `masatatsu8/haas-input` のPRへ反映する。

実アプリ更新直前に、現在の辞書・設定・保留記録と履歴ストアを退避し、編集中や録音中でないことを確認する。旧アプリをバックアップして新しい「Haas音声入力.app」を配置する。OSが本人認証を求めた場合だけ利用者へ引き継ぐ。

検証: 既存ID/本文/録音参照/辞書/ショートカットの一致、表示名と日本語UI、権限、録音開始/停止、録音中の暫定表示とTextEditへの順次入力、取消・保留、fast/naturalを確認する。必要以上に同じ検証を反復しない。実機性能や認識品質を測っていない条件へ一般化しない。
注意: 実データを自動復元して利用者の新しい編集を上書きしない。新しい未確認文を入力先へ自動再送しない。マージは利用者の指示時に行う。
