import Foundation

/// 入力欄の状態。読めるときはカーソル (選択範囲) の前後の文字列と選択範囲の長さを持つ
enum HaasFieldState: Equatable {
    /// textAfterCaret は選択範囲の後ろから末尾まで
    case readable(textBeforeCaret: String, textAfterCaret: String, selectionLength: Int)
    case unreadable
}

/// 録音の最初の区切りを貼る直前に記録した、入力欄の状態
enum HaasInsertionBaseline: Equatable {
    /// 貼る前のカーソル直前の文字列
    case readable(textBeforeInsertion: String)
    /// 貼る前に中身を読めなかった
    case unreadable
}

/// 置き換えの判定に使う、直前の挿入と入力先の状態
struct HaasReplacementContext: Equatable {
    var insertedText: String
    var allSegmentsPosted: Bool
    var watchedWithoutUserInput: Bool
    var targetUnchanged: Bool
    var field: HaasFieldState
    /// 貼る前の欄の記録。nil は記録がない
    var insertionBaseline: HaasInsertionBaseline?
}

/// 置き換えず、クリップボードへのコピーだけにする理由
enum HaasCopyReason: Equatable {
    case noRecord, notAllPosted, userInputDetected, targetChanged
    case selectionNotEmpty, textMismatch, multiline, tooLong
    /// 貼る前の欄の記録がない、または貼る前に読めなかった欄が今は読める。今回入れた文だと確かめられない
    case insertionUnverified
    /// 訂正の後で、入力先の中身が直した文と確かめられない (decide は返さない)
    case alreadyCorrected
}

/// 消している途中の読める欄が、どうなっているべきか
struct HaasFieldExpectation: Equatable {
    /// 貼る前のカーソル直前の文字列
    let textBeforeInsertion: String
    let insertedText: String
    /// ポップアップを開いたときのカーソルの後ろの文字列
    let textAfterCaret: String
}

/// 置き換えの方式。確かめられない場合は必ずコピーのみにする
enum HaasReplacementDecision: Equatable {
    case replaceAutomatically(deleteCount: Int)
    case replaceAfterConfirmation(deleteCount: Int)
    case copyOnly(HaasCopyReason)

    /// 読めない入力先で、確認付きの置き換えを許す最大文字数
    static let maximumConfirmedLength = 200

    static func decide(_ context: HaasReplacementContext) -> HaasReplacementDecision {
        let inserted = context.insertedText
        if inserted.isEmpty { return .copyOnly(.noRecord) }
        if !context.allSegmentsPosted { return .copyOnly(.notAllPosted) }
        if !context.watchedWithoutUserInput { return .copyOnly(.userInputDetected) }
        if !context.targetUnchanged { return .copyOnly(.targetChanged) }
        // 貼る前の欄を記録していなければ、何を入れたかを確かめられない
        guard let baseline = context.insertionBaseline else { return .copyOnly(.insertionUnverified) }

        let count = inserted.count
        switch context.field {
        case let .readable(textBeforeCaret, _, selectionLength):
            if selectionLength != 0 { return .copyOnly(.selectionNotEmpty) }
            // 貼る前に読めなかった欄は、今読めても入れる前の中身がわからない
            guard case let .readable(textBeforeInsertion) = baseline else { return .copyOnly(.insertionUnverified) }
            // 末尾が同じだけでは今回入れた証明にならない (貼り付けが拒まれ、元から同じ文で終わる欄など)。
            // 貼る前の中身に入れた文を足したものと、ちょうど一致するときだけ消す
            guard textBeforeCaret == textBeforeInsertion + inserted else { return .copyOnly(.textMismatch) }
            return .replaceAutomatically(deleteCount: count)
        case .unreadable:
            if inserted.contains(where: \.isNewline) { return .copyOnly(.multiline) }
            if count > maximumConfirmedLength { return .copyOnly(.tooLong) }
            return .replaceAfterConfirmation(deleteCount: count)
        }
    }

    /// 確定の時点で実行してよい判定を返す。開いたときと同じ判定のときだけ `now` を通す
    static func confirmed(shown: HaasReplacementDecision, now: HaasReplacementDecision) -> HaasReplacementDecision {
        if case .copyOnly = now { return now }
        return shown == now ? now : .copyOnly(.targetChanged)
    }

    /// 消している途中の欄が期待どおりかを返す (読めない欄は false)。
    /// カーソルの前は「貼る前の中身 + 入れた文の残り」、後ろは開いたときのままで、選択範囲が空のときだけ true
    static func fieldMatchesProgress(
        _ field: HaasFieldState, expectation: HaasFieldExpectation, deleted: Int
    ) -> Bool {
        guard case let .readable(textBeforeCaret, textAfterCaret, selectionLength) = field, selectionLength == 0
        else { return false }
        let remaining = max(0, expectation.insertedText.count - deleted)
        return textBeforeCaret == expectation.textBeforeInsertion + String(expectation.insertedText.prefix(remaining))
            && textAfterCaret == expectation.textAfterCaret
    }

    /// 開き括弧・引用符と、その閉じ側の組。エディタによっては、間で Backspace を押すと両方を消す
    static let closingPairs: [Character: Character] = [
        "(": ")", "[": "]", "{": "}", "<": ">",
        "「": "」", "『": "』", "（": "）", "［": "］", "｛": "｝", "【": "】", "〈": "〉", "《": "》",
        "\"": "\"", "'": "'", "`": "`", "“": "”", "‘": "’",
    ]

    /// 次の Backspace がカーソルの後ろの文字まで消しうるなら true (開き側を消す位置の直後に閉じ側がある)
    static func backspaceMayDeleteBeyondCaret(_ field: HaasFieldState) -> Bool {
        guard case let .readable(textBeforeCaret, textAfterCaret, _) = field else { return false }
        guard let deleting = textBeforeCaret.last, let closing = closingPairs[deleting] else { return false }
        return textAfterCaret.first == closing
    }
}
