import Foundation

/// 入力欄の状態。読めるときはカーソル直前の文字列と選択範囲の長さを持つ
enum HaasFieldState: Equatable {
    case readable(textBeforeCaret: String, selectionLength: Int)
    case unreadable
}

/// 置き換えの判定に使う、直前の挿入と入力先の状態
struct HaasReplacementContext: Equatable {
    var insertedText: String
    var allSegmentsPosted: Bool
    var watchedWithoutUserInput: Bool
    var targetUnchanged: Bool
    var field: HaasFieldState
}

/// 置き換えず、クリップボードへのコピーだけにする理由
enum HaasCopyReason: Equatable {
    case noRecord, notAllPosted, userInputDetected, targetChanged
    case selectionNotEmpty, textMismatch, multiline, tooLong
    /// 訂正の後で、入力先の中身が直した文と確かめられない (decide は返さない)
    case alreadyCorrected
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

        let count = inserted.count
        switch context.field {
        case let .readable(textBeforeCaret, selectionLength):
            if selectionLength != 0 { return .copyOnly(.selectionNotEmpty) }
            // 読める欄は中身を確かめられるため、改行を含んでいても末尾一致で自動置き換えする
            guard textBeforeCaret.hasSuffix(inserted) else { return .copyOnly(.textMismatch) }
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

    /// 消している途中の欄が期待どおりかを返す (読めない欄は false)
    static func fieldMatchesProgress(
        _ field: HaasFieldState, textBeforeInsertion: String, insertedText: String, deleted: Int
    ) -> Bool {
        guard case let .readable(textBeforeCaret, selectionLength) = field, selectionLength == 0 else { return false }
        let remaining = max(0, insertedText.count - deleted)
        return textBeforeCaret == textBeforeInsertion + String(insertedText.prefix(remaining))
    }

    /// 消している途中の欄を、更新が追いつくまで少しの間だけ読み直して確かめる。
    /// ブラウザなどでは Backspace の後しばらく前の中身を返すことがあるため、
    /// 1つ前の段階 (deleted - 1) とちょうど一致する間だけ待つ。それ以外の中身はすぐに止める。
    /// 期待どおりの中身とちょうど一致したときだけ true
    static func awaitFieldProgress(
        textBeforeInsertion: String, insertedText: String, deleted: Int,
        readField: () -> HaasFieldState,
        window: Duration = .milliseconds(150),
        pollInterval: Duration = .milliseconds(10)
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: window)
        while true {
            let field = readField()
            if fieldMatchesProgress(
                field, textBeforeInsertion: textBeforeInsertion, insertedText: insertedText, deleted: deleted)
            {
                return true
            }
            // deleted == 0 に前の段階はない。前の段階のまま以外は待たない
            guard deleted > 0,
                fieldMatchesProgress(
                    field, textBeforeInsertion: textBeforeInsertion, insertedText: insertedText, deleted: deleted - 1),
                ContinuousClock.now < deadline, !Task.isCancelled
            else { return false }
            try? await Task.sleep(for: pollInterval)
        }
    }
}
